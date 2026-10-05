# DSH iOS

DeepSeek Harness（DSH）的 **iOS 原生客户端**，使用 Swift + SwiftUI 编写，最低支持 **iOS 16.2**。

界面、交互与动效对齐桌面端 [anywhere-labs/dsh-desktop](https://github.com/anywhere-labs/dsh-desktop)（DSH Desktop），
上游为 [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)。

## 特性

### 对话
- 流式输出（SSE），逐字渲染，可随时中断
- 助手消息无气泡纯文本排版，与桌面端一致；用户消息右对齐气泡
- Markdown 渲染（标题、列表、行内样式）+ 代码块高亮样式与一键复制
- 推理模型（`deepseek-reasoner`）的「Think」折叠行，可展开查看思考过程
- 操作行：复制 / 点赞 / 点踩 / 重新生成
- 多轮上下文、消息编辑重发、失败重试

### 会话管理
- 新建、切换、删除、置顶、搜索（标题 + 全文）
- 标题自动取自首条用户消息
- 本地持久化（Documents/state.json），启动即恢复

### 插件系统（「万物皆插件」）
- **JavaScriptCore** 插件运行时：每个插件在独立 `JSContext` 中执行
- 脚本元数据：`@name` / `@summary` / `@version` / `@author` / `@enabled`
- 插件 API：`dsh.log` / `dsh.registerCommand` / `dsh.onMessage` / `dsh.setStorage` / `dsh.getStorage`
- 内置插件：时间戳、文本工具、文案统计、回答风格约束
- 用户插件：放入 `Documents/Plugins/*.js`（通过「文件」App 访问）即可热加载
- 命令面板：输入 `/` 呼出，命令结果回填输入框或提示
- 插件中心：启停开关、命令清单、实时运行日志、加载错误定位

### 界面与动效
- 品牌色 `#4D6BFE`，深色模式对齐桌面端配色（页面 `#1B1B1B`、侧栏 `#151515`）
- 底部输入舱：左侧 `+`、内嵌模型 chip、圆形发送/停止按钮、运行指标行
- 对话 / 轨迹 双标签（下划线指示器）；轨迹展示会话事件时间线
- 会话日志浮层
- iPhone 抽屉式侧边栏（跟手拖拽 + 遮罩渐变），iPad 分栏布局
- 统一弹簧动效曲线、按压反馈、触感反馈

### 设置
- API Key（Keychain 加密存储）、Base URL（兼容任意 OpenAI 格式接口）
- 模型选择、温度、系统提示词、流式开关、外观（跟随系统/浅色/深色）
- 连接测试、用量统计、会话导出 Markdown

## 构建

需要 macOS + Xcode（真实或 CI 均可），本仓库使用 GitHub Actions 的 `macos-14` 运行器构建。

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project DSHiOS.xcodeproj -scheme DSHiOS \
  -configuration Release -sdk iphoneos \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
```

产物为**未签名 IPA**（`Payload/DSH.app`），需自行签名后安装：

- 自签：用 AltStore / Sideloadly / TrollStore 等工具注入证书
- 真机开发：在 Xcode 中配置自己的 Team 后 `xcodebuild archive` 或直接 Run

## 使用

1. 打开 App → 右上角 `···` → 设置
2. 填入 DeepSeek API Key（`sk-…`），可用「测试连接」验证
3. 返回对话页开始使用；输入 `/` 可调用插件命令

## 与桌面端的差异

桌面端基于 Electron + Node Host + cordis 插件运行时（npm 生态）。
iOS 端无法运行 Node 与桌面级进程，因此：

| 能力 | 桌面端 | DSH iOS |
| --- | --- | --- |
| 插件运行时 | Node + cordis（npm 插件） | JavaScriptCore（JS 脚本插件） |
| 终端 / Worktree / 托盘 / 自动更新 | 有 | 不适用移动端 |
| 模型接入 | 本地 Host 服务 | 直连 OpenAI 兼容 HTTP 接口 |
| 会话、Markdown、流式、Think、轨迹 | 有 | 已对齐 |

## 许可与致谢

本项目为社区实现，与 DeepSeek 官方无隶属或背书关系。

- UI/交互参考：[anywhere-labs/dsh-desktop](https://github.com/anywhere-labs/dsh-desktop)（MIT）
- 上游项目：[deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)
- 本项目以 MIT 协议开源，详见 [LICENSE](LICENSE) 与 [NOTICE](NOTICE)