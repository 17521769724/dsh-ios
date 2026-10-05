import SwiftUI
import UIKit

/// 根视图：iPhone 使用抽屉式侧边栏，iPad 使用分栏布局。
struct RootView: View {
    @EnvironmentObject private var engine: ChatEngine
    @EnvironmentObject private var plugins: PluginManager
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var sidebarOpen = false
    @State private var dragOffset: CGFloat = 0
    @State private var showSettings = false
    @State private var showPlugins = false
    @State private var showSessionLog = false

    private var isRegular: Bool { sizeClass == .regular }
    private var sidebarWidth: CGFloat { isRegular ? 300 : min(310, UIScreen.main.bounds.width * 0.84) }

    var body: some View {
        ZStack(alignment: .leading) {
            if isRegular {
                HStack(spacing: 0) {
                    SidebarView(close: {}, openPlugins: { showPlugins = true }, openSettings: { showSettings = true })
                        .frame(width: sidebarWidth)
                    Divider().opacity(0.5)
                    mainColumn
                }
            } else {
                mainColumn

                if sidebarOpen {
                    Color.black.opacity(0.32 * scrimProgress)
                        .ignoresSafeArea()
                        .onTapGesture { closeSidebar() }
                        .transition(.opacity)
                }

                SidebarView(close: { closeSidebar() }, openPlugins: { showPlugins = true; closeSidebar() }, openSettings: { showSettings = true; closeSidebar() })
                    .frame(width: sidebarWidth)
                    .offset(x: sidebarOffset)
                    .gesture(dragToClose)
            }

            toastOverlay
        }
        .animation(DSHAnim.sheet, value: sidebarOpen)
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(engine)
                .environmentObject(engine.settingsStore)
                .environmentObject(plugins)
        }
        .sheet(isPresented: $showPlugins) {
            PluginsView()
                .environmentObject(engine)
                .environmentObject(plugins)
        }
        .sheet(isPresented: $showSessionLog) {
            NavigationStack {
                TrajectoryView()
                    .environmentObject(engine)
                    .navigationTitle("会话日志")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("关闭") { showSessionLog = false }
                        }
                    }
            }
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

    // MARK: - 主区域

    private var mainColumn: some View {
        VStack(spacing: 0) {
            TopBar(
                openSidebar: { openSidebar() },
                showSettings: { showSettings = true },
                showPlugins: { showPlugins = true },
                showSessionLog: { showSessionLog = true }
            )
            Divider().opacity(0.5)
            ChatView()
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
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.78))
                    .clipShape(Capsule())
                    .padding(.bottom, 120)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .allowsHitTesting(false)
        }
    }

    // MARK: - 抽屉手势

    private var scrimProgress: CGFloat {
        guard sidebarWidth > 0 else { return 0 }
        return min(1, max(0, 1 + dragOffset / sidebarWidth))
    }

    private var sidebarOffset: CGFloat {
        sidebarOpen ? (dragOffset < 0 ? dragOffset : 0) : -sidebarWidth
    }

    private var dragToClose: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                dragOffset = min(0, value.translation.width)
            }
            .onEnded { value in
                let shouldClose = value.translation.width < -sidebarWidth * 0.3
                    || value.predictedEndTranslation.width < -sidebarWidth * 0.6
                if shouldClose {
                    closeSidebar()
                } else {
                    withAnimation(DSHAnim.sheet) { dragOffset = 0 }
                }
            }
    }

    private func openSidebar() {
        dragOffset = 0
        withAnimation(DSHAnim.sheet) { sidebarOpen = true }
        if engine.settingsStore.settings.hapticsEnabled {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    private func closeSidebar() {
        withAnimation(DSHAnim.sheet) {
            sidebarOpen = false
            dragOffset = 0
        }
    }
}

// MARK: - 顶部栏

struct TopBar: View {
    @EnvironmentObject private var engine: ChatEngine
    @Environment(\.horizontalSizeClass) private var sizeClass

    var openSidebar: () -> Void
    var showSettings: () -> Void
    var showPlugins: () -> Void
    var showSessionLog: () -> Void

    var body: some View {
        HStack(spacing: DSHTheme.Spacing.small) {
            if sizeClass != .regular {
                Button(action: openSidebar) {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("打开会话列表")
            }

            Text(engine.currentConversation?.title ?? "DSH iOS")
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)

            modeChip

            Spacer(minLength: 8)

            Button(action: showSessionLog) {
                HStack(spacing: 4) {
                    Text("会话日志")
                        .font(.system(size: 11, weight: .medium))
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 10))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(DSHTheme.elevatedBackground)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(DSHTheme.separator, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("查看会话日志")

            Menu {
                Button {
                    engine.newConversation()
                } label: {
                    Label("新建会话", systemImage: "square.and.pencil")
                }
                Button {
                    engine.regenerateLast()
                } label: {
                    Label("重新生成", systemImage: "arrow.clockwise")
                }
                .disabled(engine.isStreaming)
                Divider()
                Button {
                    showPlugins()
                } label: {
                    Label("插件中心", systemImage: "puzzlepiece.extension")
                }
                Button {
                    showSettings()
                } label: {
                    Label("设置", systemImage: "gearshape")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 17))
                    .foregroundStyle(.primary)
                    .frame(width: 28, height: 28)
            }
            .accessibilityLabel("更多操作")
        }
        .padding(.horizontal, DSHTheme.Spacing.large)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var modeChip: some View {
        HStack(spacing: 3) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 9, weight: .bold))
            Text("标准模式")
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(DSHTheme.elevatedBackground)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(DSHTheme.separator, lineWidth: 0.5))
    }
}