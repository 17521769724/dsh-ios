import Foundation
import EventKit
import UIKit

/// 与本 App 权限相关的存储键（首次启动引导用，启动参数也会读写）
enum PermissionKeys {
    /// 「首次启动权限引导」是否已经展示过
    static let primerShown = "permissions.primer.shown"
}

/// 权限中心：集中查询与申请本 App 需要的系统权限，「首次启动引导」与「设置 → 权限状态」共用。
///
/// - 提醒事项 / 日历：EventKit 有正式授权接口，可查询状态、可发起申请；
/// - 剪贴板：iOS 没有「剪贴板权限」这一项，首次读取时系统会弹「允许粘贴」，这里提供一次「测试」入口；
/// - 本地网络：首次访问局域网设备（SSH、本地 MCP 服务器）时由系统询问，系统没有提供查询接口；
/// - 网络访问 / 照片 / 文件：iOS 不需要授权，或使用的是系统自带选择器，状态显示为「无需授权」。
@MainActor
final class PermissionCenter: ObservableObject {

    enum Status: Equatable {
        /// 已授权
        case granted
        /// 被拒绝（可去系统设置里开启）
        case denied
        /// 还没申请过
        case notDetermined
        /// 使用时由系统询问（没有可查询的状态）
        case systemPrompt
        /// 不需要授权
        case notRequired

        var title: String {
            switch self {
            case .granted: return "已授权"
            case .denied: return "未授权"
            case .notDetermined: return "未申请"
            case .systemPrompt: return "使用时询问"
            case .notRequired: return "无需授权"
            }
        }

        /// 是否已经不需要再处理
        var isSatisfied: Bool {
            switch self {
            case .granted, .notRequired, .systemPrompt: return true
            case .denied, .notDetermined: return false
            }
        }
    }

    struct Item: Identifiable {
        let id: String
        let title: String
        let detail: String
        let symbol: String
        let status: Status
        /// 可以主动申请（弹系统授权框，或触发一次系统询问）；nil 表示只能去系统设置里改
        let request: (() async -> String?)?

        var canRequest: Bool { request != nil }
    }

    /// 状态刷新信号：申请完成后自增，驱动界面重新计算
    @Published private(set) var revision = 0

    private let store = EKEventStore()
    private let defaults = UserDefaults.standard

    /// 首次启动的权限引导是否已经展示过
    var hasPrimed: Bool {
        get { defaults.bool(forKey: PermissionKeys.primerShown) }
        set { defaults.set(newValue, forKey: PermissionKeys.primerShown) }
    }

    /// UI 测试时（`-uitest-skip-permission-request`）只展示状态、不自动弹系统授权框，
    /// 否则系统弹窗会挡住后续用例。
    static var shouldAutoRequest: Bool {
        !ProcessInfo.processInfo.arguments.contains("-uitest-skip-permission-request")
    }

    // MARK: - 权限清单

    var items: [Item] {
        _ = revision // 读一次，保证申请完成后界面会重新计算
        return [
            Item(
                id: "reminders",
                title: "提醒事项",
                detail: "智能体查看与新建待办，例如「明天九点提醒我交周报」",
                symbol: "checklist",
                status: reminderStatus(),
                request: { await self.requestReminders() }
            ),
            Item(
                id: "calendar",
                title: "日历",
                detail: "智能体查看与新建日程，例如「周五下午三点加一个评审会」",
                symbol: "calendar",
                status: calendarStatus(),
                request: { await self.requestCalendar() }
            ),
            Item(
                id: "clipboard",
                title: "剪贴板",
                detail: "智能体读写复制内容；首次读取时系统会弹「允许粘贴」，需要点允许",
                symbol: "doc.on.clipboard",
                status: .systemPrompt,
                request: { await self.probeClipboard() }
            ),
            Item(
                id: "localNetwork",
                title: "本地网络",
                detail: "连接局域网里的 SSH 服务器或本地 MCP 服务时由系统询问",
                symbol: "wifi",
                status: .systemPrompt,
                request: nil
            ),
            Item(
                id: "internet",
                title: "网络访问",
                detail: "访问 DeepSeek 接口、GitHub 等公网服务，iOS 不需要单独授权",
                symbol: "globe",
                status: .notRequired,
                request: nil
            ),
            Item(
                id: "photos",
                title: "照片",
                detail: "发图走系统相册选择器，只拿到你选中的图片，不读取整库",
                symbol: "photo",
                status: .notRequired,
                request: nil
            ),
            Item(
                id: "files",
                title: "文件与工作区",
                detail: "内置「文件」页读写 App 自己的工作区目录，不需要授权",
                symbol: "folder",
                status: .notRequired,
                request: nil
            )
        ]
    }

    /// 还没就绪、可以申请的项目数
    var pendingCount: Int {
        items.filter { !$0.status.isSatisfied }.count
    }

    // MARK: - 申请

    /// 一键申请：依次把能主动申请的权限走一遍（提醒事项 → 日历 → 剪贴板）
    func requestAll() async -> String {
        var messages: [String] = []
        for item in items where item.canRequest && !item.status.isSatisfied {
            if let message = await item.request?() {
                messages.append(message)
            }
        }
        revision += 1
        return messages.isEmpty ? "当前没有需要申请的权限。" : messages.joined(separator: "\n")
    }

    func requestReminders() async -> String? {
        let granted: Bool
        if #available(iOS 17.0, *) {
            granted = (try? await store.requestFullAccessToReminders()) ?? false
        } else {
            granted = await withCheckedContinuation { continuation in
                store.requestAccess(to: .reminder) { ok, _ in continuation.resume(returning: ok) }
            }
        }
        revision += 1
        return granted ? "提醒事项：已授权" : "提醒事项：被拒绝，可到系统设置 → 隐私与安全性 → 提醒事项里手动开启"
    }

    func requestCalendar() async -> String? {
        let granted: Bool
        if #available(iOS 17.0, *) {
            granted = (try? await store.requestFullAccessToEvents()) ?? false
        } else {
            granted = await withCheckedContinuation { continuation in
                store.requestAccess(to: .event) { ok, _ in continuation.resume(returning: ok) }
            }
        }
        revision += 1
        return granted ? "日历：已授权" : "日历：被拒绝，可到系统设置 → 隐私与安全性 → 日历里手动开启"
    }

    /// 触发一次剪贴板读取：系统会弹「允许粘贴」，用来在引导里把这一步走完
    func probeClipboard() async -> String? {
        let text = UIPasteboard.general.string
        revision += 1
        if let text, !text.isEmpty {
            return "剪贴板：已允许访问（读到 \(text.count) 个字符）"
        }
        return "剪贴板：已允许访问（当前没有文本内容）"
    }

    /// 跳到「设置 → 本 App」，方便手动开启被拒绝的权限
    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - 状态查询

    private func reminderStatus() -> Status {
        status(for: .reminder)
    }

    private func calendarStatus() -> Status {
        status(for: .event)
    }

    private func status(for entity: EKEntityType) -> Status {
        let raw = EKEventStore.authorizationStatus(for: entity)
        if #available(iOS 17.0, *) {
            switch raw {
            case .fullAccess: return .granted
            // 只写权限不够用：智能体需要读取待办与日程，这里按「未授权」处理
            case .writeOnly: return .denied
            case .denied, .restricted: return .denied
            case .notDetermined: return .notDetermined
            @unknown default: return .notDetermined
            }
        }
        switch raw {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }
}