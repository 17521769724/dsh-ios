import SwiftUI
import UIKit

/// 视觉规范：以 iOS 系统语义色为主，DeepSeek 品牌蓝作为唯一强调色，
/// 避免多种色相互相干扰，整体接近系统「设置」与原生 App 的观感。
enum DSHTheme {

    // MARK: - 品牌色（DeepSeek #4D6BFE）

    static let brand = Color(red: 0.302, green: 0.420, blue: 0.996)
    static let brandDeep = Color(red: 0.212, green: 0.310, blue: 0.847)
    static let brandSoft = Color(red: 0.302, green: 0.420, blue: 0.996).opacity(0.12)

    // MARK: - 语义色（全部走系统语义色，自动适配深浅色）

    static let page = Color(uiColor: .systemBackground)
    static let grouped = Color(uiColor: .secondarySystemBackground)
    /// 用户气泡：系统灰，右侧对齐
    static let userBubble = Color(uiColor: .tertiarySystemFill)
    static let userText = Color(uiColor: .label)
    /// 助手消息不使用气泡，直接铺在页面背景上
    static let assistantText = Color(uiColor: .label)
    static let inputBackground = Color(uiColor: .secondarySystemBackground)
    static let reasoningBackground = Color(uiColor: .secondarySystemBackground)
    static let separator = Color(uiColor: .separator)

    static let danger = Color(uiColor: .systemRed)
    static let warning = Color(uiColor: .systemOrange)
    static let success = Color(uiColor: .systemGreen)

    // MARK: - 尺寸

    enum Radius {
        /// 输入框胶囊
        static let composer: CGFloat = 22
        static let bubble: CGFloat = 18
        static let card: CGFloat = 12
        static let chip: CGFloat = 8
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
}

/// 交互动效：统一使用系统常用曲线，克制、不抢注意力。
enum DSHAnim {
    /// 常规状态切换
    static let standard = Animation.easeInOut(duration: 0.22)
    /// 列表插入与删除
    static let list = Animation.easeInOut(duration: 0.26)
    /// 抽屉与浮层
    static let drawer = Animation.spring(response: 0.34, dampingFraction: 0.92)
    /// 流式文本刷新
    static let stream = Animation.linear(duration: 0.1)
}

extension View {
    /// 卡片风格：系统分组背景 + 细描边
    func dshCard(background: Color = DSHTheme.grouped) -> some View {
        self
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: DSHTheme.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DSHTheme.Radius.card, style: .continuous)
                    .stroke(DSHTheme.separator.opacity(0.5), lineWidth: 0.5)
            )
    }

    /// 统一应用主题偏好。需要在每个浮层（sheet）的根视图上单独调用，
    /// 否则在设置页内切换深浅色时当前浮层不会立即刷新。
    func dshAppearance(_ preference: AppThemePreference) -> some View {
        self.preferredColorScheme(preference.colorScheme)
    }
}

extension AppThemePreference {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}