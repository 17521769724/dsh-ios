import SwiftUI

// MARK: - 设置主页入口行

/// 「清理缓存」入口：先算出可清理的大小，再进入二级页面
struct CacheCleanupRow: View {
    @EnvironmentObject private var engine: ChatEngine

    @State private var cleanableBytes = 0

    var body: some View {
        SettingsValueRow(
            symbol: "trash.fill",
            color: .orange,
            title: "清理缓存",
            value: cleanableBytes > 0 ? "\(AppCache.format(cleanableBytes)) 可清理" : "无需清理"
        )
        .onAppear(perform: refresh)
    }

    private func refresh() {
        let conversations = engine.conversationStore.conversations
        let drafts = engine.draftImages
        Task.detached(priority: .utility) {
            let bytes = AppCache.snapshot(conversations: conversations, drafts: drafts).cleanableBytes
            await MainActor.run { cleanableBytes = bytes }
        }
    }
}

// MARK: - 清理缓存

/// 清理缓存：统计并清理会随时间累积的本地缓存。
/// 会话中正在使用的图片属于聊天记录（删除会话或消息时自动删除），
/// 这里清理的是已失效图片、临时文件与网络缓存。
struct CacheCleanupSettingsView: View {
    @EnvironmentObject private var engine: ChatEngine

    @State private var snapshot = AppCache.Snapshot.empty
    @State private var cleaning = false
    @State private var showConfirm = false
    @State private var clearedMessage: String?

    var body: some View {
        List {
            Section {
                LabeledContent("图片（会话中）", value: AppCache.format(snapshot.inUseImageBytes))
                LabeledContent("图片（已失效）", value: AppCache.format(snapshot.orphanImageBytes))
                LabeledContent("临时文件", value: AppCache.format(snapshot.temporaryBytes))
                LabeledContent("网络缓存", value: AppCache.format(snapshot.urlCacheBytes))
            } header: {
                Text("缓存占用")
            } footer: {
                Text("「会话中」的图片会随聊天记录一直保留，删除会话或消息时自动删除对应图片；「已失效」图片是历史版本遗留的残留文件，可以放心清理。")
            }

            Section {
                Button(role: .destructive) {
                    showConfirm = true
                } label: {
                    HStack(spacing: DSHTheme.Spacing.small) {
                        Label("立即清理", systemImage: "trash")
                        Spacer(minLength: DSHTheme.Spacing.small)
                        if cleaning {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(AppCache.format(snapshot.cleanableBytes))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .disabled(cleaning || snapshot.cleanableBytes == 0)
                .accessibilityIdentifier("cache.clean")
            } header: {
                Text("清理")
            } footer: {
                Text("清理已失效图片、临时文件与网络缓存，不影响会话文字与会话中的图片。内置浏览器的网页缓存与 Cookie 请在「浏览器设置」中清理。")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("清理缓存")
        .navigationBarTitleDisplayMode(.inline)
        .tint(DSHTheme.brand)
        .task { await refresh() }
        .confirmationDialog("确定清理缓存？", isPresented: $showConfirm, titleVisibility: .visible) {
            Button("清理", role: .destructive) { clean() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将释放约 \(AppCache.format(snapshot.cleanableBytes))。")
        }
        .alert("清理完成", isPresented: Binding(
            get: { clearedMessage != nil },
            set: { if !$0 { clearedMessage = nil } }
        )) {
            Button("好的", role: .cancel) {}
        } message: {
            Text(clearedMessage ?? "")
        }
    }

    @MainActor
    private func refresh() async {
        let conversations = engine.conversationStore.conversations
        let drafts = engine.draftImages
        snapshot = await Task.detached(priority: .userInitiated) {
            AppCache.snapshot(conversations: conversations, drafts: drafts)
        }.value
    }

    private func clean() {
        cleaning = true
        let conversations = engine.conversationStore.conversations
        let drafts = engine.draftImages
        Task {
            let freed = await Task.detached(priority: .userInitiated) {
                AppCache.clean(conversations: conversations, drafts: drafts)
            }.value
            await refresh()
            cleaning = false
            clearedMessage = "已释放 \(AppCache.format(freed)) 存储空间。"
        }
    }
}