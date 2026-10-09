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
| 智能体工具 | SSH / 内置浏览器 / 查看画面（截图 + 本地 OCR）/ 工作区文件 / 剪贴板 / 提醒事项与日历 / MCP / GitHub / Gitee / 技能，开关都在「设置 → 智能体工具」与技能库页 |
| MCP 协议 | 客户端实现 `Sources/Core/MCP.swift`：JSON-RPC 2.0 over Streamable HTTP（MCP 2025-03-26），握手 / 会话 / tools / resources / prompts；服务器配置存 `mcp-servers.json`，模型侧工具名前缀 `mcp_<别名>_` |
| 工作区目录 | `Documents/Workspace`（内置「文件」页与 IDE 的根目录，同时可在系统「文件」App → 我的 iPhone → DSH 里访问） |

## 目录结构

```
Sources/
  App/          ChatEngine（对话引擎：流式/工具/技能调度）、DSHiOSApp、RootView（抽屉布局）
  Core/         数据层：Models、ConversationStore、SettingsStore、Skill（技能库）、
                AgentTools（模型可调用工具定义）、WorkspaceStore（工作区文件 / 文件管理器与 IDE）、
                ScreenVision（截图 + 本地 OCR）、MCP + MCPStore（MCP 协议客户端与服务器管理）、
                RemindersService（提醒事项与日历，EventKit）、
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

- 版本：**2.1.0（build 102）**，已发布的未签名 IPA 见 Releases。
- 2.1.0 交付：
  - **加载动画**：模型在本地跑工具这一阶段没有任何流式输出，现在会在对话最下方显示三点动画
    （`ChatEngine.runningToolName`）；两处动画共用同一个 `TypingIndicator` 且条件互斥，
    修掉了同时出现两行的问题；
  - **生成中点「思考过程」必开弹窗**：过程弹窗从气泡里移到对话页（`ChatView.processTarget`）持有，
    生成中气泡高速重绘不会再把点击或弹窗吞掉；实时思考内容由 `LiveReasoningSection` 持续刷新；
  - **用户消息里的图片缩小**：由最大 220×280 改为 96×96 的圆角小方图（与输入框缩略图同级观感）；
  - **回到底部按钮**：向上翻阅历史时出现在对话区右下角（输入框上方），点一下回到最新消息；
  - **手动停止后也显示操作图标**：条件放宽为「本轮最终回复或最后一条助手消息 + 生成已停止」；
  - **长回复卡顿治理**：跟随滚动限制到约 4 次/秒（此前每次增量都滚动，总结这种长文本会明显掉帧）；
  - **会话日志**：模型回复/工具输出默认只显示一行摘要，右侧箭头可展开折叠查看全文；
    「插件执行」标题改为具体工具（如「调用内置浏览器打开网页」）；继续保持秒开（LazyVStack + events 只算一次）；
  - 设置页结构（第三次调整，以下为最终形态）：**设置首页**里，带配置页的功能（SSH 云服务器 / 内置浏览器 /
    MCP 工具与服务器 / GitHub / Gitee / 技能库 / 回答风格约束）只显示箭头，开关统一放到**配置页顶部**；
    没有配置页的功能（智能体 OCR 视觉 / 工作区文件 / 提醒事项与日历 / 剪贴板读写）仍直接显示开关。
- 2.0.0 交付：修复 400 工具配对错误、会话日志秒开、设置页统一为「开关 + 箭头」行（该形态已在 2.1.0 调整）。
- 1.9.0 交付：操作图标只在最终回复出现、思考与工具弹窗独立、三点加载、去掉重复开关（后一条在 2.0.0 反转）。
- 1.8.0 交付：权限与引导的提示统一改为弹窗、权限按钮精简为「一键申请权限」。
- 1.7.0 交付：设置里工具开关顺序调整、MCP 服务器卡片左滑删除（与技能库共用 SwipeToDeleteRow）、
  详情页删除图标改红、添加 GitHub 官方 MCP 前校验登录、首次启动权限申请引导与「设置 → 关于 → 权限状态」页。
- 1.6.0 交付：侧栏空状态延后到记录完全消失后、按模型上下文窗口自动压缩上下文。
- 1.5.0 交付：技能左滑加固（鲜红实底 + 惯性阈值 + 长按菜单）、剪贴板与提醒事项/日历工具、MCP 推荐服务器一键添加。
- 1.4.0 交付：技能页左滑自绘删除、侧栏删除过渡、对话页输出样式对齐、滚动卡顿治理、完整 MCP 协议支持。
- 1.3.0 交付：冷启动顶栏稳定、消息长按圆角、技能开关归位、智能体「查看画面」（截图 + OCR）、内置文件管理器与 IDE。
- 历史需求与逐版交付记录见 [`docs/CONVERSATION_HISTORY.md`](docs/CONVERSATION_HISTORY.md)。
