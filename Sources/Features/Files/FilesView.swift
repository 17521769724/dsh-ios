import SwiftUI
import UIKit

/// 文件：内置文件管理器 + IDE。
/// 根目录是 Documents/Workspace（同时可在系统「文件」App 中访问），
/// 文本文件用内置编辑器直接编写代码，图片可预览，其它文件可分享导出。
struct FilesView: View {
    @EnvironmentObject private var workspace: WorkspaceStore

    @State private var showNewFile = false
    @State private var showNewFolder = false
    @State private var newFileName = ""
    @State private var newFolderName = ""
    @State private var renameTarget: WorkspaceStore.Item?
    @State private var renameText = ""
    @State private var deleteTarget: WorkspaceStore.Item?
    /// 新建文件后直接推入编辑器
    @State private var pendingEditorURL: URL?

    var body: some View {
        List {
            Section {
                if workspace.items.isEmpty {
                    emptyState
                } else {
                    ForEach(workspace.items) { item in
                        row(item)
                    }
                }
            } header: {
                Text(workspace.isAtRoot ? "工作区" : "\(workspace.relativePath)/")
            } footer: {
                Text("点文件夹进入下一层，点文本文件用内置编辑器写代码；长按可重命名或删除。工作区在系统「文件」App 的「我的 iPhone → DSH → Workspace」里同样可见。")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("文件")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: editorPresented) {
            if let url = pendingEditorURL {
                CodeEditorPage(url: url)
            }
        }
        .alert("出错了", isPresented: errorPresented) {
            Button("好的", role: .cancel) { workspace.errorText = nil }
        } message: {
            Text(workspace.errorText ?? "")
        }
        .toolbar {
            if !workspace.isAtRoot {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        workspace.goUp()
                    } label: {
                        Label("上级", systemImage: "chevron.up")
                    }
                    .accessibilityIdentifier("files.up")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        newFileName = ""
                        showNewFile = true
                    } label: {
                        Label("新建文件", systemImage: "doc.badge.plus")
                    }
                    Button {
                        newFolderName = ""
                        showNewFolder = true
                    } label: {
                        Label("新建文件夹", systemImage: "folder.badge.plus")
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityIdentifier("files.add")
                .accessibilityLabel("新建")
            }
        }
        .alert("新建文件", isPresented: $showNewFile) {
            TextField("例如 main.swift", text: $newFileName)
            Button("创建") { createFile() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("带上扩展名，例如 .swift / .js / .py，创建后即可用内置 IDE 编写。")
        }
        .alert("新建文件夹", isPresented: $showNewFolder) {
            TextField("文件夹名称", text: $newFolderName)
            Button("创建") { workspace.createFolder(named: newFolderName) }
            Button("取消", role: .cancel) {}
        }
        .alert("重命名", isPresented: renamePresented) {
            TextField("新名称", text: $renameText)
            Button("保存") {
                if let target = renameTarget { workspace.rename(target, to: renameText) }
                renameTarget = nil
            }
            Button("取消", role: .cancel) { renameTarget = nil }
        }
        .confirmationDialog(
            "确定删除「\(deleteTarget?.name ?? "")」？",
            isPresented: deletePresented,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let target = deleteTarget { workspace.delete(target) }
                deleteTarget = nil
            }
            Button("取消", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("文件夹里的内容会一起删除，且无法恢复。")
        }
        .onAppear { workspace.reload() }
    }

    // MARK: - 行

    @ViewBuilder
    private func row(_ item: WorkspaceStore.Item) -> some View {
        Group {
            if item.isDirectory {
                Button {
                    workspace.enter(item)
                } label: {
                    rowLabel(item)
                }
                .buttonStyle(.plain)
            } else if WorkspaceStore.isTextFile(item.url) {
                NavigationLink {
                    CodeEditorPage(url: item.url)
                } label: {
                    rowLabel(item)
                }
            } else if WorkspaceStore.isImageFile(item.url) {
                NavigationLink {
                    ImagePreviewPage(url: item.url)
                } label: {
                    rowLabel(item)
                }
            } else {
                ShareLink(item: item.url) {
                    rowLabel(item)
                }
            }
        }
        .accessibilityIdentifier("files.row")
        .contextMenu {
            Button {
                renameText = item.name
                renameTarget = item
            } label: {
                Label("重命名", systemImage: "pencil")
            }
            ShareLink(item: item.url) {
                Label("分享 / 导出", systemImage: "square.and.arrow.up")
            }
            Button(role: .destructive) {
                deleteTarget = item
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private func rowLabel(_ item: WorkspaceStore.Item) -> some View {
        HStack(spacing: DSHTheme.Spacing.medium) {
            Image(systemName: iconName(item))
                .font(.system(size: 16))
                .foregroundStyle(item.isDirectory ? DSHTheme.brand : DSHTheme.secondaryText)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 15))
                    .foregroundStyle(DSHTheme.assistantText)
                    .lineLimit(1)
                Text(subtitle(item))
                    .font(.system(size: 11))
                    .foregroundStyle(DSHTheme.tertiaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private func iconName(_ item: WorkspaceStore.Item) -> String {
        if item.isDirectory { return "folder.fill" }
        if WorkspaceStore.isImageFile(item.url) { return "photo" }
        if WorkspaceStore.isTextFile(item.url) { return "doc.text" }
        return "doc"
    }

    private func subtitle(_ item: WorkspaceStore.Item) -> String {
        if item.isDirectory { return "文件夹" }
        let date = Self.formatter.string(from: item.modifiedAt)
        return "\(WorkspaceStore.sizeText(item.size)) · \(date)"
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 24))
                .foregroundStyle(DSHTheme.tertiaryText)
            Text("这里还没有文件，点右上角「+」新建")
                .font(.system(size: 14))
                .foregroundStyle(DSHTheme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .accessibilityIdentifier("files.empty")
    }

    // MARK: - 弹窗绑定

    private var renamePresented: Binding<Bool> {
        Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )
    }

    private var deletePresented: Binding<Bool> {
        Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )
    }

    private var editorPresented: Binding<Bool> {
        Binding(
            get: { pendingEditorURL != nil },
            set: { if !$0 { pendingEditorURL = nil } }
        )
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { workspace.errorText != nil },
            set: { if !$0 { workspace.errorText = nil } }
        )
    }

    private func createFile() {
        // 新建成功直接进入编辑器，符合「建完就写」的使用直觉
        if let url = workspace.createFile(named: newFileName) {
            pendingEditorURL = url
        }
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()
}

// MARK: - 代码编辑器（IDE）

/// 内置代码编辑器：等宽字体 + 保存状态提示，离开页面时自动保存未保存的改动。
struct CodeEditorPage: View {
    let url: URL

    @EnvironmentObject private var workspace: WorkspaceStore

    @State private var text = ""
    @State private var savedText = ""
    @State private var isLoaded = false
    @State private var savedAt: Date?

    private var isDirty: Bool { isLoaded && text != savedText }

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $text)
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(DSHTheme.assistantText)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .accessibilityIdentifier("files.editor.text")

            statusBar
        }
        .background(DSHTheme.page)
        .navigationTitle(url.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("保存") { save() }
                    .disabled(!isDirty)
                    .accessibilityIdentifier("files.editor.save")
            }
        }
        .onAppear(perform: load)
        .onDisappear {
            // 返回时兜底保存：手机上很容易忘记点「保存」，改动不能丢
            if isDirty { save() }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 6) {
            Text(isDirty ? "未保存" : savedAt == nil ? "已就绪" : "已保存")
                .foregroundStyle(isDirty ? DSHTheme.warning : DSHTheme.tertiaryText)
            Text("·")
            Text("\(lineCount) 行")
            Text("·")
            Text("\(text.count) 字符")
            Spacer(minLength: 0)
            Text("UTF-8")
        }
        .font(.system(size: 11))
        .foregroundStyle(DSHTheme.tertiaryText)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(DSHTheme.grouped)
    }

    private var lineCount: Int {
        text.isEmpty ? 0 : text.components(separatedBy: "\n").count
    }

    private func load() {
        guard !isLoaded else { return }
        let content = workspace.read(url) ?? ""
        text = content
        savedText = content
        isLoaded = true
    }

    private func save() {
        guard workspace.write(text, to: url) else { return }
        savedText = text
        savedAt = Date()
    }
}

// MARK: - 图片预览

/// 图片文件预览：等比展示，可分享导出
private struct ImagePreviewPage: View {
    let url: URL

    var body: some View {
        ScrollView {
            if let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .padding(DSHTheme.Spacing.large)
            } else {
                Text("无法预览这张图片")
                    .font(.system(size: 14))
                    .foregroundStyle(DSHTheme.secondaryText)
                    .padding(.top, 40)
            }
        }
        .background(DSHTheme.page)
        .navigationTitle(url.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
    }
}