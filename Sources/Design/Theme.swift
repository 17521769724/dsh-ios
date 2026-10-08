import SwiftUI
import UIKit

/// 视觉规范：对齐 iOS DeepSeek 官方客户端。
///
/// 颜色全部按浅/深两套取值，切换外观时由窗口级交叉淡入淡出接管；
/// 品牌蓝取官方主色 #4D6BFE，灰阶使用中性偏冷的浅灰，避免出现偏黄的系统灰。
enum DSHTheme {

    // MARK: - 品牌色

    /// 官方主色 #4D6BFE
    static let brand = Color(uiColor: UIColor(dshRGB: 0x4D6BFE))
    /// 品牌浅底：选中态胶囊、工具调用卡片
    static let brandSoft = Color(uiColor: UIColor(dshRGB: 0x4D6BFE)).opacity(0.12)

    // MARK: - 语义色（浅色 / 深色两套）

    static let page = dynamic(light: 0xFFFFFF, dark: 0x1A1A1A)
    static let grouped = dynamic(light: 0xF5F6F8, dark: 0x26272B)
    /// 用户气泡：官方为中性浅灰
    static let userBubble = dynamic(light: 0xEFF1F5, dark: 0x2C2D32)
    static let userText = dynamic(light: 0x1A1A1A, dark: 0xEDEDED)
    /// 助手消息直接铺在页面背景上，无气泡
    static let assistantText = dynamic(light: 0x1A1A1A, dark: 0xEDEDED)
    /// 输入卡片底色
    static let composerCard = dynamic(light: 0xF5F6F8, dark: 0x26272B)
    /// 选中会话行底色：不透明（长按预览时不会透出下方内容），
    /// 视觉上等价于品牌色 12% 叠在输入卡片底色上
    static let rowSelected = dynamic(light: 0xE1E5F9, dark: 0x2B2F44)
    /// 未激活胶囊底色（比输入卡片底色深一档，保证胶囊可辨识）
    static let chipFill = dynamic(light: 0xE7EAEF, dark: 0x35363D)
    static let reasoningBackground = dynamic(light: 0xF5F6F8, dark: 0x26272B)
    static let separator = dynamic(light: 0xE9EAEE, dark: 0x303136)

    static let secondaryText = dynamic(light: 0x8A8F99, dark: 0x9B9EA5)
    static let tertiaryText = dynamic(light: 0xB4B8C0, dark: 0x6E7076)

    /// 发送键空闲态：灰底 + 灰箭头（与官方一致，比胶囊再深一档）
    static let sendIdle = dynamic(light: 0xDFE3EA, dark: 0x3C3D45)
    static let sendIdleIcon = dynamic(light: 0xA8ADB8, dark: 0x6E7076)

    static let danger = Color(uiColor: .systemRed)
    static let warning = Color(uiColor: .systemOrange)
    static let success = Color(uiColor: .systemGreen)

    // MARK: - 尺寸

    enum Radius {
        /// 输入卡片
        static let composer: CGFloat = 24
        static let bubble: CGFloat = 18
        static let card: CGFloat = 14
        static let chip: CGFloat = 10
        /// 侧栏会话行
        static let row: CGFloat = 12
    }

    enum Spacing {
        static let tight: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let section: CGFloat = 24
    }

    /// 消息区域左右边距
    static let messageHorizontalPadding: CGFloat = 16

    // MARK: - 构造

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(dshRGB: dark) : UIColor(dshRGB: light)
        })
    }
}

/// 交互动效：统一使用官方客户端的「轻弹簧 + 短淡入」，克制、不抢注意力。
enum DSHAnim {
    /// 常规状态切换（胶囊选中、描边、图标切换）
    static let standard = Animation.easeInOut(duration: 0.24)
    /// 列表插入与删除
    static let list = Animation.spring(response: 0.36, dampingFraction: 0.9)
    /// 抽屉与遮罩
    static let drawer = Animation.spring(response: 0.34, dampingFraction: 0.9)
    /// 流式文本刷新
    static let stream = Animation.linear(duration: 0.08)
    /// 深浅色切换
    static let appearance = Animation.easeInOut(duration: 0.3)
    /// 按钮按压回弹
    static let press = Animation.spring(response: 0.26, dampingFraction: 0.72)
    /// 键盘 / 输入区高度变化
    static let composer = Animation.spring(response: 0.32, dampingFraction: 0.9)
}

/// 按压反馈：缩放 + 轻微变淡，用于发送键、胶囊与列表行。
struct DSHPressStyle: ButtonStyle {
    var scale: CGFloat = 0.92

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(DSHAnim.press, value: configuration.isPressed)
    }
}

/// DeepSeek 鲸鱼标识：模板着色，随主题与强调色变化。
struct DSHWhaleMark: View {
    var size: CGFloat
    var color: Color = DSHTheme.brand

    var body: some View {
        Image("DeepSeekWhale")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// 助手标识：深色圆角方块 + 鲸鱼，用在对话页每条模型回复的头部
struct DSHAssistantAvatar: View {
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(DSHTheme.assistantText)
            .frame(width: size, height: size)
            .overlay(DSHWhaleMark(size: size * 0.62, color: DSHTheme.page))
            .accessibilityHidden(true)
    }
}

/// 顶栏右侧的菜单图标：三条横线，右对齐、自上而下依次变短，
/// 体量与左侧栏图标一致（横向 18pt，线条 2pt 左右）。
struct DSHMenuGlyph: View {
    var size: CGFloat = 18
    var color: Color = DSHTheme.assistantText

    var body: some View {
        VStack(alignment: .trailing, spacing: size * 0.2) {
            ForEach(0..<3) { index in
                Capsule(style: .continuous)
                    .fill(color)
                    .frame(width: size * (1 - CGFloat(index) * 0.3), height: size * 0.12)
            }
        }
        .frame(width: size, alignment: .trailing)
        .accessibilityHidden(true)
    }
}

/// 深浅色切换走窗口级交叉淡入淡出，避免整屏颜色生硬跳变。
/// 同步设置 window 样式，保证快照里已经带上新配色，交叉淡化才可见。
@MainActor
func dshApplyAppearanceChange(
    to preference: AppThemePreference,
    duration: Double = 0.3,
    _ changes: @escaping () -> Void
) {
    guard let window = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene })
        .flatMap({ $0.windows })
        .first(where: { $0.isKeyWindow }) else {
        changes()
        return
    }
    UIView.transition(
        with: window,
        duration: duration,
        options: [.transitionCrossDissolve, .allowUserInteraction]
    ) {
        window.overrideUserInterfaceStyle = preference.uiInterfaceStyle
        changes()
    }
}

extension View {
    /// 卡片风格：分组底色 + 细描边
    func dshCard(background: Color = DSHTheme.grouped) -> some View {
        self
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: DSHTheme.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DSHTheme.Radius.card, style: .continuous)
                    .stroke(DSHTheme.separator.opacity(0.6), lineWidth: 0.5)
            )
    }

    /// 统一应用主题偏好。
    ///
    /// 这里刻意不用 SwiftUI 的 `preferredColorScheme`：它把偏好写进场景后，
    /// 从「深色」切回「跟随系统」时传 nil 并不会撤销已生效的深色，
    /// 设置页会一直停留在深色（点「浅色」因为是一个新的具体值才会立刻刷新）。
    /// 改为在窗口层直接设置 `overrideUserInterfaceStyle`：深浅与跟随系统都能立即生效，
    /// 而且对设置这类 sheet 浮层同样有效。需要在每个浮层（sheet）的根视图上单独调用。
    func dshAppearance(_ preference: AppThemePreference) -> some View {
        background(WindowAppearanceBinder(preference: preference))
    }
}

/// 把外观偏好写到所在窗口：窗口 trait 变化后，整个界面（含 sheet）立即重绘。
private struct WindowAppearanceBinder: UIViewRepresentable {
    let preference: AppThemePreference

    func makeUIView(context: Context) -> UIView {
        let view = AppearanceProbeView()
        view.apply(preference)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        (uiView as? AppearanceProbeView)?.apply(preference)
    }
}

/// 零尺寸探针：进入窗口或偏好变化时，把样式写到窗口上
private final class AppearanceProbeView: UIView {
    private var preference: AppThemePreference?

    func apply(_ preference: AppThemePreference) {
        self.preference = preference
        guard let window else { return }
        applyToWindow(window)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let window, let preference else { return }
        applyToWindow(window)
    }

    private func applyToWindow(_ window: UIWindow) {
        let style = preference?.uiInterfaceStyle ?? .unspecified
        guard window.overrideUserInterfaceStyle != style else { return }
        window.overrideUserInterfaceStyle = style
    }
}

extension AppThemePreference {
    /// 供窗口级交叉淡入淡出使用
    var uiInterfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: return .unspecified
        case .light: return .light
        case .dark: return .dark
        }
    }
}

extension UIColor {
    /// 0xRRGGBB 形式的品牌色构造
    convenience init(dshRGB value: UInt32) {
        self.init(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
