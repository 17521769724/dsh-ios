import Foundation

/// 本机缓存统计与清理。
///
/// 可清理的数据（都会随使用时间不断累积）：
/// - 已失效图片：`Documents/attachments/` 中不再被任何会话或待发图片引用的残留文件
/// - 临时文件：`tmp/` 目录里系统与内置浏览器留下的暂存数据
/// - 网络缓存：`URLCache` 里的 HTTP 响应缓存
///
/// 会话中正在使用的图片属于聊天记录，不在这里清理；它们会在删除会话或消息时自动删除。
enum AppCache {

    // MARK: - 缓存快照

    struct Snapshot: Equatable {
        /// 会话中正在使用的图片
        var inUseImageBytes: Int = 0
        /// 已失效（无任何引用）的残留图片
        var orphanImageBytes: Int = 0
        /// 临时文件
        var temporaryBytes: Int = 0
        /// 网络响应缓存
        var urlCacheBytes: Int = 0

        /// 一键清理可释放的字节数
        var cleanableBytes: Int { orphanImageBytes + temporaryBytes + urlCacheBytes }
        /// 全部图片缓存字节数
        var imageBytes: Int { inUseImageBytes + orphanImageBytes }

        static let empty = Snapshot()
    }

    // MARK: - 统计

    static func snapshot(conversations: [Conversation], drafts: [ChatAttachment] = []) -> Snapshot {
        let referenced = referencedFileNames(conversations: conversations, drafts: drafts)
        var result = Snapshot()
        for file in attachmentFiles() {
            let size = fileSize(file)
            if referenced.contains(file.lastPathComponent) {
                result.inUseImageBytes += size
            } else {
                result.orphanImageBytes += size
            }
        }
        result.temporaryBytes = directoryBytes(FileManager.default.temporaryDirectory)
        result.urlCacheBytes = URLCache.shared.currentDiskUsage
        return result
    }

    // MARK: - 清理

    /// 删除不再被引用的图片文件，返回释放的字节数
    @discardableResult
    static func purgeOrphanImages(conversations: [Conversation], drafts: [ChatAttachment] = []) -> Int {
        let referenced = referencedFileNames(conversations: conversations, drafts: drafts)
        var freed = 0
        for file in attachmentFiles() where !referenced.contains(file.lastPathComponent) {
            freed += fileSize(file)
            try? FileManager.default.removeItem(at: file)
        }
        if freed > 0 {
            AttachmentImageCache.removeAll()
        }
        return freed
    }

    /// 清理已失效图片、临时文件与网络缓存，返回释放的字节数
    @discardableResult
    static func clean(conversations: [Conversation], drafts: [ChatAttachment] = []) -> Int {
        var freed = purgeOrphanImages(conversations: conversations, drafts: drafts)
        freed += clearTemporaryDirectory()
        URLCache.shared.removeAllCachedResponses()
        AttachmentImageCache.removeAll()
        return freed
    }

    // MARK: - 展示

    /// 把字节数格式化成便于阅读的文本
    static func format(_ bytes: Int) -> String {
        guard bytes > 0 else { return "0 KB" }
        let kb = Double(bytes) / 1024
        if kb < 1000 { return String(format: "%.0f KB", max(kb, 1)) }
        let mb = kb / 1024
        if mb < 1000 { return String(format: "%.1f MB", mb) }
        return String(format: "%.2f GB", mb / 1024)
    }

    // MARK: - 内部实现

    /// 当前仍被会话消息或输入框待发图片引用的文件名
    private static func referencedFileNames(
        conversations: [Conversation],
        drafts: [ChatAttachment]
    ) -> Set<String> {
        var names = Set<String>()
        for conversation in conversations {
            for message in conversation.messages {
                for attachment in message.attachments ?? [] {
                    names.insert(attachment.fileName)
                }
            }
        }
        for draft in drafts {
            names.insert(draft.fileName)
        }
        return names
    }

    private static func attachmentFiles() -> [URL] {
        let directory = ChatAttachment.directory
        let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        return contents ?? []
    }

    private static func fileSize(_ url: URL) -> Int {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize ?? 0
    }

    private static func directoryBytes(_ directory: URL) -> Int {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: []
        )
        return (contents ?? []).reduce(0) { $0 + fileSize($1) }
    }

    /// 清空临时目录，返回释放的字节数
    @discardableResult
    private static func clearTemporaryDirectory() -> Int {
        let directory = FileManager.default.temporaryDirectory
        let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: []
        )
        var freed = 0
        for file in contents ?? [] {
            freed += fileSize(file)
            try? FileManager.default.removeItem(at: file)
        }
        return freed
    }
}