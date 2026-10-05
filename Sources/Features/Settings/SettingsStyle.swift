import SwiftUI

/// 设置页通用组件：与系统「设置」一致的彩色圆角图标行。
struct SettingsIcon: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 29

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
    }
}

/// 带彩色图标的行标题
struct SettingsRowLabel: View {
    let symbol: String
    let color: Color
    let title: String

    var body: some View {
        HStack(spacing: DSHTheme.Spacing.medium) {
            SettingsIcon(symbol: symbol, color: color)
            Text(title)
        }
        // 整行都可点：避免点到留白区域时无响应
        .contentShape(Rectangle())
    }
}

/// 右侧显示当前值的行（用于二级页入口）
struct SettingsValueRow: View {
    let symbol: String
    let color: Color
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: DSHTheme.Spacing.medium) {
            SettingsIcon(symbol: symbol, color: color)
            Text(title)
            Spacer(minLength: DSHTheme.Spacing.small)
            Text(value)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        // 整行都可点：避免点到留白区域时无响应
        .contentShape(Rectangle())
    }
}