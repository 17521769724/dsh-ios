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
                    Color.black.opacity(0.28 * scrimProgress)
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
                .environmentObject(plugins)
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
                                Image(systemName: "line.3.horizontal")
                                    .font(.system(size: 16, weight: .medium))
                            }
                            .accessibilityIdentifier("topbar.sidebar")
                            .accessibilityLabel("会话列表")
                        }
                    }

                    ToolbarItemGroup(placement: .navigationBarTrailing) {
                        if features.sessionLog {
                            Button {
                                showSessionLog = true
                            } label: {
                                Image(systemName: "list.bullet.rectangle")
                                    .font(.system(size: 15))
                            }
                            .accessibilityIdentifier("topbar.sessionlog")
                            .accessibilityLabel("会话日志")
                        }

                        Button {
                            engine.newConversation()
                        } label: {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 16))
                        }
                        .accessibilityIdentifier("topbar.newchat")
                        .accessibilityLabel("新对话")
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
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(Color.black.opacity(0.8))
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
                dragOffset = min(0, value.translation.width)
            }
            .onEnded { value in
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
        dragOffset = 0
        withAnimation(DSHAnim.drawer) { drawerOpen = true }
        if settings.hapticsEnabled {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    private func closeDrawer() {
        withAnimation(DSHAnim.drawer) {
            drawerOpen = false
            dragOffset = 0
        }
    }
}