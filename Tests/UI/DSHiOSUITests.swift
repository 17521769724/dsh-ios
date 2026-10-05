import XCTest
import UIKit

/// 端到端 UI 测试：覆盖引导门禁、主页极简、输入框高度与键盘、设置即时生效、
/// 功能开关、模型名称、聊天渲染与抽屉。
final class DSHiOSUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = launchApp(configured: true, seed: false)
    }

    // MARK: - 工具

    @discardableResult
    private func launchApp(configured: Bool, seed: Bool) -> XCUIApplication {
        if let existing = app, existing.state == .runningForeground { existing.terminate() }
        let instance = XCUIApplication()
        var arguments = ["-uitest-reset"]
        if configured { arguments.append("-uitest-apikey") }
        if seed { arguments.append("-uitest-seed") }
        instance.launchArguments = arguments
        instance.launch()
        app = instance
        XCTAssertTrue(instance.wait(for: .runningForeground, timeout: 20), "应用未能进入前台")
        return instance
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func capture(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? screenshot.pngRepresentation.write(to: directory.appendingPathComponent("\(name).png"))
    }

    /// 整屏平均亮度，用于验证深浅色是否真的切换
    private func averageBrightness() -> CGFloat {
        let image = XCUIScreen.main.screenshot().image
        guard let cgImage = image.cgImage else { return -1 }
        var pixel: [UInt8] = [0, 0, 0, 0]
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return -1 }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let red = CGFloat(pixel[0]) / 255
        let green = CGFloat(pixel[1]) / 255
        let blue = CGFloat(pixel[2]) / 255
        return 0.299 * red + 0.587 * green + 0.114 * blue
    }

    private func openSettings() {
        element("topbar.sidebar").tap()
        let entry = element("sidebar.settings")
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "抽屉未打开或缺少设置入口")
        entry.tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5), "设置页未打开")
    }

    private func closeSettings() {
        let done = app.buttons["完成"].firstMatch
        if done.exists { done.tap() }
        XCTAssertTrue(element("composer.input").waitForExistence(timeout: 5))
    }

    /// 设置页为懒加载列表，首屏之外的开关需先滚动到位
    @discardableResult
    private func scrollTo(_ identifier: String, maxSwipes: Int = 8) -> XCUIElement {
        var target = element(identifier)
        var swipes = 0
        while !target.exists && swipes < maxSwipes {
            app.swipeUp()
            target = element(identifier)
            swipes += 1
        }
        return target
    }

    private func toggleFeature(_ identifier: String, on: Bool) {
        let toggle = scrollTo(identifier)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "未找到开关 \(identifier)")
        var attempts = 0
        while attempts < 4 {
            let isOn = (toggle.value as? String) == "1"
            if isOn == on { break }
            toggle.tap()
            attempts += 1
        }
    }

    // MARK: - 引导门禁

    func test01_未配置Key时强制进入引导页() {
        launchApp(configured: false, seed: false)

        XCTAssertTrue(app.staticTexts["欢迎使用 DeepSeek"].waitForExistence(timeout: 10), "未进入引导页")
        XCTAssertFalse(element("composer.input").exists, "未配置 Key 时不应进入主页")
        capture("01-onboarding")

        // 填写 Key 后进入主页
        let field = app.textFields.matching(identifier: "onboarding.key").firstMatch
        let target = field.exists ? field : app.secureTextFields.firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 5), "未找到 Key 输入框")
        target.tap()
        target.typeText("sk-uitest-onboarding")

        app.buttons["跳过验证，直接保存"].tap()

        XCTAssertTrue(element("composer.input").waitForExistence(timeout: 10), "保存 Key 后未进入主页")
        capture("02-after-onboarding")
    }

    // MARK: - 主页默认极简

    func test02_主页默认只保留核心元素() {
        XCTAssertTrue(element("composer.input").waitForExistence(timeout: 10))
        XCTAssertTrue(element("topbar.sidebar").exists, "缺少会话列表入口")
        XCTAssertTrue(element("topbar.newchat").exists, "缺少新对话入口")
        XCTAssertTrue(app.staticTexts["有什么可以帮你的吗？"].exists, "缺少空态标题")
        XCTAssertTrue(element("composer.thinking").exists, "默认应显示深度思考开关")

        // 高级入口默认关闭
        XCTAssertFalse(element("tab.trajectory").exists, "轨迹标签默认不该出现")
        XCTAssertFalse(element("composer.model").exists, "模型选择默认不该出现")
        XCTAssertFalse(element("composer.plus").exists, "插件命令默认不该出现")
        XCTAssertFalse(element("topbar.sessionlog").exists, "会话日志入口默认不该出现")
        capture("03-home-minimal")
    }

    // MARK: - 输入框高度（真机问题回归）

    func test03_输入框不会撑满屏幕且支持多行() {
        let composer = element("composer.input")
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()

        let screenHeight = app.windows.firstMatch.frame.height
        for index in 1...12 {
            composer.typeText("第 \(index) 行文字\n")
        }

        let height = composer.frame.height
        XCTAssertLessThan(
            height,
            screenHeight * 0.5,
            "输入框高度 \(height) 超过半屏（屏高 \(screenHeight)），仍存在撑满屏幕的问题"
        )
        XCTAssertLessThanOrEqual(height, 140, "输入框高度应被限制在 140pt 以内，实际 \(height)")

        // 对话区域仍可见
        XCTAssertTrue(app.staticTexts["有什么可以帮你的吗？"].exists, "输入框疑似遮挡了对话区域")
        capture("04-composer-multiline")
    }

    // MARK: - 键盘收起（真机问题回归）

    func test04_键盘可通过完成按钮与点击空白收起() throws {
        let composer = element("composer.input")
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()

        try XCTSkipIf(app.keyboards.count == 0, "模拟器未启用软键盘，跳过键盘断言")

        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 5), "键盘未弹出")
        element("keyboard.done").tap()
        XCTAssertTrue(
            app.keyboards.element.waitForNonExistence(timeout: 3),
            "点击「完成」后键盘未收起"
        )

        composer.tap()
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 5), "键盘未再次弹出")
        app.staticTexts["有什么可以帮你的吗？"].tap()
        XCTAssertTrue(
            app.keyboards.element.waitForNonExistence(timeout: 3),
            "点击空白处后键盘未收起"
        )
    }

    // MARK: - 外观即时生效（真机问题回归）

    func test05_设置内切换深浅色立即生效() {
        openSettings()

        let before = averageBrightness()
        element("settings.theme").tap()
        assertTrueNavigation("外观")
        element("theme.dark").tap()
        Thread.sleep(forTimeInterval: 0.6)
        let afterDark = averageBrightness()
        capture("05-settings-dark")

        XCTAssertLessThan(
            afterDark,
            before - 0.15,
            "切换到深色后界面亮度未下降（前 \(before) / 后 \(afterDark)），设置页可能未立即刷新"
        )

        // 切回浅色
        element("theme.light").tap()
        Thread.sleep(forTimeInterval: 0.6)
        let afterLight = averageBrightness()
        XCTAssertGreaterThan(afterLight, afterDark + 0.15, "切回浅色后亮度未恢复")

        // 恢复跟随系统
        element("theme.system").tap()
        app.navigationBars.buttons.firstMatch.tap()
        closeSettings()
    }

    private func assertTrueNavigation(_ title: String) {
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5), "未进入「\(title)」页面")
    }

    // MARK: - 功能开关

    func test06_功能开关可开启轨迹与模型选择() {
        openSettings()
        toggleFeature("feature.trajectoryTab", on: true)
        toggleFeature("feature.modelPicker", on: true)
        toggleFeature("feature.usageMetrics", on: true)
        closeSettings()

        XCTAssertTrue(element("tab.trajectory").waitForExistence(timeout: 5), "开启后仍未出现轨迹标签")
        XCTAssertTrue(element("composer.model").waitForExistence(timeout: 5), "开启后仍未出现模型选择")
        capture("06-features-on")

        element("tab.trajectory").tap()
        XCTAssertTrue(app.staticTexts["当前会话还没有轨迹记录"].waitForExistence(timeout: 5))
        element("tab.chat").tap()

        // 关闭后应恢复简洁
        openSettings()
        toggleFeature("feature.trajectoryTab", on: false)
        toggleFeature("feature.modelPicker", on: false)
        toggleFeature("feature.usageMetrics", on: false)
        closeSettings()
        XCTAssertTrue(
            element("tab.trajectory").waitForNonExistence(timeout: 3),
            "关闭开关后轨迹标签仍然存在"
        )
    }

    func test07_插件命令开关与抽屉入口() {
        openSettings()
        toggleFeature("feature.pluginCommands", on: true)
        closeSettings()

        let composer = element("composer.input")
        composer.tap()
        composer.typeText("/")

        let timeCommand = element("plugin.command.time")
        XCTAssertTrue(timeCommand.waitForExistence(timeout: 5), "插件命令面板未出现")
        XCTAssertTrue(element("plugin.command.upper").exists, "缺少 /upper 命令")
        capture("07-plugin-commands")

        timeCommand.tap()
        let toast = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "/time →")
        ).firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: 5), "命令执行后未出现结果")

        // 抽屉中出现插件入口
        element("topbar.sidebar").tap()
        XCTAssertTrue(element("sidebar.plugins").waitForExistence(timeout: 5), "抽屉缺少插件中心入口")
        capture("08-drawer-with-plugins")
        element("sidebar.settings").tap()
    }

    // MARK: - 模型名称（真机问题回归）

    func test08_模型名称与官方一致() {
        openSettings()
        element("settings.model").tap()
        assertTrueNavigation("模型")

        XCTAssertTrue(app.staticTexts["DeepSeek-V4.1-Flash"].waitForExistence(timeout: 5), "缺少 V4.1-Flash")
        XCTAssertTrue(app.staticTexts["deepseek-flash"].exists, "缺少模型 ID")
        XCTAssertTrue(app.staticTexts["DeepSeek-V4-Pro"].exists, "缺少 V4-Pro")
        capture("09-models")

        app.navigationBars.buttons.firstMatch.tap()
        closeSettings()
    }

    // MARK: - 聊天渲染

    func test09_聊天渲染与思考折叠() {
        launchApp(configured: true, seed: true)

        let userText = app.staticTexts["用 Swift 写一个防抖函数，并解释它的用途。"]
        XCTAssertTrue(userText.waitForExistence(timeout: 15), "未渲染用户消息")
        XCTAssertTrue(app.staticTexts["SWIFT"].waitForExistence(timeout: 5), "代码块未渲染")

        let listItem = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@", "减少无效请求与重复计算"))
            .firstMatch
        XCTAssertTrue(listItem.exists, "Markdown 正文未渲染")
        XCTAssertTrue(app.buttons["有帮助"].exists, "缺少点赞按钮")
        XCTAssertTrue(app.buttons["重新生成"].exists, "缺少重新生成按钮")
        capture("10-chat-render")

        element("message.thinking").tap()
        let reasoning = app.staticTexts["用户要的是防抖函数，需要给出可运行实现并说明使用场景。先确认防抖与节流的区别，再组织代码与要点。"]
        XCTAssertTrue(reasoning.waitForExistence(timeout: 5), "思考内容未展开")
        capture("11-thinking-expanded")
    }

    // MARK: - 抽屉

    func test10_抽屉新建对话() {
        element("topbar.sidebar").tap()
        let newConversation = element("sidebar.new")
        XCTAssertTrue(newConversation.waitForExistence(timeout: 5), "抽屉未打开")
        capture("12-drawer")
        newConversation.tap()

        XCTAssertTrue(app.navigationBars["DeepSeek"].waitForExistence(timeout: 5), "新建对话后标题不正确")
        XCTAssertTrue(element("composer.input").waitForExistence(timeout: 5))
    }
}