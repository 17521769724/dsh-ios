import SwiftUI
import UIKit

/// 根视图：未配置 API Key 时强制走引导页；配置后进入极简主页。
/// iPhone 为抽屉式会话列表，iPad 为分栏布局。
struct RootView: View {
    @EnvironmentObject private var engine: ChatEngine
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var plugins: PluginManager
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var drawerOpen = false
    @State private var dragOffset: CGFloat = 0
    /// 本次拖拽是否为横向（只有横向拖拽才驱动抽屉，避免与列表纵向滚动抢手势产生抖动）
    @State private var isHorizontalDrag = false
    @State private var showSettings = false
    @State private var showPlugins = false
    @State private var showSessionLog = false

    private var settings: AppSettings { settingsStore.settings }
    private var features: FeatureFlags { settings.features }

    private var isRegular: Bool { sizeClass == .regular }
    private var drawerWidth: CGFloat { isRegular ? 320 : min(320, UIScreen.main.bounds.width * 0.82) }

    var body: some View {
        Group {
            // 在设置里编辑 Key 时（可能被清空）不立刻跳回引导页，
            // 只有显式「清除 API Key」或关闭全部浮层后才回到引导页。
            if settingsStore.isConfigured || isAnyOverlayPresented {
                mainInterface
            } else {
                OnboardingView()
            }
        }
        .dshAppearance(settings.appTheme)
        // 全局：点击空白区域收起键盘（点击输入框内部不收起）
        .background(alignment: .topLeading) {
            TapToDismissKeyboard()
                .frame(width: 1, height: 1)
        }
        .onChange(of: settingsStore.onboardingRequested) { requested in
            guard requested else { return }
            settingsStore.onboardingRequested = false
            showPlugins = false
            showSessionLog = false
            showSettings = false
        }
    }

    private var isAnyOverlayPresented: Bool {
        showSettings || showPlugins || showSessionLog
    }

    // MARK: - 主界面

    private var mainInterface: some View {
        ZStack(alignment: .leading) {
            if isRegular {
                HStack(spacing: 0) {
                    drawer(embedded: true)
                        .frame(width: drawerWidth)
                    Divider()
                    navigationLayer
                }
            } else {
                navigationLayer

                if drawerOpen {
                    Color.black.opacity(0.3 * scrimProgress)
                        .ignoresSafeArea()
                        .onTapGesture { closeDrawer() }
                        .transition(.opacity)
                }

                drawer(embedded: false)
                    .frame(width: drawerWidth)
                    .background(DSHTheme.page.ignoresSafeArea())
                    .offset(x: drawerOffset)
                    .gesture(dragToClose)
            }

            toastOverlay
        }
        .animation(DSHAnim.drawer, value: drawerOpen)
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(engine)
                .environmentObject(engine.settingsStore)
                .environmentObject(engine.sshStore)
                .environmentObject(plugins)
        }
        // 内置浏览器：模型工具调用或手动入口触发
        .sheet(item: $engine.browserRequest) { request in
            BrowserView(initialURL: request.url)
                .environmentObject(settingsStore)
                .dshAppearance(settings.appTheme)
        }
        .sheet(isPresented: $showPlugins) {
            NavigationStack {
                PluginsView()
                    .environmentObject(plugins)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("关闭") { showPlugins = false }
                        }
                    }
            }
            .dshAppearance(settings.appTheme)
        }
        .sheet(isPresented: $showSessionLog) {
            NavigationStack {
                TrajectoryView()
                    .environmentObject(engine)
                    .navigationTitle("会话日志")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("完成") { showSessionLog = false }
                        }
                    }
            }
            .dshAppearance(settings.appTheme)
        }
        .alert("出错了", isPresented: Binding(
            get: { engine.lastError != nil },
            set: { if !$0 { engine.lastError = nil } }
        )) {
            Button("好的", role: .cancel) { engine.lastError = nil }
        } message: {
            Text(engine.lastError ?? "")
        }
    }

    // MARK: - 导航层（原生导航栏 + 对话页）

    private var navigationLayer: some View {
        NavigationStack {
            ChatView()
                .navigationTitle(navigationTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if !isRegular {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button {
                                openDrawer()
                            } label: {
                                // 打开侧栏：面板样式的侧栏图标，和右上角的「菜单」区分开
                                Image(systemName: "sidebar.left")
                                    .font(.system(size: 17, weight: .medium))
                                    .foregroundStyle(DSHTheme.assistantText)
                            }
                            .accessibilityIdentifier("topbar.sidebar")
                            .accessibilityLabel("会话列表")
                        }
                    }

                    ToolbarItem(placement: .navigationBarTrailing) {
                        // 右上角合并为一个功能菜单：新对话 / 置顶 / 删除 / 会话日志 / 内置浏览器
                        // 其中会话日志与内置浏览器仍受设置开关控制，关闭后不会出现在菜单里。
                        Menu {
                            Button {
                                engine.newConversation()
                            } label: {
                                Label("新对话", systemImage: "square.and.pencil")
                            }
                            .accessibilityIdentifier("menu.newChat")

                            if let conversation = engine.currentConversation {
                                Button {
                                    engine.togglePin(conversation)
                                } label: {
                                    Label(
                                        conversation.isPinned ? "取消置顶" : "置顶",
                                        systemImage: conversation.isPinned ? "pin.slash" : "pin"
                                    )
                                }
                                .accessibilityIdentifier("menu.pin")

                                Button(role: .destructive) {
                                    engine.delete(conversation)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                                .accessibilityIdentifier("menu.delete")
                            }

                            if features.sessionLog {
                                Button {
                                    showSessionLog = true
                                } label: {
                                    Label("会话日志", systemImage: "list.bullet.rectangle")
                                }
                                .accessibilityIdentifier("menu.sessionLog")
                            }

                            if features.browserTool {
                                Button {
                                    engine.openBrowser(settings.browser.homeLink)
                                } label: {
                                    Label("内置浏览器", systemImage: "safari")
                                }
                                .accessibilityIdentifier("menu.browser")
                            }
                        } label: {
                            // 菜单图标：三条横线右对齐、上长下短，与左侧栏图标同尺寸
                            DSHMenuGlyph()
                        }
                        .accessibilityIdentifier("topbar.menu")
                        .accessibilityLabel("菜单")
                    }
                }
        }
    }

    private var navigationTitle: String {
        guard let conversation = engine.currentConversation else { return "DeepSeek" }
        return conversation.messages.isEmpty ? "DeepSeek" : conversation.title
    }

    // MARK: - 抽屉

    @ViewBuilder
    private func drawer(embedded: Bool) -> some View {
        SidebarView(
            close: { if !embedded { closeDrawer() } },
            openSettings: { presentOverlay { showSettings = true } },
            openPlugins: { presentOverlay { showPlugins = true } }
        )
        // 搜索框聚焦弹出键盘时，抽屉底部的「插件中心 / 设置」保持固定在屏幕底部，
        // 不随键盘上移（被键盘遮挡也保持原位置）。
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }

    /// 先让浮层（设置/插件）升起，再让抽屉在其遮挡下收起，
    /// 避免「抽屉收起」与「浮层弹出」两个动画叠加时露出主页造成闪屏。
    private func presentOverlay(_ present: () -> Void) {
        present()
        guard !isRegular else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if drawerOpen { closeDrawer() }
        }
    }

    // MARK: - Toast

    @ViewBuilder
    private var toastOverlay: some View {
        if let toast = engine.toast {
            VStack {
                Spacer()
                Text(toast)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(DSHTheme.page)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(DSHTheme.assistantText.opacity(0.88))
                    .clipShape(Capsule())
                    .padding(.bottom, 120)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .allowsHitTesting(false)
        }
    }

    // MARK: - 抽屉手势

    private var scrimProgress: CGFloat {
        guard drawerWidth > 0 else { return 0 }
        return min(1, max(0, 1 + dragOffset / drawerWidth))
    }

    private var drawerOffset: CGFloat {
        drawerOpen ? (dragOffset < 0 ? dragOffset : 0) : -drawerWidth
    }

    private var dragToClose: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                let horizontal = abs(value.translation.width) > abs(value.translation.height)
                // 纵向滑动交给列表滚动，避免抽屉跟着抖动
                guard horizontal else { return }
                isHorizontalDrag = true
                dragOffset = min(0, value.translation.width)
            }
            .onEnded { value in
                defer { isHorizontalDrag = false }
                guard isHorizontalDrag else { return }
                let shouldClose = value.translation.width < -drawerWidth * 0.3
                    || value.predictedEndTranslation.width < -drawerWidth * 0.6
                if shouldClose {
                    closeDrawer()
                } else {
                    withAnimation(DSHAnim.drawer) { dragOffset = 0 }
                }
            }
    }

    private func openDrawer() {
        // 抽屉底部的「插件中心 / 设置」固定在屏幕底部不随键盘上移，
        // 因此打开抽屉时先收起键盘，避免这两个入口被键盘盖住点不到。
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
        dragOffset = 0
        withAnimation(DSHAnim.drawer) { drawerOpen = true }
        if settings.hapticsEnabled {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    private func closeDrawer() {
        // 收起抽屉时一并收起键盘（点搜索框后点空白处关闭抽屉，键盘不应还留在屏幕上）
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
        withAnimation(DSHAnim.drawer) {
            drawerOpen = false
            dragOffset = 0
        }
    }
}