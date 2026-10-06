import Foundation
import JavaScriptCore

/// 暴露给 JavaScript 插件的宿主 API（插件脚本中通过全局对象 `dsh` 访问）。
///
/// 契约示例：
/// ```js
/// dsh.log("hello from plugin")
/// dsh.registerCommand("upper", "转大字", function (text) { return text.toUpperCase() })
/// dsh.onMessage(function (text, role) { return text })
/// ```
@objc protocol DSHJSExports: JSExport {
    func log(_ message: String)
    func registerCommand(_ name: String, _ summary: String, _ handler: JSValue)
    func onMessage(_ handler: JSValue)
    func setStorage(_ key: String, _ value: String)
    func getStorage(_ key: String) -> String
    func getSetting(_ key: String) -> String
    func version() -> String
}

/// JS 桥接实现，收集插件注册的命令与钩子。
final class DSHJSBridge: NSObject, DSHJSExports {

    weak var runtime: PluginRuntime?
    let pluginID: String

    init(pluginID: String) {
        self.pluginID = pluginID
    }

    func log(_ message: String) {
        runtime?.appendLog(pluginID: pluginID, level: "info", message: message)
    }

    func registerCommand(_ name: String, _ summary: String, _ handler: JSValue) {
        runtime?.registerCommand(pluginID: pluginID, name: name, summary: summary, handler: handler)
    }

    func onMessage(_ handler: JSValue) {
        runtime?.registerMessageHook(pluginID: pluginID, handler: handler)
    }

    func setStorage(_ key: String, _ value: String) {
        runtime?.setStorage(pluginID: pluginID, key: key, value: value)
    }

    func getStorage(_ key: String) -> String {
        runtime?.getStorage(pluginID: pluginID, key: key) ?? ""
    }

    func getSetting(_ key: String) -> String {
        runtime?.getSetting(key: key) ?? ""
    }

    func version() -> String {
        "DSH-iOS/0.1 (JavaScriptCore)"
    }
}

/// 基于 JavaScriptCore 的插件运行时。
/// 每个插件在独立的 JSContext 中执行，互不干扰。
final class PluginRuntime {

    // MARK: - 状态

    private(set) var commands: [PluginCommand] = []
    private(set) var logs: [PluginLogEntry] = []
    private(set) var loadedPluginIDs: [String] = []
    private(set) var failedPlugins: [String: String] = [:]

    private var contexts: [String: JSContext] = [:]
    private var commandHandlers: [String: JSValue] = [:]
    private var messageHooks: [String: [JSValue]] = [:]
    private var messageHookOrder: [String] = []
    private var storage: [String: String] = [:]

    /// 由宿主注入的设置读取器：插件可通过 dsh.getSetting(key) 读取用户在设置里填写的内容
    var settingProvider: ((String) -> String)?

    private let maxLogEntries = 300

    // MARK: - 加载

    /// 加载单个插件脚本；失败时记录错误但不影响其它插件。
    func load(manifest: PluginManifest, script: String) {
        unload(pluginID: manifest.id)

        guard let context = JSContext() else {
            failedPlugins[manifest.id] = "无法创建 JavaScript 运行时"
            return
        }

        context.exceptionHandler = { [weak self] _, exception in
            let text = exception?.toString() ?? "未知 JS 异常"
            self?.appendLog(pluginID: manifest.id, level: "error", message: text)
            self?.failedPlugins[manifest.id] = text
        }

        let bridge = DSHJSBridge(pluginID: manifest.id)
        bridge.runtime = self
        context.setObject(bridge, forKeyedSubscript: "dsh" as NSString)

        // 提供最小 console 兼容层
        let console = JSValue(newObjectIn: context)
        let logBlock: @convention(block) (String) -> Void = { [weak self] message in
            self?.appendLog(pluginID: manifest.id, level: "info", message: message)
        }
        console?.setObject(logBlock, forKeyedSubscript: "log" as NSString)
        console?.setObject(logBlock, forKeyedSubscript: "info" as NSString)
        console?.setObject(logBlock, forKeyedSubscript: "warn" as NSString)
        console?.setObject(logBlock, forKeyedSubscript: "error" as NSString)
        context.setObject(console, forKeyedSubscript: "console" as NSString)

        context.evaluateScript(script)

        if let exception = context.exception {
            let text = exception.toString() ?? "脚本执行失败"
            failedPlugins[manifest.id] = text
            appendLog(pluginID: manifest.id, level: "error", message: text)
            return
        }

        contexts[manifest.id] = context
        if !loadedPluginIDs.contains(manifest.id) {
            loadedPluginIDs.append(manifest.id)
        }
        appendLog(pluginID: manifest.id, level: "info", message: "插件已激活 \(manifest.name) v\(manifest.version)")
    }

    func unload(pluginID: String) {
        contexts.removeValue(forKey: pluginID)
        loadedPluginIDs.removeAll { $0 == pluginID }
        failedPlugins.removeValue(forKey: pluginID)
        commands.removeAll { $0.pluginID == pluginID }
        commandHandlers = commandHandlers.filter { !$0.key.hasPrefix("\(pluginID)::") }
        messageHooks.removeValue(forKey: pluginID)
        messageHookOrder.removeAll { $0 == pluginID }
    }

    func unloadAll() {
        for id in loadedPluginIDs { unload(pluginID: id) }
        commands.removeAll()
        commandHandlers.removeAll()
        messageHooks.removeAll()
        messageHookOrder.removeAll()
        contexts.removeAll()
        loadedPluginIDs.removeAll()
        failedPlugins.removeAll()
    }

    // MARK: - 注册（由桥接回调）

    func registerCommand(pluginID: String, name: String, summary: String, handler: JSValue) {
        let sanitized = name.trimmingCharacters(in: .whitespaces)
        guard !sanitized.isEmpty else { return }
        let key = "\(pluginID)::\(sanitized)"
        commandHandlers[key] = handler
        commands.removeAll { $0.pluginID == pluginID && $0.name == sanitized }
        commands.append(PluginCommand(pluginID: pluginID, name: sanitized, summary: summary))
    }

    func registerMessageHook(pluginID: String, handler: JSValue) {
        var hooks = messageHooks[pluginID] ?? []
        hooks.append(handler)
        messageHooks[pluginID] = hooks
        if !messageHookOrder.contains(pluginID) {
            messageHookOrder.append(pluginID)
        }
    }

    func appendLog(pluginID: String, level: String, message: String) {
        logs.append(PluginLogEntry(pluginID: pluginID, level: level, message: message, timestamp: Date()))
        if logs.count > maxLogEntries {
            logs.removeFirst(logs.count - maxLogEntries)
        }
    }

    func setStorage(pluginID: String, key: String, value: String) {
        storage["\(pluginID)::\(key)"] = value
    }

    func getStorage(pluginID: String, key: String) -> String {
        storage["\(pluginID)::\(key)"] ?? ""
    }

    /// 读取宿主设置（非插件私有存储）
    func getSetting(key: String) -> String {
        settingProvider?(key) ?? ""
    }

    // MARK: - 执行

    /// 执行插件命令
    func runCommand(name: String, argument: String) -> String? {
        guard let command = commands.first(where: { $0.name == name }),
              let handler = commandHandlers[command.id],
              let context = contexts[command.pluginID] else {
            return nil
        }
        guard let result = handler.call(withArguments: [argument]), !result.isUndefined else {
            return nil
        }
        if let exception = context.exception {
            appendLog(pluginID: command.pluginID, level: "error", message: exception.toString() ?? "")
            context.exception = nil
            return nil
        }
        return result.toString()
    }

    /// 依次应用所有启用插件的消息改写钩子
    func transformOutgoing(_ text: String, role: String) -> String {
        var current = text
        for pluginID in messageHookOrder {
            guard let hooks = messageHooks[pluginID] else { continue }
            for hook in hooks {
                guard let result = hook.call(withArguments: [current, role]),
                      let transformed = result.toString(),
                      !result.isUndefined,
                      !result.isNull else { continue }
                current = transformed
            }
        }
        return current
    }

    var activeCommandSummary: [PluginCommand] {
        commands.sorted { $0.name < $1.name }
    }
}
