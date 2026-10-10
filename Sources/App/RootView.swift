import SwiftUI
import UIKit

/// 新功能弹窗：每个版本首次打开主界面时弹一次，告知本次新增能力（用户要求：新增功能要有弹窗提示）
enum ReleaseNotes {
    /// 已提示过的版本号（UserDefaults）
    static let seenKey = "dsh.releaseNotes.seenVersion"

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    /// 本次更新说明
    static let message = """
    本次更新（2.6.0）：
    • SSH 云服务器支持添加多台，每台独立配置与左滑删除；智能体可用 server 参数指定用哪一台；
    • 云端推理「SSH 服务器」改为多选：部署与推理都走你选中的那台；
    • 连接测试（模型服务 / SSH / MCP 连接并刷新）与 SSH 命令结果统一改为弹窗提示；
    • MCP 服务器列表卡片宽度对齐、去掉多余分割线；详情页「连接并刷新」下方只显示最近连接时间。

    「云端推理」回顾（2.5.0）：
    • 一键把 SSH 云服务器变成 Agent 工作环境；会话交由云服务器推理、流式返回本机；
    • App 退到后台推理不中断，回到前台自动补齐；云端沙盒可暂停 / 恢复 / 销毁，支持文件上传下载；
    • 模型 Key 只保存在本机钥匙串并随请求下发，服务器不留存。

    本机直连模式保持不变，两个模式可在「云端推理」页里随时切换。
    """
}

/// 根视图：未配置 API Key 时强制走引导页；配置后进入极简主页。
/// iPhone 为抽屉式会话列表，iPad 为分栏布局。
struct RootView: View {
    @EnvironmentObject private var engine: ChatEngine
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var plugins: PluginManager
    @EnvironmentObject private var skillStore: SkillStore
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var drawerOpen = false
    @State private var dragOffset: CGFloat = 0
    /// 本次拖拽是否为横向（只有横向拖拽才驱动抽屉，避免与列表纵向滚动抢手势产生抖动）
    @State private var isHorizontalDrag = false
    @State private var showSettings = false
    @State private var showPlugins = false
    @State private var showSkills = false
    @State private var showFiles = false
    @State private var showSessionLog = false
    /// 首次启动的权限申请引导
    @State private var showPermissionsPrimer = false
    /// 新功能弹窗（每个版本一次）
    @State private var showReleaseNotes = false
    @StateObject private var permissions = PermissionCenter()
    /// 启动阶段是否已经稳定：首帧布局就绪前屏蔽隐式动画，
    /// 否则冷启动时（顶栏、抽屉）会播放一次位移动画，看起来就是「图标跳动」
    @State private var hasSettled = false
    /// 抽屉宽度在启动时算一次就固定：冷启动首帧屏幕尺寸未就绪时宽度变化会让抽屉闪现、顶栏图标跳动
    @State private var drawerWidth: CGFloat = RootView.initialDrawerWidth

    private var settings: AppSettings { settingsStore.settings }
    private var features: FeatureFlags { settings.features }

    private var isRegular: Bool { sizeClass == .regular }

    /// 启动时的抽屉宽度：手机约为屏宽的 82%（上限 320），iPad 固定 320
    private static var initialDrawerWidth: CGFloat {
        min(320, max(280, UIScreen.main.bounds.width * 0.82))
    }

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
        // 首帧稳定前不播放隐式动画：冷启动时布局还在收敛，播放动画会表现为顶栏图标「跳动」
        .transaction { transaction in
            if !hasSettled { transaction.animation = nil }
        }
        .onAppear {
            guard !hasSettled else { return }
            DispatchQueue.main.async { hasSettled = true }
        }
        .task {
            // 首次启动：进入主界面后弹出权限申请引导（提醒事项 / 日历 / 剪贴板），只弹一次
            guard settingsStore.isConfigured, !permissions.hasPrimed else { return }
            showPermissionsPrimer = true
        }
        .task {
            // 新功能弹窗：每个版本首次打开时弹一次（告知本次新增能力）
            guard settingsStore.isConfigured else { return }
            guard UserDefaults.standard.string(forKey: ReleaseNotes.seenKey) != ReleaseNotes.currentVersion else { return }
            try? await Task.sleep(nanoseconds: 600_000_000)
            showReleaseNotes = true
        }
        // 全局：点击空白区域收起键盘（点击输入框内部不收起）
        .background(alignment: .topLeading) {
            TapToDismissKeyboard()
                .frame(width: 1, height: 1)
        }
        .onChange(of: settingsStore.onboardingRequested) { requested in
            guard requested else { return }
            settingsStore.onboardingRequested = false
            showPlugins = false
            showSkills = false
            showFiles = false
            showSessionLog = false
            showSettings = false
        }
    }

    private var isAnyOverlayPresented: Bool {
        showSettings || showPlugins || showSkills || showFiles || showSessionLog
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
                    // 关闭时同时置为透明：冷启动首帧几何尚未就绪时也不会闪现抽屉
                    .opacity(drawerOpen ? 1 : 0)
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
                .environmentObject(engine.gitStore)
                .environmentObject(plugins)
                .environmentObject(skillStore)
                .environmentObject(engine.mcpStore)
                .environmentObject(engine.cloudStore)
        }
        // 首次进入主界面：把本 App 需要的系统权限（提醒事项 / 日历 / 剪贴板）走一遍
        .sheet(isPresented: $showPermissionsPrimer) {
            NavigationStack {
                PermissionsView(isPrimer: true)
            }
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
        .sheet(isPresented: $showSkills) {
            NavigationStack {
                SkillsView()
                    .environmentObject(skillStore)
                    .environmentObject(settingsStore)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("关闭") { showSkills = false }
                        }
                    }
            }
            .dshAppearance(settings.appTheme)
        }
        // 内置文件管理器 + IDE：与智能体的「工作区文件」工具共用同一批文件
        .sheet(isPresented: $showFiles) {
            NavigationStack {
                FilesView()
                    .environmentObject(engine.workspaceStore)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("完成") { showFiles = false }
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
        // 每个版本首次打开时的「新功能」弹窗（用户要求：新增能力要有弹窗告知）
        .alert("新功能 · 云端推理", isPresented: $showReleaseNotes) {
            Button("稍后再说", role: .cancel) {
                UserDefaults.standard.set(ReleaseNotes.currentVersion, forKey: ReleaseNotes.seenKey)
            }
            Button("去设置看看") {
                UserDefaults.standard.set(ReleaseNotes.currentVersion, forKey: ReleaseNotes.seenKey)
                presentOverlay { showSettings = true }
            }
        } message: {
            Text(ReleaseNotes.message)
        }
    }

    // MARK: - 导航层（原生导航栏 + 对话页）

    private var navigationLayer: some View {
        NavigationStack {
            ChatView()
                .navigationTitle(navigationTitle)
                .navigationBarTitleDisplayMode(.inline)
                // 列表向下滚动时，标题栏固定用页面底色铺底，不再透出下方内容
                .toolbarBackground(DSHTheme.page, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
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

                                if !conversation.messages.isEmpty {
                                    Button {
                                        Task { await engine.compactContext() }
                                    } label: {
                                        Label("压缩上下文", systemImage: "arrow.down.right.and.arrow.up.left")
                                    }
                                    .accessibilityIdentifier("menu.compact")
                                    .disabled(engine.isStreaming || engine.compacting)
                                }
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
            openPlugins: { presentOverlay { showPlugins = true } },
            openSkills: { presentOverlay { showSkills = true } },
            openFiles: { presentOverlay { showFiles = true } }
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