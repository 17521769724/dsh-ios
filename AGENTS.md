# AGENTS.md — 项目交接说明（给 AI 助手 / 新协作者）

> 本文件用于让 AI 助手（或新加入的开发者）在**零上下文**的情况下快速接手本项目。
> 新开对话时，把本仓库地址发给助手，并让它先读 `AGENTS.md` 与 `docs/CONVERSATION_HISTORY.md` 即可。

## 项目是什么

DSH（DeepSeek Harness）的 **iOS 原生客户端**：Swift + SwiftUI 编写，最低支持 **iOS 16.2**。
未上架 App Store，通过 CI 产出的未签名 IPA + 自行签名（AltStore / Sideloadly / TrollStore 等）安装。
UI、交互与动效对齐桌面端 [anywhere-labs/dsh-desktop](https://github.com/anywhere-labs/dsh-desktop)。

## 关键事实（先看这几条）

| 事项 | 结论 |
| --- | --- |
| 工程生成 | XcodeGen（`project.yml` 是唯一工程配置来源，`.xcodeproj` 不入库） |
| 构建 | `xcodegen generate` + `xcodebuild`（无签名，见下文命令） |
| CI / 交付 | push 到 `main` → GitHub Actions（`.github/workflows/ios.yml`）自动构建并发布 Release，tag 为 `build-<run_number>` |
| 版本号 | `project.yml` → `MARKETING_VERSION`（如 `1.2.4`）；构建号 = CI 运行序号（`CURRENT_PROJECT_VERSION` 由 CI 覆盖） |
| 下载地址 | https://github.com/17521769724/dsh-ios/releases/latest |
| 发布资产 | `DSH-iOS-<版本>-build<构建号>.ipa`（每次文件名唯一，避免装到旧包） |
| 应用内验证版本 | 左侧菜单栏底部「设置」一行右侧显示 `V<版本> (<构建号>)` |
| 测试 | `Tests/Unit`（单元）+ `Tests/UI`（XCUITest 端到端），CI 每次 push 都会跑 |
| 智能体工具 | SSH / 内置浏览器 / 查看画面（截图 + 本地 OCR）/ 工作区文件 / MCP / GitHub / Gitee / 技能，开关都在「设置 → 智能体工具」与技能库页 |
| MCP 协议 | 客户端实现 `Sources/Core/MCP.swift`：JSON-RPC 2.0 over Streamable HTTP（MCP 2025-03-26），握手 / 会话 / tools / resources / prompts；服务器配置存 `mcp-servers.json`，模型侧工具名前缀 `mcp_<别名>_` |
| 工作区目录 | `Documents/Workspace`（内置「文件」页与 IDE 的根目录，同时可在系统「文件」App → 我的 iPhone → DSH 里访问） |

## 目录结构

```
Sources/
  App/          ChatEngine（对话引擎：流式/工具/技能调度）、DSHiOSApp、RootView（抽屉布局）
  Core/         数据层：Models、ConversationStore、SettingsStore、Skill（技能库）、
                AgentTools（模型可调用工具定义）、WorkspaceStore（工作区文件 / 文件管理器与 IDE）、
                ScreenVision（截图 + 本地 OCR）、MCP + MCPStore（MCP 协议客户端与服务器管理）、
                AppCache（缓存统计/清理）、SSHStore、GitAccountStore、Keychain
  Design/       Theme（配色/间距/圆角/动效）、SecureInputField、TapToDismissKeyboard
  Features/
    Chat/       对话页：ChatView、MessageBubble、StreamingText（增量缓冲）、
                ChatProcess（过程折叠）、ProcessSheet（过程弹窗）、MarkdownRenderer、ComposerBar
    Sidebar/    左侧抽屉：会话列表、置顶/重命名/删除、底部入口（插件/技能/文件/设置+版本号）
    Skills/     技能库界面：SkillEditorPage（页内推入编辑）
    Files/      内置文件管理器与 IDE：FilesView（浏览/新建/重命名/删除）、CodeEditorPage（代码编辑与自动保存）
    Plugins/    插件中心界面
    Settings/   设置页及二级页（API/模型/SSH/Git 账号/浏览器/清理缓存）
    Browser/    内置浏览器（OAuth 回调拦截、网页工具）
    Onboarding/ 首次启动引导
  Net/          DeepSeekClient（OpenAI 兼容接口）、ChatStreamParser（SSE + usage 容错）、
                SSHService、GitService、GitHub/Gitee 授权
  Plugins/      JavaScriptCore 插件运行时（PluginManager / PluginManifest / PluginRuntime）
Resources/      资源、Info.plist、内置 JS 插件
Tests/          Unit / UI 测试
project.yml     XcodeGen 工程配置（版本号在这里改）
.github/workflows/ios.yml  CI：构建未签名 IPA + 跑测试 + 发布 Release
```

## 构建与测试（本机或 CI）

```bash
brew install xcodegen
xcodegen generate
# 构建（未签名 IPA 用）
xcodebuild -project DSHiOS.xcodeproj -scheme DSHiOS -configuration Release -sdk iphoneos \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
# 测试（模拟器）
xcodebuild test -project DSHiOS.xcodeproj -scheme DSHiOS -destination "platform=iOS Simulator,name=iPhone 16"
```

## 发布流程（通常无需手动操作）

1. 改动提交并 push 到 `main`；
2. CI 自动：选择最新 Xcode → 生成工程 → 构建 → 校验无高于 iOS 16.2 的 API → 打包 IPA → 发布 Release（标题含版本与构建号）；
3. 用户在 Release 下载 `DSH-iOS-<版本>-build<构建号>.ipa` 自签安装；
4. 安装后可在应用内左侧菜单栏底部核对版本号（`V1.2.4 (76)` 这种格式）。

发新版时记得同步提升 `project.yml` 的 `MARKETING_VERSION`。

## 代码约定

- 注释、文案、日志一律使用**中文**；面向用户的文案力求简短。
- UI 颜色/间距/圆角/动效统一走 `DSHTheme` / `DSHAnim`，不要写魔法值。
- 可测试的控件加 `accessibilityIdentifier`（命名如 `sidebar.settings`、`skills.row`），UI 测试依赖它们。
- 流式输出必须走 `StreamingText` 缓冲（定频刷新），避免整树重算导致卡顿；
  长文本按块渲染（已定型块复用排版），生成期间只有正在输出的那条消息视图参与刷新。
- 新增模型可调用工具 → 在 `Sources/Core/AgentTools.swift` 中登记（含 JSON Schema 与描述）。
- 新增设置项 → `Sources/Core/SettingsStore.swift` + `Sources/Features/Settings/SettingsView.swift`（图标用 `SettingsRowLabel`）。
- 技能（Skill）与工具不重合：技能规定「怎么做」（步骤/规范/清单），工具负责「执行」；模型通过 `skill` 工具按需取回技能全文。

## 当前状态

- 版本：**1.4.0（build 84）**，已发布的未签名 IPA 见 Releases。
- 1.4.0 交付：
  - 技能页左滑删除改为自绘 `SwipeToDeleteRow`：删除背景与卡片同高同圆角、固定红色（系统 swipeActions 会露出直角且比卡片高）；
  - 侧栏删除最后一条记录时，空状态延后 0.4s 再淡入，不再与被删记录 / 长按菜单收起动画重叠；
  - 对话页模型输出对齐参考实现：每条回复带「图标 + DeepSeek」标识行，思考过程 / 过程摘要排在正文之前；
  - 输出完成后滚动卡顿治理：消息入场动画只在刚生成时播放（滚动回收重建的行不重播），正文分块不再逐块开启文本选择；
  - 新增 **MCP 协议支持**（`Sources/Core/MCP.swift`）：JSON-RPC 2.0 over Streamable HTTP，
    覆盖 initialize 握手 / 协议版本协商 / `Mcp-Session-Id` 会话 / `notifications/initialized` /
    tools(list·call) / resources(list·read) / prompts(list·get)，兼容 JSON 与 SSE 两种响应；
    设置页可添加多台服务器（名称 / 地址 / 请求头）、连接并刷新、查看工具与提示模板，
    已连接服务器的工具以 `mcp_<别名>_<工具名>` 下发给模型，调用时由本机代发。
- 1.3.0 交付：冷启动顶栏稳定、消息长按圆角、技能开关归位、智能体「查看画面」（截图 + OCR）、内置文件管理器与 IDE。
- 历史需求与逐版交付记录见 [`docs/CONVERSATION_HISTORY.md`](docs/CONVERSATION_HISTORY.md)。
