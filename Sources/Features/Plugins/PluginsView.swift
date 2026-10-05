import SwiftUI

/// 插件中心：查看插件清单、启停、命令与运行日志。
struct PluginsView: View {
    @EnvironmentObject private var plugins: PluginManager
    @Environment(\.dismiss) private var dismiss

    private enum Tab: String, CaseIterable, Identifiable {
        case installed = "已安装"
        case commands = "命令"
        case logs = "日志"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .installed

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("视图", selection: $tab) {
                    ForEach(Tab.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, DSHTheme.Spacing.large)
                .padding(.vertical, DSHTheme.Spacing.small)

                Divider().opacity(0.4)

                switch tab {
                case .installed: installedList
                case .commands: commandList
                case .logs: logList
                }
            }
            .navigationTitle("插件中心")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        plugins.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
    }

    // MARK: - 已安装

    private var installedList: some View {
        List {
            Section {
                ForEach(plugins.manifests) { manifest in
                    manifestRow(manifest)
                }
                if plugins.manifests.isEmpty {
                    Text("未发现插件")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("\(plugins.manifests.count) 个插件")
            } footer: {
                Text("内置插件随 App 分发；用户插件放在 Documents/Plugins 目录下。关闭插件会立即卸载其注册的命令与钩子，无需重启。")
            }

            if !plugins.errors.isEmpty {
                Section("加载失败") {
                    ForEach(Array(plugins.errors.keys.sorted()), id: \.self) { key in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(key)
                                .font(.system(size: 13, weight: .semibold))
                            Text(plugins.errors[key] ?? "")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(DSHTheme.danger)
                        }
                    }
                }
            }
        }
    }

    private func manifestRow(_ manifest: PluginManifest) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(manifest.name)
                            .font(.system(size: 15, weight: .semibold))
                        if manifest.isBuiltIn {
                            Text("内置")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(DSHTheme.brand)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(DSHTheme.brandSoft)
                                .clipShape(Capsule())
                        }
                    }
                    Text("v\(manifest.version) · \(manifest.author)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { manifest.isEnabled },
                    set: { plugins.setEnabled($0, for: manifest.id) }
                ))
                .labelsHidden()
                .tint(DSHTheme.brand)
            }

            if !manifest.summary.isEmpty {
                Text(manifest.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            if !manifest.isBuiltIn {
                Button(role: .destructive) {
                    plugins.removeUserPlugin(id: manifest.id)
                } label: {
                    Text("删除插件")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(DSHTheme.danger)
            }
        }
        .padding(.vertical, 2)
        .animation(DSHAnim.standard, value: manifest.isEnabled)
    }

    // MARK: - 命令

    private var commandList: some View {
        List {
            Section {
                ForEach(plugins.commands) { command in
                    HStack(spacing: DSHTheme.Spacing.medium) {
                        Text("/" + command.name)
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundStyle(DSHTheme.brand)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(command.summary.isEmpty ? "无说明" : command.summary)
                                .font(.system(size: 13))
                            Text(command.pluginID)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if plugins.commands.isEmpty {
                    Text("当前没有可用命令")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("\(plugins.commands.count) 个命令")
            } footer: {
                Text("在输入框输入 / 可呼出命令面板，命令返回值会回填到输入框或直接提示。")
            }
        }
    }

    // MARK: - 日志

    private var logList: some View {
        List {
            Section {
                ForEach(plugins.logs.reversed()) { entry in
                    HStack(alignment: .top, spacing: DSHTheme.Spacing.small) {
                        Text(entry.level.uppercased())
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(color(for: entry.level))
                            .frame(width: 44, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.message)
                                .font(.system(size: 12, design: .monospaced))
                            Text("\(entry.pluginID) · \(entry.timestamp.formatted(date: .omitted, time: .standard))")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 1)
                }
                if plugins.logs.isEmpty {
                    Text("暂无日志")
                        .foregroundStyle(.secondary)
                }
            } header: {
                HStack {
                    Text("运行日志")
                    Spacer()
                    Button("清空") { plugins.clearLogs() }
                        .font(.system(size: 12))
                }
            }
        }
    }

    private func color(for level: String) -> Color {
        switch level.lowercased() {
        case "error": return DSHTheme.danger
        case "warn": return DSHTheme.warning
        default: return DSHTheme.success
        }
    }
}