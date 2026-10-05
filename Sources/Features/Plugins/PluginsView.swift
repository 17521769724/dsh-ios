import SwiftUI

/// 插件中心：系统列表风格，插件启停、命令清单与运行日志拆分到子页面。
struct PluginsView: View {
    @EnvironmentObject private var plugins: PluginManager

    var body: some View {
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
                Text("已安装（\(plugins.manifests.count)）")
            } footer: {
                Text("内置插件随 App 分发；用户插件放在 Documents/Plugins 目录。关闭插件会立即卸载其命令与钩子。")
            }

            Section {
                NavigationLink {
                    PluginCommandsView()
                        .environmentObject(plugins)
                } label: {
                    SettingsValueRow(
                        symbol: "command",
                        color: .blue,
                        title: "命令",
                        value: "\(plugins.commands.count) 个"
                    )
                }
                NavigationLink {
                    PluginLogsView()
                        .environmentObject(plugins)
                } label: {
                    SettingsValueRow(
                        symbol: "doc.text.magnifyingglass",
                        color: .orange,
                        title: "运行日志",
                        value: "\(plugins.logs.count) 条"
                    )
                }
            }

            if !plugins.errors.isEmpty {
                Section("加载失败") {
                    ForEach(Array(plugins.errors.keys.sorted()), id: \.self) { key in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(key)
                                .font(.system(size: 14, weight: .semibold))
                            Text(plugins.errors[key] ?? "")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(DSHTheme.danger)
                        }
                    }
                }
            }

            Section {
                NavigationLink {
                    PluginDirectoryInfoView()
                        .environmentObject(plugins)
                } label: {
                    SettingsRowLabel(symbol: "folder", color: .gray, title: "插件目录说明")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("插件中心")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    plugins.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityIdentifier("plugins.refresh")
            }
        }
        .tint(DSHTheme.brand)
    }

    private func manifestRow(_ manifest: PluginManifest) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(manifest.name)
                            .font(.system(size: 16))
                        if manifest.isBuiltIn {
                            Text("内置")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(DSHTheme.brand)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(DSHTheme.brandSoft)
                                .clipShape(Capsule())
                        }
                    }
                    Text("v\(manifest.version) · \(manifest.author)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: DSHTheme.Spacing.small)
                Toggle("", isOn: Binding(
                    get: { manifest.isEnabled },
                    set: { plugins.setEnabled($0, for: manifest.id) }
                ))
                .labelsHidden()
                .accessibilityIdentifier("plugin.toggle.\(manifest.name)")
            }

            if !manifest.summary.isEmpty {
                Text(manifest.summary)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            if !manifest.isBuiltIn {
                Button("删除插件", role: .destructive) {
                    plugins.removeUserPlugin(id: manifest.id)
                }
                .font(.system(size: 13))
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 命令列表

struct PluginCommandsView: View {
    @EnvironmentObject private var plugins: PluginManager

    var body: some View {
        List {
            Section {
                ForEach(plugins.commands) { command in
                    HStack(spacing: DSHTheme.Spacing.medium) {
                        Text("/" + command.name)
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundStyle(DSHTheme.brand)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(command.summary.isEmpty ? "无说明" : command.summary)
                                .font(.system(size: 14))
                            Text(command.pluginID)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if plugins.commands.isEmpty {
                    Text("当前没有可用命令")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("在输入框输入 / 可呼出命令面板（需在「主页功能」开启插件命令）。")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("命令")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 日志

struct PluginLogsView: View {
    @EnvironmentObject private var plugins: PluginManager

    var body: some View {
        List {
            Section {
                ForEach(plugins.logs.reversed()) { entry in
                    HStack(alignment: .top, spacing: DSHTheme.Spacing.small) {
                        Circle()
                            .fill(color(for: entry.level))
                            .frame(width: 7, height: 7)
                            .padding(.top, 6)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.message)
                                .font(.system(size: 13, design: .monospaced))
                            Text("\(entry.pluginID) · \(entry.timestamp.formatted(date: .omitted, time: .standard))")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 1)
                }
                if plugins.logs.isEmpty {
                    Text("暂无日志")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("运行日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("清空") { plugins.clearLogs() }
                    .disabled(plugins.logs.isEmpty)
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