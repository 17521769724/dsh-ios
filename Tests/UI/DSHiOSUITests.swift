import XCTest
import UIKit

/// 端到端 UI 测试：覆盖引导门禁与表单、主页极简、输入框高度与键盘、设置即时生效、
/// 功能开关、模型列表、聊天渲染与抽屉、抽屉删除/重命名、引导页与设置页的 Key 回归。
final class DSHiOSUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = launchApp(configured: true, seed: false)
    }

    // MARK: - 工具

    @discardableResult
    private func launchApp(
        configured: Bool,
        seed: Bool,
        serverModels: Bool = false,
        extraArguments: [String] = []
    ) -> XCUIApplication {
        if let existing = app, existing.state == .runningForeground { existing.terminate() }
        let instance = XCUIApplication()
        var arguments = ["-uitest-reset"]
        if configured { arguments.append("-uitest-apikey") }
        if seed { arguments.append("-uitest-seed") }
        if serverModels { arguments.append("-uitest-server-models") }
        arguments.append(contentsOf: extraArguments)
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

    /// 打开导航栏右上角的合并功能菜单（新对话 / 置顶 / 删除 / 会话日志 / 内置浏览器）
    private func openTopMenu() {
        let trigger = element("topbar.menu")
        XCTAssertTrue(trigger.waitForExistence(timeout: 5), "缺少右上角功能菜单入口")
        trigger.tap()
    }

    /// 点击菜单项：优先按无障碍标识匹配，取不到时退回按钮文字
    private func tapMenuItem(_ identifier: String, label: String) {
        let byIdentifier = element(identifier)
        let target = byIdentifier.waitForExistence(timeout: 5)
            ? byIdentifier
            : app.buttons[label].firstMatch
        XCTAssertTrue(target.exists, "菜单项「\(label)」未出现")
        target.tap()
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
        XCTAssertTrue(element("topbar.menu").exists, "缺少右上角功能菜单入口")
        XCTAssertTrue(app.staticTexts["有什么可以帮你的吗？"].exists, "缺少空态标题")
        XCTAssertTrue(element("composer.thinking").exists, "默认应显示深度思考开关")

        // 高级入口默认关闭
        XCTAssertFalse(element("composer.model").exists, "模型选择默认不该出现")
        XCTAssertFalse(element("composer.plus").exists, "插件命令默认不该出现")
        // 会话日志与内置浏览器合并进右上角菜单，关闭开关时不应出现在菜单里
        openTopMenu()
        XCTAssertFalse(element("menu.sessionLog").exists, "会话日志默认不该出现在菜单中")
        XCTAssertFalse(element("menu.browser").exists, "内置浏览器默认不该出现在菜单中")
        XCTAssertTrue(element("menu.newChat").exists, "菜单应始终包含新对话")
        app.staticTexts["有什么可以帮你的吗？"].tap()
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
        openTopMenu()
        tapMenuItem("menu.newChat", label: "新对话")
        element("topbar.sidebar").tap()

        let row = app.buttons.matching(identifier: "sidebar.row").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "抽屉里未出现会话行")
        row.press(forDuration: 1.4)

        let delete = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "删除"))
            .firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "长按未出现删除菜单")
        capture("15a-drawer-longpress")
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
        // 验证失败应弹出提示弹窗（用户反馈：行内红字改为弹窗）
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 30), "验证失败应弹出提示弹窗")
        capture("16-onboarding-validation-failed")
        XCTAssertTrue(alert.buttons["知道了"].exists, "弹窗缺少「知道了」按钮")
        alert.buttons["知道了"].tap()
        XCTAssertTrue(submit.exists, "关闭弹窗后「验证并进入」按钮应仍然存在")
    }

    // MARK: - 智能体工具（SSH / 内置浏览器）

    /// 打开「浏览器设置」并把内置浏览器工具开关设为指定值
    /// （总开关已从设置主页移到配置页，避免两处重复）
    private func openBrowserSettingsAndToggle(_ on: Bool) {
        let browserRow = scrollTo("settings.browser")
        XCTAssertTrue(browserRow.waitForExistence(timeout: 5), "缺少浏览器设置入口")
        browserRow.tap()
        XCTAssertTrue(app.navigationBars["浏览器设置"].waitForExistence(timeout: 5), "浏览器设置页未打开")
        // 复用与其它用例一致的开关切换逻辑（带重试与状态等待，直接 tap 行容器不会切换）
        toggleFeature("browser.agentTools", on: on)
        app.navigationBars["浏览器设置"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5), "未返回设置页")
    }

    func test20_SSH设置页与内置浏览器入口() {
        openSettings()

        let sshRow = scrollTo("settings.ssh")
        XCTAssertTrue(sshRow.waitForExistence(timeout: 5), "缺少 SSH 云服务器入口")
        sshRow.tap()
        XCTAssertTrue(app.navigationBars["SSH 云服务器"].waitForExistence(timeout: 5), "SSH 设置页未打开")
        XCTAssertTrue(element("ssh.host").exists, "缺少主机输入框")
        XCTAssertTrue(element("ssh.agentTools").exists, "缺少智能体工具开关")
        XCTAssertTrue(scrollTo("ssh.command").waitForExistence(timeout: 5), "缺少命令控制台")
        capture("20-ssh-settings")

        // 返回设置主页（必须点 SSH 页自己的返回按钮，避免误点到根导航栏的「完成」把设置关掉）
        app.navigationBars["SSH 云服务器"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5), "未返回设置页")
        // 工具开关都在各自配置页里：设置主页只保留入口（不再有重复开关）
        XCTAssertTrue(scrollTo("settings.ssh").exists, "缺少 SSH 云服务器入口")
        XCTAssertFalse(element("feature.sshTool").exists, "SSH 开关不应再出现在设置主页")
        XCTAssertFalse(element("feature.browserTool").exists, "浏览器开关不应再出现在设置主页")
        openBrowserSettingsAndToggle(true)
        closeSettings()

        // 开关打开后，菜单里应出现「内置浏览器」入口
        openTopMenu()
        tapMenuItem("menu.browser", label: "内置浏览器")

        XCTAssertTrue(
            element("browser.address").waitForExistence(timeout: 10),
            "内置浏览器未弹出"
        )
        capture("21-browser")
        element("browser.done").tap()

        XCTAssertTrue(element("composer.input").waitForExistence(timeout: 5), "关闭浏览器后未回到主页")

        // 恢复默认，避免影响其它用例
        openSettings()
        openBrowserSettingsAndToggle(false)
        // 智能体工具分组：查看画面 / 工作区文件 / MCP 工具 / MCP 服务器 / 提醒事项 / 剪贴板
        XCTAssertTrue(scrollTo("feature.visionTool").waitForExistence(timeout: 5), "缺少「智能体查看画面」开关")
        XCTAssertTrue(scrollTo("feature.fileTool").waitForExistence(timeout: 5), "缺少「智能体读写工作区文件」开关")
        XCTAssertTrue(scrollTo("feature.mcpTool").waitForExistence(timeout: 5), "缺少「MCP 工具」开关")
        // 顺序：MCP 工具 → MCP 服务器 → 提醒事项与日历 → 剪贴板读写
        let mcpRow = scrollTo("settings.mcp")
        XCTAssertTrue(mcpRow.waitForExistence(timeout: 5), "缺少「MCP 服务器」入口")
        mcpRow.tap()
        // 偶发第一次点按没有推入（列表动画未结束），补一次点按再判定
        if !app.navigationBars["MCP 服务器"].waitForExistence(timeout: 6) {
            mcpRow.tap()
        }
        XCTAssertTrue(app.navigationBars["MCP 服务器"].waitForExistence(timeout: 8), "MCP 服务器页未打开")
        // 预设服务器（GitHub 官方 MCP / DeepWiki / Context7）应可直接添加
        XCTAssertTrue(app.staticTexts["GitHub 官方 MCP"].exists, "缺少 GitHub MCP 预设")
        capture("26-mcp-presets")
        // 按标题精确定位返回按钮，避免误触右上角「+」
        app.navigationBars.buttons
            .matching(NSPredicate(format: "label IN %@", ["设置", "Back", "返回"]))
            .firstMatch.tap()
        XCTAssertTrue(scrollTo("feature.reminderTool").waitForExistence(timeout: 5), "缺少「提醒事项与日历」开关")
        XCTAssertTrue(scrollTo("feature.clipboardTool").waitForExistence(timeout: 5), "缺少「剪贴板读写」开关")
        closeSettings()
    }

    // MARK: - 输入区不被拉伸（真机问题回归）

    func test15_开启模型与插件命令后输入框不铺满屏幕() {
        openSettings()
        toggleFeature("feature.modelPicker", on: true)
        toggleFeature("feature.pluginCommands", on: true)
        closeSettings()

        let composer = element("composer.input")
        XCTAssertTrue(composer.waitForExistence(timeout: 5), "开启开关后未出现输入框")
        composer.tap()
        Thread.sleep(forTimeInterval: 1.2)

        // 真机反馈：开启这两个开关后点击输入框，整个输入卡片会顶满屏幕
        XCTAssertLessThanOrEqual(
            composer.frame.height,
            60,
            "输入框高度异常（\(composer.frame.height)），疑似被拉伸铺满屏幕"
        )
        capture("17-composer-not-fullscreen")

        // 收起键盘，避免影响后续用例
        app.staticTexts["有什么可以帮你的吗？"].tap()
    }

    // MARK: - 会话重命名

    func test16_抽屉长按可重命名会话() {
        openTopMenu()
        tapMenuItem("menu.newChat", label: "新对话")
        element("topbar.sidebar").tap()

        let row = app.buttons.matching(identifier: "sidebar.row").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "抽屉里未出现会话行")
        row.press(forDuration: 1.4)

        let rename = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "重命名"))
            .firstMatch
        XCTAssertTrue(rename.waitForExistence(timeout: 5), "长按未出现重命名菜单")
        rename.tap()

        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "未弹出重命名输入框")
        let field = alert.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "重命名弹窗缺少输入框")
        field.tap()
        // 清空原有名称（多按几次删除键，空输入时无副作用）
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 20))
        field.typeText("重命名测试")
        alert.buttons["保存"].tap()

        let renamed = app.buttons.matching(identifier: "sidebar.row")
            .matching(NSPredicate(format: "label CONTAINS %@", "重命名测试"))
            .firstMatch
        XCTAssertTrue(renamed.waitForExistence(timeout: 5), "重命名后列表未立即刷新")
        capture("18-renamed")
    }

    // MARK: - 清除 API Key（真机问题回归）

    func test17_删除字符不跳页且清除按钮回到引导页() {
        openSettings()
        element("settings.apikey").tap()
        XCTAssertTrue(app.navigationBars["API Key"].waitForExistence(timeout: 5), "API Key 页未打开")

        let field = app.secureTextFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "缺少 API Key 输入框")
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 40))

        // 关键回归点：把 Key 删空后仍停留在设置页，不应跳回引导页
        XCTAssertTrue(app.navigationBars["API Key"].exists, "删除 Key 字符时不应跳转到引导页")
        XCTAssertFalse(app.staticTexts["欢迎使用 DeepSeek"].exists, "删除 Key 字符时不应出现引导页")

        // 重新填写后，用显式按钮清除 → 自动回到引导页
        field.typeText("sk-uitest-clear")
        let clear = element("settings.apikey.clear")
        XCTAssertTrue(clear.waitForExistence(timeout: 5), "缺少清除 API Key 按钮")
        clear.tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label == %@", "清除")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "清除确认弹窗未出现")
        confirm.tap()

        XCTAssertTrue(
            app.staticTexts["欢迎使用 DeepSeek"].waitForExistence(timeout: 8),
            "清除 API Key 后未回到引导页"
        )
        capture("19-cleared-apikey-onboarding")
    }

    // MARK: - 技能（自行添加 / 删除）

    func test18_技能可自行添加并删除() {
        launchApp(configured: true, seed: false)

        element("topbar.sidebar").tap()
        let entry = element("sidebar.skills")
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "抽屉缺少技能入口")
        entry.tap()

        XCTAssertTrue(app.navigationBars["技能"].waitForExistence(timeout: 5), "技能页未打开")

        // 总开关已从设置页移到技能库页顶部
        let agentToggle = element("skills.agentToggle")
        XCTAssertTrue(agentToggle.waitForExistence(timeout: 5), "技能页顶部缺少总开关")

        element("skills.add").tap()
        let nameField = element("skills.editor.name")
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "新建技能页未打开")
        nameField.tap()
        nameField.typeText("UI Test Skill")

        let contentField = element("skills.editor.content")
        contentField.tap()
        contentField.typeText("Step 1: check, Step 2: report")

        element("skills.editor.save").tap()

        let row = app.staticTexts["UI Test Skill"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "新增的技能未出现在列表里")
        // 开关应在技能列表上方（用户要求把开关放到顶部）
        XCTAssertLessThan(agentToggle.frame.minY, row.frame.minY, "总开关应位于技能列表上方")
        capture("20-skill-added")

        // 左滑删除：技能应立即消失并回到空态
        row.swipeLeft()
        // 留档：确认左滑是否真的把卡片滑开（失败时便于定位是手势没触发还是按钮没匹配上）
        capture("20b-skill-swiped")
        let deleteButton = app.buttons
            .matching(NSPredicate(format: "label == %@", "删除"))
            .firstMatch
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 5), "左滑未出现删除按钮")
        deleteButton.tap()
        // 留档：点删除后的界面（确认是否真的删掉，而不是只把卡片合上）
        capture("20c-after-delete-tap")

        XCTAssertTrue(
            element("skills.empty").waitForExistence(timeout: 5),
            "删除后技能列表未立即回到空态"
        )
    }

    // MARK: - 文件管理器与 IDE（新增功能）

    func test21_文件管理器与IDE可编写代码() {
        element("topbar.sidebar").tap()
        let filesEntry = element("sidebar.files")
        XCTAssertTrue(filesEntry.waitForExistence(timeout: 5), "抽屉缺少文件入口")
        filesEntry.tap()

        XCTAssertTrue(app.navigationBars["文件"].waitForExistence(timeout: 5), "文件页未打开")
        let empty = element("files.empty")
        XCTAssertTrue(empty.waitForExistence(timeout: 5), "空工作区应显示空状态")
        capture("21-files-empty")

        // 新建代码文件：创建后应直接进入内置编辑器
        element("files.add").tap()
        let newFile = app.buttons["新建文件"].firstMatch
        XCTAssertTrue(newFile.waitForExistence(timeout: 5), "缺少「新建文件」入口")
        newFile.tap()

        let nameField = app.alerts.firstMatch.textFields.firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "新建文件弹窗缺少输入框")
        nameField.typeText("hello.swift")
        app.alerts.firstMatch.buttons["创建"].tap()

        let editor = element("files.editor.text")
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "新建文件后未进入内置编辑器")
        editor.tap()
        editor.typeText("let answer = 42\n")
        capture("22-ide-editor")

        element("files.editor.save").tap()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(app.staticTexts["已保存"].waitForExistence(timeout: 5), "保存后状态栏未显示已保存")

        // 返回文件列表，应看到新建的文件
        tapEditorBack()
        let row = app.staticTexts["hello.swift"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "文件列表未出现新建的文件")
        capture("23-files-list")

        // 重新打开，确认代码已落盘
        row.tap()
        let reopened = element("files.editor.text")
        XCTAssertTrue(reopened.waitForExistence(timeout: 8), "未重新进入编辑器")
        let text = (reopened.value as? String) ?? ""
        XCTAssertTrue(text.contains("let answer = 42"), "重新打开后代码内容丢失：\(text)")
        capture("24-ide-reopened")

        tapEditorBack()
        app.navigationBars["文件"].buttons["完成"].firstMatch.tap()
        XCTAssertTrue(element("composer.input").waitForExistence(timeout: 5), "关闭文件页后未回到主页")
    }

    /// 点编辑器页自己的返回按钮（上一页标题是「文件」），
    /// 不要用 firstMatch：编辑器导航栏里还有一个「保存」，根导航栏里还有「完成」，容易串位
    private func tapEditorBack() {
        let back = app.navigationBars.buttons
            .matching(NSPredicate(format: "label IN %@", ["文件", "Back", "返回"]))
            .firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), "编辑器缺少返回按钮")
        back.tap()
        XCTAssertTrue(app.navigationBars["文件"].waitForExistence(timeout: 5), "未回到文件列表")
    }

    // MARK: - 冷启动顶栏（真机问题回归：图标跳动）

    func test22_冷启动顶栏图标不跳动() {
        launchApp(configured: true, seed: false)
        // 启动后立刻抓一帧，再等布局稳定后对比（截图会随 CI 产物一起收集）
        capture("25-cold-start-early")

        let sidebar = element("topbar.sidebar")
        XCTAssertTrue(sidebar.waitForExistence(timeout: 10), "缺少左侧顶栏图标")
        let early = sidebar.frame

        Thread.sleep(forTimeInterval: 1.5)
        let settled = sidebar.frame
        capture("25-cold-start-settled")

        XCTAssertEqual(early.minX, settled.minX, accuracy: 0.5, "冷启动后左侧顶栏图标横向位移")
        XCTAssertEqual(early.minY, settled.minY, accuracy: 0.5, "冷启动后左侧顶栏图标纵向位移")

        let menu = element("topbar.menu")
        XCTAssertTrue(menu.exists, "缺少右侧顶栏图标")
        let menuEarly = menu.frame
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertEqual(menuEarly.minX, menu.frame.minX, accuracy: 0.5, "冷启动后右侧顶栏图标横向位移")
        XCTAssertEqual(menuEarly.minY, menu.frame.minY, accuracy: 0.5, "冷启动后右侧顶栏图标纵向位移")
    }

    /// 思考过程与工具过程各自打开独立弹窗（用户反馈：两个入口点开内容一模一样）
    func test25_思考与工具弹窗内容独立() {
        launchApp(configured: true, seed: true)

        // 演示会话里助手消息带有「思考过程」与「工具过程」两行
        let thinking = element("message.thinking")
        XCTAssertTrue(thinking.waitForExistence(timeout: 10), "缺少「思考过程」入口")
        thinking.tap()
        XCTAssertTrue(app.navigationBars["思考过程"].waitForExistence(timeout: 5), "思考过程弹窗未打开")
        capture("31-sheet-reasoning")
        app.navigationBars["思考过程"].buttons.firstMatch.tap()

        let process = element("message.process")
        XCTAssertTrue(process.waitForExistence(timeout: 5), "缺少「工具过程」入口")
        process.tap()
        XCTAssertTrue(app.navigationBars["工具过程"].waitForExistence(timeout: 5), "工具过程弹窗未打开")
        // 两个弹窗标题不同，内容也各自独立
        XCTAssertFalse(app.navigationBars["思考过程"].exists, "工具弹窗不应再显示思考内容")
        capture("32-sheet-steps")
        app.navigationBars["工具过程"].buttons.firstMatch.tap()

        XCTAssertTrue(element("composer.input").waitForExistence(timeout: 5), "关闭弹窗后未回到对话页")
    }

    // MARK: - 权限（首次引导 + 设置里的权限状态页）

    func test23_首次启动权限引导与权限状态页() {
        // 强制弹出引导；不带 -uitest-skip-permission-request 之外的干扰参数时此处只跑 UI，
        // 避免系统授权弹窗挡住用例
        launchApp(
            configured: true,
            seed: false,
            extraArguments: ["-uitest-permissions-primer", "-uitest-skip-permission-request"]
        )

        XCTAssertTrue(app.navigationBars["权限申请"].waitForExistence(timeout: 15), "首次启动应弹出权限申请页")
        XCTAssertTrue(element("permissions.row.reminders").waitForExistence(timeout: 5), "缺少提醒事项权限行")
        XCTAssertTrue(element("permissions.row.clipboard").exists, "缺少剪贴板权限行")
        capture("27-permissions-primer")
        // 「完成」固定在导航栏右上角
        let done = element("permissions.done")
        XCTAssertTrue(done.waitForExistence(timeout: 5), "权限引导页缺少「完成」按钮")
        done.tap()

        // 设置 → 关于 → 权限状态
        openSettings()
        let permissionsRow = scrollTo("settings.permissions")
        XCTAssertTrue(permissionsRow.waitForExistence(timeout: 5), "设置里缺少权限状态入口")
        permissionsRow.tap()
        XCTAssertTrue(app.navigationBars["权限状态"].waitForExistence(timeout: 5), "权限状态页未打开")
        XCTAssertTrue(element("permissions.row.calendar").waitForExistence(timeout: 5), "权限状态页缺少日历行")
        // 按钮只保留「一键申请权限」（不带括号说明）
        XCTAssertTrue(
            app.buttons["一键申请权限"].waitForExistence(timeout: 5),
            "缺少「一键申请权限」按钮"
        )
        capture("28-permissions-status")

        let back = app.navigationBars.buttons
            .matching(NSPredicate(format: "label IN %@", ["设置", "Back", "返回"]))
            .firstMatch
        back.tap()
        closeSettings()
    }

    // MARK: - MCP 服务器（未登录校验 + 左滑删除）

    func test24_MCP服务器左滑删除与GitHub未登录提示() {
        launchApp(configured: true, seed: false)
        openSettings()
        let mcpRow = scrollTo("settings.mcp")
        XCTAssertTrue(mcpRow.waitForExistence(timeout: 5), "缺少 MCP 服务器入口")
        mcpRow.tap()
        if !app.navigationBars["MCP 服务器"].waitForExistence(timeout: 6) {
            mcpRow.tap()
        }
        XCTAssertTrue(app.navigationBars["MCP 服务器"].waitForExistence(timeout: 8), "MCP 服务器页未打开")

        // 未登录 GitHub 时点 GitHub 官方 MCP：提示登录，不写入配置
        app.staticTexts["GitHub 官方 MCP"].firstMatch.tap()
        let alert = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "GitHub 账号未登录")).firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "未登录时应提示「GitHub 账号未登录」")
        capture("29-mcp-github-login-required")
        app.buttons["知道了"].tap()
        XCTAssertTrue(app.staticTexts["还没有 MCP 服务器，点右上角「+」添加"].exists, "未登录时不应添加服务器")

        // 手动添加一台（地址故意不可达：连接失败不影响列表与删除）
        element("mcp.add").tap()
        XCTAssertTrue(app.navigationBars["添加 MCP 服务器"].waitForExistence(timeout: 5))
        element("mcp.editor.name").tap()
        element("mcp.editor.name").typeText("测试服务器")
        element("mcp.editor.url").tap()
        element("mcp.editor.url").typeText("http://127.0.0.1:1/mcp")
        element("mcp.editor.save").tap()

        XCTAssertTrue(app.staticTexts["测试服务器"].waitForExistence(timeout: 15), "服务器未出现在列表里")

        // 左滑删除：与技能库同一套逻辑（固定红色删除区）
        app.staticTexts["测试服务器"].swipeLeft()
        capture("30-mcp-row-swiped")
        let deleteButton = app.buttons["删除服务器"].firstMatch
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 5), "左滑应出现删除按钮")
        deleteButton.tap()
        XCTAssertTrue(
            app.staticTexts["还没有 MCP 服务器，点右上角「+」添加"].waitForExistence(timeout: 5),
            "删除后应回到空状态"
        )

        let back = app.navigationBars.buttons
            .matching(NSPredicate(format: "label IN %@", ["设置", "Back", "返回"]))
            .firstMatch
        back.tap()
        closeSettings()
    }
}