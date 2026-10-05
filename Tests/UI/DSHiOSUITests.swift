import XCTest

/// 端到端 UI 测试：验证界面渲染、插件命令、错误引导、抽屉与各面板。
/// 截图会写入运行器沙盒的 Documents 目录，并由 CI 收集为构建产物。
final class DSHiOSUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uitest-reset"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20), "应用未能进入前台")
    }

    // MARK: - 工具

    private func capture(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = directory.appendingPathComponent("\(name).png")
        try? screenshot.pngRepresentation.write(to: url)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    // MARK: - 用例

    func test01_欢迎页与输入舱渲染() {
        let composer = element("composer.input")
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "未找到输入框")
        XCTAssertTrue(app.staticTexts["有什么可以帮你？"].exists, "未显示欢迎文案")
        XCTAssertTrue(element("composer.send").exists, "未找到发送按钮")
        XCTAssertTrue(element("composer.model").exists, "未找到模型选择器")
        XCTAssertTrue(element("composer.plus").exists, "未找到加号入口")
        XCTAssertTrue(element("tab.chat").exists)
        XCTAssertTrue(element("tab.trajectory").exists)
        capture("01-welcome")
    }

    func test02_插件命令面板与执行() {
        let composer = element("composer.input")
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        composer.typeText("/")

        let timeCommand = element("plugin.command.time")
        XCTAssertTrue(timeCommand.waitForExistence(timeout: 5), "未出现插件命令面板，插件运行时可能未加载")
        XCTAssertTrue(element("plugin.command.upper").exists, "缺少 /upper 命令")
        XCTAssertTrue(element("plugin.command.count").exists, "缺少 /count 命令")
        capture("02-command-palette")

        timeCommand.tap()

        // 命令返回短文本时会以 Toast 提示 /time → 时间
        let toast = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "/time →")
        ).firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: 5), "命令执行后未出现结果提示")
        capture("03-command-result")
    }

    func test03_未配置APIKey时给出引导() {
        let composer = element("composer.input")
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        composer.typeText("你好")

        element("composer.send").tap()

        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "未弹出错误提示")
        XCTAssertTrue(
            alert.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "API Key")).count > 0,
            "错误提示未说明缺少 API Key"
        )
        capture("04-missing-api-key")
        alert.buttons.firstMatch.tap()
    }

    func test04_抽屉侧边栏与新建会话() {
        element("topbar.sidebar").tap()

        let newConversation = element("sidebar.new")
        XCTAssertTrue(newConversation.waitForExistence(timeout: 5), "抽屉未打开")
        XCTAssertTrue(element("sidebar.settings").exists)
        XCTAssertTrue(element("sidebar.plugins").exists)
        capture("05-sidebar")

        newConversation.tap()

        // 新建后顶栏标题应为「新会话」
        let title = app.staticTexts["新会话"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "未创建新会话")
        capture("06-new-conversation")
    }

    func test05_轨迹标签页() {
        element("tab.trajectory").tap()
        let emptyHint = app.staticTexts["当前会话还没有轨迹记录"]
        XCTAssertTrue(emptyHint.waitForExistence(timeout: 5), "轨迹页未渲染")
        capture("07-trajectory")
    }

    func test06_设置面板() {
        element("topbar.sidebar").tap()
        let settings = element("sidebar.settings")
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()

        XCTAssertTrue(app.staticTexts["API Key"].waitForExistence(timeout: 5), "设置页未打开")
        XCTAssertTrue(app.staticTexts["Base URL"].exists)
        XCTAssertTrue(app.staticTexts["默认模型"].exists)
        XCTAssertTrue(app.staticTexts["流式输出"].exists)
        capture("08-settings")

        app.buttons["完成"].tap()
    }

    func test07_插件中心() {
        element("topbar.sidebar").tap()
        let plugins = element("sidebar.plugins")
        XCTAssertTrue(plugins.waitForExistence(timeout: 5))
        plugins.tap()

        XCTAssertTrue(app.staticTexts["插件中心"].waitForExistence(timeout: 5), "插件中心未打开")
        XCTAssertTrue(app.staticTexts["时间戳助手"].exists, "未列出内置插件")
        XCTAssertTrue(app.staticTexts["文本工具"].exists)
        capture("09-plugins")

        app.buttons["命令"].tap()
        XCTAssertTrue(app.staticTexts["/time"].waitForExistence(timeout: 5), "命令列表为空")
        capture("10-plugin-commands")

        app.buttons["日志"].tap()
        XCTAssertTrue(app.staticTexts["运行日志"].waitForExistence(timeout: 5))
        capture("11-plugin-logs")
    }

    func test08_深色模式外观() {
        element("topbar.sidebar").tap()
        let settings = element("sidebar.settings")
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()

        // 外观选择器 → 深色
        let appearance = app.staticTexts["外观"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        appearance.tap()
        let dark = app.buttons["深色"].firstMatch
        if dark.waitForExistence(timeout: 5) {
            dark.tap()
        }
        app.buttons["完成"].tap()

        XCTAssertTrue(element("composer.input").waitForExistence(timeout: 5))
        capture("12-dark-appearance")
    }

    /// 注入演示会话，验证聊天界面的完整渲染（用户气泡、Markdown、代码块、操作行、思考折叠）
    func test09_对话与Markdown渲染() {
        relaunch(withSeed: true)

        // 用户消息气泡
        let userText = app.staticTexts["用 Swift 写一个防抖函数，并解释它的用途。"]
        XCTAssertTrue(userText.waitForExistence(timeout: 15), "未渲染用户消息")

        // 代码块：语言标签 + 复制按钮
        XCTAssertTrue(app.staticTexts["SWIFT"].waitForExistence(timeout: 5), "代码块未渲染")
        XCTAssertTrue(app.staticTexts["复制"].exists, "代码块缺少复制入口")

        // Markdown 列表内容（整段文本为一个可访问元素，用包含匹配）
        let listItem = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@", "减少无效请求与重复计算"))
            .firstMatch
        XCTAssertTrue(listItem.exists, "Markdown 正文未渲染")

        // 操作行
        XCTAssertTrue(app.buttons["有帮助"].exists, "缺少点赞按钮")
        XCTAssertTrue(app.buttons["没帮助"].exists, "缺少点踩按钮")
        XCTAssertTrue(app.buttons["重新生成"].exists, "缺少重新生成按钮")
        capture("13-chat-markdown")

        // 展开思考过程
        app.staticTexts["Think"].tap()
        let reasoning = app.staticTexts["用户要的是防抖函数，需要给出可运行实现并说明使用场景。先确认防抖与节流的区别，再组织代码与要点。"]
        XCTAssertTrue(reasoning.waitForExistence(timeout: 5), "思考内容未展开")
        capture("14-reasoning-expanded")

        // 轨迹页应展示会话事件
        element("tab.trajectory").tap()
        XCTAssertTrue(app.staticTexts["模型回复"].waitForExistence(timeout: 5), "轨迹未记录模型回复")
        XCTAssertTrue(app.staticTexts["用户输入"].exists, "轨迹未记录用户输入")
        capture("15-trajectory-filled")
    }

    private func relaunch(withSeed: Bool) {
        app.terminate()
        let fresh = XCUIApplication()
        fresh.launchArguments = ["-uitest-reset"] + (withSeed ? ["-uitest-seed"] : [])
        fresh.launch()
        app = fresh
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
    }
}