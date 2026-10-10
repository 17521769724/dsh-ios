import Foundation

/// 工作区文件系统：内置文件管理器与 IDE 的数据层，根目录在 Documents/Workspace。
///
/// 该目录同时通过系统「文件」App 可见（Info.plist 已开启 UIFileSharingEnabled），
/// 用户既可以在 App 里管理，也可以把代码文件从「文件」App 拖进来；
/// 智能体则通过「工作区文件」工具读写同一批文件——模型写的代码可以直接用内置 IDE 打开继续编辑。
final class WorkspaceStore: ObservableObject {

    /// 一条文件或文件夹记录
    struct Item: Identifiable, Hashable {
        let url: URL
        let isDirectory: Bool
        let size: Int64
        let modifiedAt: Date

        var name: String { url.lastPathComponent }
        var id: String { url.path }
    }

    /// 默认根目录（Documents/Workspace，首次访问时创建）
    static var defaultRoot: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let root = documents.appendingPathComponent("Workspace", isDirectory: true)
        if !FileManager.default.fileExists(atPath: root.path) {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        return root
    }

    /// 单个文本文件的读取上限 / 写入上限（避免把整个磁盘塞进上下文）
    static let maxReadCharacters = 60_000
    static let maxWriteCharacters = 200_000
    /// 工作区检索：最多扫描的文件数 / 单文件大小上限 / 返回的匹配条数 / 单行截断长度
    static let maxSearchFiles = 300
    static let maxSearchFileBytes = 256 * 1024
    static let maxSearchMatches = 30
    static let searchLineCharacters = 120

    let root: URL

    /// 当前浏览的目录
    @Published private(set) var directory: URL
    /// 当前目录下的内容（文件夹在前，各自按名字排序）
    @Published private(set) var items: [Item] = []
    /// 最近一次操作失败的原因（界面提示用）
    @Published var errorText: String?

    private let fileManager = FileManager.default

    init(root: URL? = nil) {
        let target = root ?? Self.defaultRoot
        if !fileManager.fileExists(atPath: target.path) {
            try? fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        }
        self.root = target
        self.directory = target
        reload()
    }

    // MARK: - 浏览

    var isAtRoot: Bool { directory.path == root.path }

    /// 当前目录相对工作区根目录的路径（根目录为空串）
    var relativePath: String {
        guard !isAtRoot else { return "" }
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return directory.path.hasPrefix(prefix) ? String(directory.path.dropFirst(prefix.count)) : ""
    }

    func reload() {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let urls = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )) ?? []
        items = urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return Item(
                url: url,
                isDirectory: values?.isDirectory ?? false,
                size: Int64(values?.fileSize ?? 0),
                modifiedAt: values?.contentModificationDate ?? Date(timeIntervalSince1970: 0)
            )
        }
        .sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    func enter(_ item: Item) {
        guard item.isDirectory else { return }
        directory = item.url
        reload()
    }

    func goUp() {
        guard !isAtRoot else { return }
        let parent = directory.deletingLastPathComponent()
        guard parent.path.count >= root.path.count else { return }
        directory = parent
        reload()
    }

    // MARK: - 增删改

    /// 新建文件夹，返回新目录；名字为空或重名时返回 nil
    @discardableResult
    func createFolder(named rawName: String) -> URL? {
        guard let name = Self.sanitized(name: rawName, isDirectory: true) else { return nil }
        let url = directory.appendingPathComponent(name, isDirectory: true)
        guard !fileManager.fileExists(atPath: url.path) else {
            errorText = "已存在同名文件夹"
            return nil
        }
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
            reload()
            return url
        } catch {
            errorText = "新建文件夹失败：\(error.localizedDescription)"
            return nil
        }
    }

    /// 新建空文件，返回文件地址；名字为空或重名时返回 nil
    @discardableResult
    func createFile(named rawName: String) -> URL? {
        guard let name = Self.sanitized(name: rawName, isDirectory: false) else { return nil }
        let url = directory.appendingPathComponent(name)
        guard !fileManager.fileExists(atPath: url.path) else {
            errorText = "已存在同名文件"
            return nil
        }
        guard fileManager.createFile(atPath: url.path, contents: Data()) else {
            errorText = "新建文件失败"
            return nil
        }
        reload()
        return url
    }

    @discardableResult
    func rename(_ item: Item, to rawName: String) -> Bool {
        guard let name = Self.sanitized(name: rawName, isDirectory: item.isDirectory) else { return false }
        let target = item.url.deletingLastPathComponent().appendingPathComponent(name)
        guard target.path != item.url.path else { return true }
        guard !fileManager.fileExists(atPath: target.path) else {
            errorText = "已存在同名\(item.isDirectory ? "文件夹" : "文件")"
            return false
        }
        do {
            try fileManager.moveItem(at: item.url, to: target)
            reload()
            return true
        } catch {
            errorText = "重命名失败：\(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func delete(_ item: Item) -> Bool {
        do {
            try fileManager.removeItem(at: item.url)
            reload()
            return true
        } catch {
            errorText = "删除失败：\(error.localizedDescription)"
            return false
        }
    }

    // MARK: - 读写

    /// 读取文本文件内容（超长截断，非文本返回 nil）
    func read(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        guard text.count > Self.maxReadCharacters else { return text }
        return String(text.prefix(Self.maxReadCharacters)) + "\n…（文件过长，已截断）"
    }

    @discardableResult
    func write(_ text: String, to url: URL) -> Bool {
        guard Self.isInside(url, root: root) else {
            errorText = "只能写入工作区内的文件"
            return false
        }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            reload()
            return true
        } catch {
            errorText = "保存失败：\(error.localizedDescription)"
            return false
        }
    }

    // MARK: - 智能体工具

    /// 把一次文件操作转成给模型的文本结果。
    /// 路径一律按「相对工作区」解析，且必须落在工作区内（拒绝 .. 越界）。
    func perform(action: String, path: String, content: String, query: String = "") -> String {
        switch action {
        case "list":
            guard let url = Self.resolve(path: path, root: root) else {
                return "路径不合法：\(path)"
            }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                return "路径不存在：\(display(path))"
            }
            if !isDirectory.boolValue {
                return "\(display(path)) 是文件不是目录，可以用 read 读取内容。"
            }
            let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
            let children = (try? fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            )) ?? []
            guard !children.isEmpty else { return "\(display(path)) 是空目录。" }
            let lines = children
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                .map { child -> String in
                    let values = try? child.resourceValues(forKeys: Set(keys))
                    let isDir = values?.isDirectory ?? false
                    let size = values?.fileSize ?? 0
                    return isDir ? "\(child.lastPathComponent)/（文件夹）" : "\(child.lastPathComponent)（\(Self.sizeText(Int64(size)))）"
                }
            return "\(display(path)) 下共有 \(lines.count) 项：\n" + lines.joined(separator: "\n")

        case "read":
            guard let url = Self.resolve(path: path, root: root) else {
                return "路径不合法：\(path)"
            }
            guard fileManager.fileExists(atPath: url.path) else {
                return "文件不存在：\(display(path))"
            }
            guard let text = read(url) else {
                return "无法读取 \(display(path))（可能是二进制文件）。"
            }
            return "\(display(path)) 的内容如下：\n\n\(text)"

        case "search":
            guard !query.isEmpty else {
                return "检索需要提供关键词：请通过 query 参数给出要查找的内容。"
            }
            guard let url = Self.resolve(path: path, root: root) else {
                return "路径不合法：\(path)"
            }
            return search(in: url, query: query, label: display(path))

        case "write":
            guard let url = Self.resolve(path: path, root: root) else {
                return "路径不合法：\(path)"
            }
            guard !content.isEmpty else {
                return "写入内容为空：请通过 content 参数给出文件内容。"
            }
            guard content.count <= Self.maxWriteCharacters else {
                return "内容过长（\(content.count) 字符，上限 \(Self.maxWriteCharacters)），请拆成多个文件或分批写入。"
            }
            do {
                try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try content.write(to: url, atomically: true, encoding: .utf8)
                reload()
                return "已写入 \(display(path))（\(Self.sizeText(Int64(content.utf8.count)))）。用户可以在 App 的「文件」页用内置 IDE 打开它继续编辑。"
            } catch {
                return "写入失败：\(error.localizedDescription)"
            }

        case "mkdir":
            guard let url = Self.resolve(path: path, root: root) else {
                return "路径不合法：\(path)"
            }
            do {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
                reload()
                return "已创建文件夹 \(display(path))。"
            } catch {
                return "创建失败：\(error.localizedDescription)"
            }

        case "delete":
            guard let url = Self.resolve(path: path, root: root) else {
                return "路径不合法：\(path)"
            }
            guard fileManager.fileExists(atPath: url.path) else {
                return "路径不存在：\(display(path))"
            }
            guard url.path != root.path else { return "不能删除工作区根目录。" }
            do {
                try fileManager.removeItem(at: url)
                reload()
                return "已删除 \(display(path))。"
            } catch {
                return "删除失败：\(error.localizedDescription)"
            }

        default:
            return "不支持的动作：\(action)（可用：list / read / search / write / mkdir / delete）"
        }
    }

    // MARK: - 工作区检索

    /// 在目录（或单个文件）里按关键词检索匹配行，返回「文件:行号: 内容」。
    /// 让模型按需求取相关片段，而不是把整个文件读进上下文（省 token 的按需取数）。
    private func search(in url: URL, query: String, label: String) -> String {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return "路径不存在：\(label)"
        }

        var files: [URL] = []
        if isDirectory.boolValue {
            let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
            let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            while let child = enumerator?.nextObject() as? URL {
                guard files.count < Self.maxSearchFiles else { break }
                let values = try? child.resourceValues(forKeys: Set(keys))
                guard values?.isDirectory != true else { continue }
                guard (values?.fileSize ?? 0) <= Self.maxSearchFileBytes else { continue }
                guard Self.isTextFile(child) else { continue }
                files.append(child)
            }
            files.sort { $0.path < $1.path }
        } else {
            files = [url]
        }
        guard !files.isEmpty else {
            return "\(label) 下没有可检索的文本文件。"
        }

        var lines: [String] = []
        for file in files {
            guard lines.count < Self.maxSearchMatches else { break }
            guard let text = read(file) else { continue }
            let relative = file.path.hasPrefix(root.path + "/")
                ? String(file.path.dropFirst(root.path.count + 1))
                : file.lastPathComponent
            for match in Self.searchMatches(in: text, query: query, limit: Self.maxSearchMatches - lines.count) {
                lines.append("\(relative):\(match.line): \(match.text)")
            }
        }
        guard !lines.isEmpty else {
            return "在 \(label) 中没有找到包含「\(query)」的内容（已检索 \(files.count) 个文本文件）。"
        }
        return "在 \(label) 中找到 \(lines.count) 处包含「\(query)」的内容：\n" + lines.joined(separator: "\n")
    }

    /// 单文件内的关键词匹配（不区分大小写，行号从 1 开始，命中行截断到上限）
    static func searchMatches(in text: String, query: String, limit: Int) -> [(line: Int, text: String)] {
        guard !query.isEmpty, limit > 0 else { return [] }
        var results: [(line: Int, text: String)] = []
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            guard results.count < limit else { break }
            guard line.range(of: query, options: .caseInsensitive) != nil else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let content = trimmed.count > searchLineCharacters
                ? String(trimmed.prefix(searchLineCharacters)) + "…"
                : trimmed
            results.append((line: index + 1, text: content))
        }
        return results
    }

    // MARK: - 工具方法

    /// 是否是可编辑的文本文件（按扩展名判断）
    static func isTextFile(_ url: URL) -> Bool {
        textExtensions.contains(url.pathExtension.lowercased())
    }

    /// 是否是可直接预览的图片
    static func isImageFile(_ url: URL) -> Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "heic", "bmp"].contains(url.pathExtension.lowercased())
    }

    /// 相对路径 → 工作区内绝对路径；越出工作区或为空时返回 nil
    static func resolve(path: String, root: URL) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return root }
        guard !trimmed.hasPrefix("/") else { return nil }
        let url = root.appendingPathComponent(trimmed).standardizedFileURL
        return isInside(url, root: root) ? url : nil
    }

    /// 判断给定地址是否位于工作区内（含根目录本身）
    static func isInside(_ url: URL, root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// 补充说明：智能体看到的是相对路径
    private func display(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "工作区根目录" : trimmed
    }

    /// 文件名清洗：去掉路径分隔符与前后空白，拒绝 . 与 ..
    private static func sanitized(name: String, isDirectory: Bool) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != ".." else { return nil }
        guard !trimmed.contains("/"), !trimmed.contains(":") else { return nil }
        return trimmed
    }

    private static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "swift", "js", "mjs", "ts", "jsx", "tsx", "py", "rb", "go", "rs",
        "c", "h", "m", "mm", "cpp", "hpp", "cs", "java", "kt", "php", "sh", "bash", "zsh", "fish",
        "json", "yml", "yaml", "toml", "ini", "conf", "cfg", "xml", "plist", "html", "htm", "css",
        "scss", "sql", "csv", "tsv", "log", "gitignore", "env", "properties", "gradle", "dockerfile"
    ]
}