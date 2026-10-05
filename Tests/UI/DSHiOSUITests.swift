import XCTest
import UIKit

/// 端到端 UI 测试：覆盖引导门禁与表单、主页极简、输入框高度与键盘、设置即时生效、
/// 功能开关、模型列表、聊天渲染与抽屉、抽屉删除即时刷新、引导页验证失败回归。
final class DSHiOSUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = launchApp(configured: true, seed: false)
    }

    // MARK: - 工具

    @discardableResult
    private func launchApp(configured: Bool, seed: Bool, serverModels: Bool = false) -> XCUIApplication {
        if let existing = app, existing.state == .runningForeground { existing.terminate() }
        let instance = XCUIApplication()
        var arguments = ["-uitest-reset"]
        if configured { arguments.append("-uitest-apikey") }
        if seed { arguments.append("-uitest-seed") }
        if serverModels { arguments.append("-uitest-server-models") }
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

    /// 优先匹配开关元素（SwiftUI Toggle 在无障碍树中是 switch），否则退回通用查询
    private func uiElement(_ identifier: String) -> XCUIElement {
        let toggle = app.switches.matching(identifier: identifier).firstMatch
        return toggle.exists ? toggle : element(identifier)
    }

    /// 设置页为懒加载列表，首屏之外的开关需先滚动到位；
    /// 滚动带惯性，需等其停下再操作，否则点击会落到其他行
    @discardableResult
    private func scrollTo(_ identifier: String, maxSwipes: Int = 10) -> XCUIElement {
        var target = uiElement(identifier)
        var swipes = 0
        while !(target.exists && target.isHittable) && swipes < maxSwipes {
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.5)
            target = uiElement(identifier)
            swipes += 1
        }
        return target
    }

    private func toggleFeature(_ identifier: String, on: Bool) {
        let toggle = scrollTo(identifier)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "未找到开关 \(identifier)")
        let expected = on ? "1" : "0"
        for _ in 0..<5 {
            if (toggle.value as? String) == expected {
                Thread.sleep(forTimeInterval: 0.4)
                return
            }
            tapToggle(toggle)
            // 等待开关状态刷新，避免重复点击把开关又切回去
            for _ in 0..<15 {
                if (toggle.value as? String) == expected {
                    Thread.sleep(forTimeInterval: 0.4)
                    return
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        XCTFail("开关 \(identifier) 未切换到\(on ? "开启" : "关闭")")
    }

    /// 与系统设置一致，点击开关行标签区不会切换：优先点开关本体，其次点行尾区域
    private func tapToggle(_ toggle: XCUIElement) {
        let switchElement = toggle.switches.firstMatch
        if switchElement.exists {
            switchElement.tap()
        } else {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        }
    }

    // MARK: - 引导门禁与表单

    func test01_未配置Key时强制进入引导页() {
        launchApp(configured: false, seed: false)

        XCTAssertTrue(app.staticTexts["欢迎使用 DeepSeek"].waitForExistence(timeout: 10), "未进入引导页")
        XCTAssertFalse(element("composer.input").exists, "未配置 Key 时不应进入主页")

        // API 地址在 Key 上方，且两者都是常显输入框（没有折起的「高级选项」）
        let baseURL = app.textFields.matching(identifier: "onboarding.baseurl").firstMatch
        XCTAssertTrue(baseURL.waitForExistence(timeout: 5), "缺少 API 地址输入框")
        XCTAssertFalse(app.staticTexts["高级选项"].exists, "高级选项折叠应已移除")
        capture("01-onboarding")

        let baseFrame = baseURL.frame
        let keyField = app.secureTextFields.firstMatch
        XCTAssertTrue(keyField.waitForExistence(timeout: 5), "缺少 API Key 输入框")
        XCTAssertLessThan(baseFrame.minY, keyField.frame.minY, "API 地址应位于 API Key 上方")

        // 填写 Key 后进入主页
        keyField.tap()
        keyField.typeText("sk-uitest-onboarding")
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 5), "键盘未弹出")

        // 点击空白处收起键盘；点击输入框内部不应收起
        app.staticTexts["欢迎使用 DeepSeek"].tap()
        XCTAssertTrue(app.keyboards.element.waitForNonExistence(timeout: 3), "点击空白处后键盘未收起")

        baseURL.tap()
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 5), "键盘未再次弹出")
        keyField.tap()
        XCTAssertTrue(app.keyboards.element.exists, "点击输入框内部后键盘不应收起")

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
        XCTAssertFalse(element("composer.model").exists, "模型选择默认不该出现")
        XCTAssertFalse(element("composer.plus").exists, "插件命令默认不该出现")
        XCTAssertFalse(element("topbar.sessionlog").exists, "会话日志入口默认不该出现")
        // 对话/轨迹切换栏已整体移除
        XCTAssertFalse(app.staticTexts["轨迹"].exists, "首页不应再出现轨迹切换")
        capture("03-home-minimal")
    }

    // MARK: - 输入框高度（真机问题回归）

    func test03_输入框不会撑满屏幕且支持多行() {
        let composer = element("composer.input")
        XCTAssertTrue(composer.waitForExistence(timeout: 10))

        // 空态应保持单行高度，不允许预留多行空白
        XCTAssertLessThanOrEqual(
            composer.frame.height,
            60,
            "空态输入框高度 \(composer.frame.height) 偏大，疑似按上限高度占位"
        )

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
        capture("04-composer-multiline")

        // 真机问题回归：通过「+ → 清空输入」清空后，输入区不能撑高
        scrollToPluginMenu()
        let clearItem = app.buttons["清空输入"]
        XCTAssertTrue(clearItem.waitForExistence(timeout: 5), "缺少清空输入菜单项")
        clearItem.tap()
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertLessThanOrEqual(
            element("composer.input").frame.height,
            60,
            "清空输入后输入框被撑高到 \(element("composer.input").frame.height)"
        )
        XCTAssertTrue(app.staticTexts["有什么可以帮你的吗？"].exists, "清空后对话区域被遮挡")
        capture("04b-composer-after-clear")

        // 「+ → 插件命令」同样不能撑高输入区
        element("composer.plus").tap()
        let commandItem = app.buttons["插件命令"]
        XCTAssertTrue(commandItem.waitForExistence(timeout: 5), "缺少插件命令菜单项")
        commandItem.tap()
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertLessThanOrEqual(
            element("composer.input").frame.height,
            60,
            "选择插件命令后输入框被撑高到 \(element("composer.input").frame.height)"
        )
        capture("04c-composer-after-command")
    }

    /// 先确保插件命令开关打开，再展开输入框左侧「+」菜单
    private func scrollToPluginMenu() {
        if !element("composer.plus").exists {
            openSettings()
            toggleFeature("feature.pluginCommands", on: true)
            closeSettings()
        }
        element("composer.plus").tap()
    }

    // MARK: - 键盘收起（真机问题回归）

    func test04_键盘可通过点击空白收起且不再有完成按钮() throws {
        let composer = element("composer.input")
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()

        try XCTSkipIf(app.keyboards.count == 0, "模拟器未启用软键盘，跳过键盘断言")

        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 5), "键盘未弹出")
        // 真机反馈：键盘上方不再保留用于收起键盘的「完成」按钮
        XCTAssertFalse(element("keyboard.done").exists, "键盘不应再出现「完成」按钮")
        XCTAssertFalse(app.buttons["完成"].exists, "键盘不应再出现「完成」按钮")

        app.staticTexts["有什么可以帮你的吗？"].tap()
        XCTAssertTrue(
            app.keyboards.element.waitForNonExistence(timeout: 3),
            "点击空白处后键盘未收起"
        )

        // 点击输入框内部不应收起键盘
        composer.tap()
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 5), "键盘未再次弹出")
        composer.tap()
        XCTAssertTrue(app.keyboards.element.exists, "点击输入框内部不应收起键盘")
    }

    // MARK: - 外观即时生效（真机问题回归）

    func test05_设置内切换深浅色立即生效() {
        openSettings()

        let before = averageBrightness()
        // 点击行中间留白区域，验证整行都可点（真机反馈过点了没反应）
        let themeRow = element("settings.theme")
        XCTAssertTrue(themeRow.waitForExistence(timeout: 5), "未找到外观入口")
        themeRow.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5)).tap()
        XCTAssertTrue(app.navigationBars["外观"].waitForExistence(timeout: 5), "外观入口点击后未进入二级页")

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

    // MARK: - 功能开关

    func test06_功能开关可开启模型选择与运行指标() {
        openSettings()
        toggleFeature("feature.modelPicker", on: true)
        toggleFeature("feature.usageMetrics", on: true)
        capture("06-settings-features")
        closeSettings()
        capture("06-home-after-toggles")

        XCTAssertTrue(element("composer.model").waitForExistence(timeout: 5), "开启后仍未出现模型选择")
        XCTAssertTrue(app.staticTexts["0 轮"].exists, "开启后仍未出现运行指标")

        // 模型菜单只应包含模型本身，不应包含服务端拉取入口
        element("composer.model").tap()
        XCTAssertTrue(app.buttons["DeepSeek-V4.1-Flash"].waitForExistence(timeout: 5), "模型菜单未列出模型")
        XCTAssertFalse(
            app.buttons["从服务端获取模型列表"].exists,
            "输入框的模型菜单不应包含服务端拉取入口"
        )
        capture("06-model-menu")
        app.staticTexts["有什么可以帮你的吗？"].tap()

        // 关闭后应恢复简洁
        openSettings()
        toggleFeature("feature.modelPicker", on: false)
        toggleFeature("feature.usageMetrics", on: false)
        closeSettings()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertFalse(element("composer.model").exists, "关闭开关后模型选择仍然存在")
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

    // MARK: - 模型列表（真机问题回归）

    func test08_模型列表只保留在售模型() {
        openSettings()
        element("settings.model").tap()
        XCTAssertTrue(app.navigationBars["模型"].waitForExistence(timeout: 5), "模型页未打开")

        XCTAssertTrue(app.staticTexts["DeepSeek-V4.1-Flash"].waitForExistence(timeout: 5), "缺少 V4.1-Flash")
        XCTAssertTrue(app.staticTexts["deepseek-flash"].exists, "缺少模型 ID")
        XCTAssertTrue(app.staticTexts["DeepSeek-V4-Pro"].exists, "缺少 V4-Pro")
        XCTAssertFalse(app.staticTexts["deepseek-chat（已弃用）"].exists, "不应再列已下线模型")
        XCTAssertFalse(app.staticTexts["deepseek-reasoner（已弃用）"].exists, "不应再列已下线模型")
        capture("09-models")

        app.navigationBars.buttons.firstMatch.tap()
        closeSettings()
    }

    /// 服务端返回模型列表后，设置页上方的列表应立即反映服务端结果
    func test09_服务端模型列表刷新后立即生效() {
        launchApp(configured: true, seed: false, serverModels: true)
        openSettings()
        element("settings.model").tap()
        XCTAssertTrue(app.navigationBars["模型"].waitForExistence(timeout: 5), "模型页未打开")

        XCTAssertTrue(
            app.staticTexts["deepseek-vl-experimental"].waitForExistence(timeout: 5),
            "服务端返回的模型未出现在上方列表，说明拉取后没有立即刷新"
        )
        capture("13-models-from-server")

        app.navigationBars.buttons.firstMatch.tap()
        closeSettings()
    }

    // MARK: - 连接测试（行内）

    func test10_连接测试在行内完成() {
        openSettings()
        let row = element("settings.connection")
        XCTAssertTrue(row.waitForExistence(timeout: 5), "缺少连接测试行")
        XCTAssertTrue(app.staticTexts["点击测试"].exists, "连接测试行应提示可点击")
        row.tap()

        // 无网络环境下会给出失败文案，但结果必须出现在行内而不是二级页面
        let result = element("settings.connection.result")
        XCTAssertTrue(result.waitForExistence(timeout: 25), "连接测试结果未出现在行内")
        XCTAssertFalse(app.navigationBars["连接测试"].exists, "连接测试不应进入二级页面")
        capture("14-connection-inline")
        closeSettings()
    }

    // MARK: - 聊天渲染

    func test11_聊天渲染与思考折叠() {
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

    func test12_抽屉新建对话() {
        element("topbar.sidebar").tap()
        let newConversation = element("sidebar.new")
        XCTAssertTrue(newConversation.waitForExistence(timeout: 5), "抽屉未打开")
        capture("12-drawer")
        newConversation.tap()

        XCTAssertTrue(app.navigationBars["DeepSeek"].waitForExistence(timeout: 5), "新建对话后标题不正确")
        XCTAssertTrue(element("composer.input").waitForExistence(timeout: 5))
    }

    // MARK: - 抽屉删除即时刷新（真机问题回归）

    func test13_抽屉长按删除会话后列表立即刷新() {
        // 新建一个会话，让抽屉里有一条记录
        element("topbar.newchat").tap()
        element("topbar.sidebar").tap()

        let row = app.buttons.matching(identifier: "sidebar.row").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "抽屉里未出现会话行")
        row.press(forDuration: 1.4)

        let delete = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "删除"))
            .firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "长按未出现删除菜单")
        delete.tap()

        // 关键回归点：不关闭抽屉，列表就应该立即刷新为空态
        XCTAssertTrue(
            app.staticTexts["还没有对话"].waitForExistence(timeout: 5),
            "删除后抽屉列表未立即刷新（此前需要重开抽屉才更新）"
        )
        capture("15-drawer-delete-refresh")
    }

    // MARK: - 引导页验证失败（真机问题回归）

    func test14_验证失败后按钮不消失() {
        launchApp(configured: false, seed: false)

        let keyField = app.secureTextFields.firstMatch
        XCTAssertTrue(keyField.waitForExistence(timeout: 10), "缺少 API Key 输入框")
        keyField.tap()
        keyField.typeText("sk-invalid-for-test")
        // 收起键盘，避免遮挡按钮
        app.staticTexts["欢迎使用 DeepSeek"].tap()

        let submit = element("onboarding.submit")
        XCTAssertTrue(submit.waitForExistence(timeout: 5), "缺少「验证并进入」按钮")
        submit.tap()

        // 验证结束（网络错误或 401）前后，按钮都必须一直存在：
        // 真机上曾出现验证失败后按钮被整个移除的问题。
        let start = Date()
        while Date().timeIntervalSince(start) < 45 {
            XCTAssertTrue(submit.exists, "验证过程中「验证并进入」按钮消失了")
            if Date().timeIntervalSince(start) > 8, submit.isEnabled {
                break
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertTrue(submit.exists, "验证失败后「验证并进入」按钮消失了")
        capture("16-onboarding-validation-failed")
    }
}