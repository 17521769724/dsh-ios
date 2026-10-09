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

/// 带配置页的「入口行」：右侧只给一个进入配置的箭头。
/// 开关统一放在配置页顶部，设置首页不再重复（用户要求）。
struct SettingsLinkRow<Destination: View>: View {
    let symbol: String
    let color: Color
    let title: String
    /// 入口行的无障碍标识（沿用 settings.xxx）
    var linkIdentifier: String
    @ViewBuilder var destination: Destination

    var body: some View {
        NavigationLink {
            destination
        } label: {
            SettingsRowLabel(symbol: symbol, color: color, title: title)
        }
        .accessibilityIdentifier(linkIdentifier)
    }
}