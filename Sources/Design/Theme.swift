import SwiftUI
import UIKit

/// DSH 视觉规范：颜色、圆角、间距、动效曲线。
/// 参考 DSH Desktop 的品牌色 #4D6BFE 与深色聊天界面。
enum DSHTheme {

    // MARK: - 品牌色

    static let brand = Color(red: 0.302, green: 0.420, blue: 0.996)          // #4D6BFE
    static let brandSoft = Color(red: 0.302, green: 0.420, blue: 0.996).opacity(0.14)
    static let brandDeep = Color(red: 0.212, green: 0.310, blue: 0.847)      // #364FD8

    // MARK: - 语义色（对齐 DSH Desktop 深色界面）

    /// 用户气泡：深色模式下为深灰 #2E2E2E，浅色模式下为浅灰
    static let userBubble = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0.18, alpha: 1)
            : UIColor(white: 0.92, alpha: 1)
    })

    static let userText = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? .white : .black
    })

    /// 页面背景：深色 #1B1B1B
    static let pageBackground = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0.106, alpha: 1)
            : .systemBackground
    })

    /// 侧边栏/卡片背景：深色 #151515
    static let elevatedBackground = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0.082, alpha: 1)
            : .secondarySystemBackground
    })

    /// 思考内容底色
    static let reasoningBackground = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0.145, alpha: 1)
            : UIColor(white: 0.96, alpha: 1)
    })

    /// 输入舱底色
    static let inputBackground = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0.135, alpha: 1)
            : .secondarySystemBackground
    })

    static let separator = Color(uiColor: .separator).opacity(0.5)

    static let success = Color(red: 0.204, green: 0.780, blue: 0.349)
    static let warning = Color(red: 1.000, green: 0.624, blue: 0.039)
    static let danger = Color(red: 0.937, green: 0.267, blue: 0.267)

    // MARK: - 尺寸

    enum Radius {
        static let bubble: CGFloat = 16
        static let card: CGFloat = 14
        static let chip: CGFloat = 10
        static let composer: CGFloat = 24
    }

    enum Spacing {
        static let tight: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let section: CGFloat = 24
    }
}

/// 统一动效曲线，贴近桌面端的顺滑手感。
enum DSHAnim {
    /// 常规状态切换
    static let standard = Animation.spring(response: 0.34, dampingFraction: 0.86)
    /// 列表增删
    static let list = Animation.spring(response: 0.40, dampingFraction: 0.82)
    /// 弹出/抽屉
    static let sheet = Animation.spring(response: 0.32, dampingFraction: 0.88)
    /// 流式文字刷新（短、轻，避免抖动）
    static let stream = Animation.linear(duration: 0.12)
    /// 强调反馈
    static let emphasis = Animation.spring(response: 0.28, dampingFraction: 0.70)
}

extension View {
    /// 卡片风格背景，带轻描边
    func dshCard(background: Color = DSHTheme.elevatedBackground) -> some View {
        self
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: DSHTheme.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DSHTheme.Radius.card, style: .continuous)
                    .stroke(DSHTheme.separator, lineWidth: 0.5)
            )
    }
}
