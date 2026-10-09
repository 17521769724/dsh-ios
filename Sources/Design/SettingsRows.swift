import SwiftUI

/// 设置里的「开关行」：右侧一个开关，没有配置页的功能用它。
struct SettingsToggleRow: View {
    let symbol: String
    let color: Color
    let title: String
    @Binding var isOn: Bool
    /// 无障碍标识（沿用 feature.xxx，界面测试依赖）
    var identifier: String

    var body: some View {
        Toggle(isOn: $isOn) {
            SettingsRowLabel(symbol: symbol, color: color, title: title)
        }
        .accessibilityIdentifier(identifier)
    }
}

/// 带配置页的「开关行」：右侧是开关，开关右边再跟一个进入配置的箭头。
/// 点开关只切换开关，点这一行的其它位置进入配置页。
struct SettingsToggleLinkRow<Destination: View>: View {
    let symbol: String
    let color: Color
    let title: String
    @Binding var isOn: Bool
    /// 开关的无障碍标识（沿用 feature.xxx）
    var identifier: String
    /// 入口行的无障碍标识（沿用 settings.xxx）
    var linkIdentifier: String
    @ViewBuilder var destination: Destination

    var body: some View {
        NavigationLink {
            destination
        } label: {
            HStack(spacing: DSHTheme.Spacing.small) {
                SettingsRowLabel(symbol: symbol, color: color, title: title)
                Spacer(minLength: 8)
                Toggle("", isOn: $isOn)
                    .labelsHidden()
                    .accessibilityIdentifier(identifier)
                    // 开关自己吃掉点击，不会顺带把这一行推进配置页
                    .contentShape(Rectangle())
            }
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier(linkIdentifier)
    }
}