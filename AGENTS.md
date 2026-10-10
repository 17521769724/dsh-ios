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
  App/          ChatEngine（对话引擎：流式/工具/技能调度、云端推理遥控）、DSHiOSApp、RootView（抽屉布局 + 新功能弹窗）
  Core/         数据层：Models、ConversationStore、SettingsStore、Skill（技能库）、
                AgentTools（模型可调用工具定义）、WorkspaceStore（工作区文件 / 文件管理器与 IDE）、
                ScreenVision（截图 + 本地 OCR）、MCP + MCPStore（MCP 协议客户端与服务器管理）、
                CloudStore（云端推理配置 / 钥匙串令牌 / 一键部署脚本，见 2.5.0）、
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

- 版本：**2.6.2**（构建号由 CI 运行序号决定；2.2.0 = 106、2.3.0 = 107、2.4.0 = 109、2.5.0 = 112、2.6.0 = 114、2.6.1 = 116）。
- 2.6.2 交付（列表卡片简化 + 操作行统一成卡）：
  - **卡片只显示名字**：SSH / MCP 服务器列表行改为「名称 + 右箭头」单行（名称过长省略），
    去掉副标题与角标（详情页仍能看到地址、工具数等）；
  - **彻底去掉红色残影**（`SwipeToDeleteRow` 第三次调整，用户截图反馈「右侧莫名的删除按钮残影」）：
    红底改挂 ZStack 的 `background(alignment: .trailing)`（尺寸严格等于卡片、位于卡片下方），
    **静止时不渲染**（`offset < 0 || opened` 才画），因此不可能留下任何残影；
    同时恢复「展开后最上层透明点击层」——2.6.1 把点击层放到卡片下面，导致点红色区域被卡片接住
    只触发收起（CI 的 test18/test24 删除用例因此失败），本次修复；也不再使用 `content.hidden()`
    尺寸基准（它会让行的无障碍 frame 变成空值，test20 点按失败）；
  - **带图标的操作行独立成卡**（间距与「删除服务器」一致）：MCP 详情「连接并刷新」、云端页
    「一键创建 / 检测连接 / 查看部署日志」、设置首页「连接测试」、Git 账号「退出登录」、
    权限页「一键申请权限 / 打开系统设置」。
- 2.6.1 交付（UI 显示修复 + 云端页字段与日志）：
  - **修复「红色删除区露出卡片之外」**（`SwipeToDeleteRow` 重构，用户截图反馈 SSH / MCP 列表里
    卡片右侧与上下露出红色）：删除层不再与卡片并排放在 ZStack 里，而是挂在一份**不可见的内容副本**
    上作为 `overlay`——尺寸由卡片本身决定（确定的尺寸基准），在任何父容器（List 行 / ScrollView）
    都不会比卡片高出或宽出；同时在最外层加 `.frame(maxWidth: .infinity)` 保证卡片撑满行宽；
  - **云端推理页**：SSH 服务器选择改为 `Menu`（只显示服务器名称、`.lineLimit(1)` 省略、不换行），
    不再显示 `名称（root@host:22）` 那种会换行的长文本；
  - **端口不再千分位**：三处端口输入框改用 `format: .number.grouping(.never)`（8931 而不是 8,931）；
  - **新增「查看部署日志」按钮**（`cloud.log`）：经 SSH 取回 `~/.dsh/agent.log` 末尾 120 行，
    以可滚动弹窗展示（部署失败提示同时引导用户点它排查）；
  - UI 用例 test10 改为「连接测试结果以弹窗给出」（2.6.0 把行内结果改成弹窗后它一直红着）；
    单测新增端口格式化断言。
- 2.6.0 交付（设置页体验 + SSH 多服务器）：
  - **SSH 云服务器支持多台**（`SSHStore` 重写）：每台一张卡片（左滑删除、点按进详情），
    密码按服务器 id 存钥匙串（`ssh.password.<uuid>`）；旧版单台配置在首次读取时自动迁移
    （旧键 `dsh.ssh.config.v1` + `ssh.password` → 列表第一台），迁移后旧键删除；
    智能体 `ssh_exec` 新增可选 `server` 参数（名称或主机，支持模糊匹配；不填用第一台），
    可用服务器名单写进工具描述；
  - **云端推理服务器多选**（`CloudConfiguration.sshServerID`）：云端页用 Picker 选择部署/推理用哪台，
    `CloudStore.selectedServer(in:)` / `baseURL(for:)` 统一解析；
  - **全部结果改弹窗**：模型服务「连接测试」（ConnectionTestRow）、SSH「测试连接」、
    SSH「命令控制台」输出（sheet 可滚动，替代原来的行内文本块）、MCP「连接并刷新」；
  - **MCP 服务器列表修复**：去掉自定义 `listRowInsets` + `listRowSeparator(.hidden)`（卡片宽度与其它分组一致、
    不再出现中间分割线）；详情页「连接并刷新」下方的说明只显示**最近连接时间**（错误不再行内展示）；
  - **一键部署日志行去除**：部署结果只以弹窗提示（成功含已部署的服务器名与 Agent 版本），
    不再显示「（命令执行完成，没有输出）」这类 SSH 原始输出（`CloudStore.lastDeployLog` 已删除）；
  - 单测：`SSHStoreMultiServerTests`（增删/解析/密码清理、旧配置迁移）；
    UI 用例 test20 改为「添加服务器 → 详情页」新流程；`-uitest-reset` 同时清空 SSH 服务器列表。
- 2.5.0 交付（**云端推理**：iOS 当遥控器、云服务器执行推理，用户要求新功能要有弹窗告知）：
  - **服务端 Agent**（`Resources/dsh-agent.py`，纯标准库单文件）：HTTP 服务，
    接口 = 健康检查 / 沙盒（自动创建、列表、暂停、恢复、销毁）/ 沙盒文件（列出、上传、下载、删除）/
    推理（发起 chat、按游标 `after=N` 长轮询取事件、停止）；推理在服务器后台线程执行，
    客户端断开（App 后台）不中断，客户端回来按游标补齐全部内容；除 /health 外都要 Bearer 鉴权；
  - **一键部署**（`CloudDeploy`）：在「设置 → 云端推理」用已有 SSH 配置把 Agent 源码写入服务器、
    缺 python3 时自动安装、`nohup` 后台启动并自检；部署后用 HTTP 从手机侧再验证一次端口可达性；
  - **iOS 遥控**（`CloudAgentClient` + `ChatEngine.startCloudStreaming`）：会话消息（纯文本角色）
    发给服务器推理，事件（content/reasoning/usage）流式写入同一套 `StreamingText` 缓冲；
    App 退到后台只是停止取事件，回前台自动续取；停止按钮会显式通知服务器 `stop`；
    模型 Key 保存在本机钥匙串、随请求下发，服务器不落盘；
  - **设置页**（`CloudSettingsView`）：顶部总开关（`FeatureFlags.cloudInference`）、服务器/端口/令牌、
    一键部署、检测连接、沙盒列表（创建 / 暂停 / 恢复 / 销毁）、沙盒文件（上传 fileImporter、
    下载后系统分享保存、左滑删除）；
  - **新功能弹窗**（`ReleaseNotes`，RootView）：每个版本首次打开主界面弹一次「新功能」说明，
    可在弹窗里直接跳设置；UI 测试用 `-uitest-release-notes` 强制弹出、默认跳过；
  - 云端 v1 限制：只发纯文本（图片与智能体工具仍在本机直连模式可用）、Agent 重启会丢进行中的任务；
  - 单测：`CloudAgentTests`（令牌、部署脚本与结果判定、事件/沙盒解码、老数据兼容、内置脚本可读）。
- 2.4.0 交付（继续压 token + 新功能）：收尾轮零工具、单轮工具输出预算（3 万字符）、
  同名网页去重、工具描述精简约三成、新增「工作区检索」（workspace search 动作）。
  明细：
  - **收尾轮不再下发工具**（`ChatEngine.startStreaming`）：工具轮的第 6 轮（最后一轮）改为「零工具 +
    收尾提示」，直接要结论——既保证一定有最终回答，又省掉一轮「执行工具 + 整段重发」；
    循环结束后的「收尾救场」继续兜底空响应；
  - **单轮工具输出预算**（`ToolOutputBudget`，`Sources/Core/ToolOutputAging.swift`）：
    单轮累计 3 万字符，超出后后续结果收紧截断到 2 千字符并附说明，压住「工具轮逐轮重发」的最坏情况；
  - **同名网页去重**：同一轮内重复读取同一 URL 只回一句「同上」，不再重复放入整段正文；
  - **工具描述精简**（`AgentTools.swift`）：10 个工具的描述与参数说明缩减约三成，每请求固定省 token，
    功能语义不变；
  - **新功能：工作区检索**（workspace 工具新增 `search` 动作，`WorkspaceStore.searchMatches`）：
    按关键词在文本文件里找匹配行，返回「文件:行号: 内容」（最多 30 条、命中行截断 120 字）——
    让模型按需只取相关片段而不是整文件读取（just-in-time 取数，同时也是省 token 的做法）；
  - 单测：`ToolOutputBudget` 预算行为、`WorkspaceStore` search 动作与 `searchMatches` 行匹配。
- 2.3.0 交付（省 token + 空回复修复，用户反馈「两轮对话最后模型都输出本轮没有返回内容」
  与「token 用量比其他软件大太多」）：
  - **工具结果老化**（`Sources/Core/ToolOutputAging.swift`，业界称 tool result clearing / observation
    masking）：较早轮次的工具结果发送前只留开头 400 字摘要、并丢弃其截图（界面、过程弹窗与会话日志
    仍显示完整内容，模型需要完整内容时可重新执行工具）；当前轮（最后一条用户消息之后）的工具结果
    完整保留。此前每条历史工具结果都会在每次请求里整段重发，是 token 用量膨胀的最大来源；
  - **截断收紧**：网页正文 12k → 8k 字符（保留开头 5.5k + 结尾 2k，中间省略）；
    所有工具输出发送前再加一道 16k 字符兜底（`ChatEngine.limitedToolOutput`，覆盖 MCP 大返回、
    工作区大文件）；
  - **自动压缩更省**：触发阈值 75% → 70%、保留比例 35% → 30%；压缩触发判断与「上下文 %」显示
    改为按老化后的实际发送量估算（不会虚高、不会过早压缩）；摘要请求本身也按老化后的内容发送；
  - **空回复「收尾救场」**：模型一个字都没写出（工具轮用尽 / 空响应）时，追加一条临时用户消息
    （不写入会话记录）并**不下发工具**再请求一次，逼出文字结论；`ChatEngine.request` 抽出
    流式/非流式统一发请求逻辑；
  - 单测：`ToolOutputAgingTests`（老化只作用较早轮次、老截图丢弃、兜底截断）。
- 2.2.0 交付：
  - **三点动画兜底**（用户第二次反馈「模型无输出时没有动画，无法判断是否结束」）：
    `ChatView.showsStreamingIndicator` 改为两条条件——跑工具期间、或「正在生成但最后一条助手消息
    还没拿到流式缓冲 / 内容为空」时，在对话最下方补一行 `TypingIndicator`；
    正在输出的气泡自己会显示同一套动画，两处条件互斥，始终只有一行；
  - **不再留空气泡**：`ChatEngine.markEmptyFinalReplyIfNeeded` 在本轮结束（含达到单轮 6 轮工具上限）
    或用户手动停止后，若最后一条助手消息一个字都没有，就补一句说明
    （「（本轮没有返回内容，可以继续提问，或点重新生成。）」/「（已手动停止，本轮没有产生回复。）」）；
  - **侧栏会话状态点**（`SidebarView.RunStatusDot`）：当前会话标题右侧显示
    绿色跳动（正在生成）/ 橙色（已手动停止，`ChatEngine.stoppedRun`）/ 红色（本轮失败，看最后一条的 errorText）；
  - 设置里「MCP 工具与服务器」移到「内置浏览器」下方（顺序：SSH 云服务器 → 内置浏览器 → MCP 工具与服务器
    → 智能体 OCR 视觉 → 工作区文件 → 提醒事项与日历 → 剪贴板读写）。
- 2.1.0 交付：工具执行补动画、实时思考弹窗、图片缩小、回到底部、停止后图标、长文卡顿治理、会话日志可展开。
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
