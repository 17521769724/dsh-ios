import SwiftUI
import WebKit

/// 内置浏览器设置：首页、桌面版、智能体读取权限与本地数据清理。
struct BrowserSettingsView: View {
    @EnvironmentObject private var settingsStore: SettingsStore

    @State private var showClearConfirm = false
    @State private var cleared = false

    var body: some View {
        List {
            Section {
                // 总开关在配置页顶部（设置首页那一行只有箭头）
                Toggle(isOn: $settingsStore.settings.features.browserTool) {
                    SettingsRowLabel(symbol: "safari.fill", color: .blue, title: "内置浏览器工具")
                }
                .accessibilityIdentifier("browser.agentTools")

                Toggle(isOn: $settingsStore.settings.browser.allowAgentRead) {
                    SettingsRowLabel(
                        symbol: "doc.text.magnifyingglass",
                        color: .orange,
                        title: "允许智能体读取网页正文"
                    )
                }
                .accessibilityIdentifier("browser.allowAgentRead")
            } header: {
                Text("智能体")
            } footer: {
                Text("「内置浏览器工具」控制智能体能否打开网页（同时决定顶栏菜单里的内置浏览器入口）；开启「读取网页正文」后模型还可调用 browser_read 读取正文纯文本，关闭只影响读取。")
            }

            Section {
                Toggle(isOn: $settingsStore.settings.browser.desktopSite) {
                    SettingsRowLabel(symbol: "desktopcomputer", color: .indigo, title: "桌面版网站")
                }
                .accessibilityIdentifier("browser.desktopSite")
            } header: {
                Text("显示")
            } footer: {
                Text("开启后以桌面版 User-Agent 加载网页，适合只提供桌面布局的站点。")
            }

            Section {
                TextField("https://www.deepseek.com", text: $settingsStore.settings.browser.homeURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(.system(size: 14, design: .monospaced))
                    .accessibilityIdentifier("browser.homeURL")
            } header: {
                Text("首页")
            } footer: {
                Text("从顶栏菜单或输入框「+」打开内置浏览器时，首先加载这个地址。")
            }

            Section {
                Button {
                    showClearConfirm = true
                } label: {
                    Label("清除浏览数据", systemImage: "trash")
                }
                .accessibilityIdentifier("browser.clearData")
            } footer: {
                Text("清除内置浏览器的缓存、Cookie 与本地存储，已登录的网站需要重新登录。")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("浏览器设置")
        .navigationBarTitleDisplayMode(.inline)
        .tint(DSHTheme.brand)
        .confirmationDialog("确定清除浏览数据？", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("清除", role: .destructive) { clearWebsiteData() }
            Button("取消", role: .cancel) {}
        }
        .alert("已清除浏览数据", isPresented: $cleared) {
            Button("好的", role: .cancel) {}
        }
    }

    private func clearWebsiteData() {
        WKWebsiteDataStore.default().removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        ) {
            DispatchQueue.main.async { cleared = true }
        }
    }
}