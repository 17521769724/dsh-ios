import Foundation
import Citadel
import NIOCore

/// SSH 执行错误
enum SSHError: LocalizedError {
    case notConfigured
    case noPassword
    case connect(String)
    case execute(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "SSH 未配置：请在「设置 → SSH 云服务器」里填写主机、端口与用户名。"
        case .noPassword:
            return "SSH 缺少密码：请在「设置 → SSH 云服务器」里填写登录密码。"
        case .connect(let detail):
            return "SSH 连接失败：\(detail)"
        case .execute(let detail):
            return "SSH 命令执行失败：\(detail)"
        case .timeout:
            return "SSH 命令超时（超过 40 秒未返回）。"
        }
    }
}

/// 通过 SSH 在云服务器上执行命令（Citadel / NIOSSH，纯 Swift 实现）。
enum SSHService {

    /// 返回给模型的输出上限，超出部分截断，避免撑爆上下文
    static let maxOutputCharacters = 8_000

    static func execute(
        command: String,
        configuration: SSHConfiguration,
        password: String,
        timeout: Double = 40
    ) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await run(command: command, configuration: configuration, password: password)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw SSHError.timeout
            }
            guard let first = try await group.next() else { throw SSHError.timeout }
            group.cancelAll()
            return first
        }
    }

    private static func run(
        command: String,
        configuration: SSHConfiguration,
        password: String
    ) async throws -> String {
        guard configuration.isFilled else { throw SSHError.notConfigured }
        guard !password.isEmpty else { throw SSHError.noPassword }

        let client: SSHClient
        do {
            client = try await SSHClient.connect(
                host: configuration.host.trimmingCharacters(in: .whitespacesAndNewlines),
                port: configuration.port,
                authenticationMethod: .passwordBased(
                    username: configuration.username.trimmingCharacters(in: .whitespacesAndNewlines),
                    password: password
                ),
                hostKeyValidator: .acceptAnything(),
                reconnect: .never
            )
        } catch {
            throw SSHError.connect(Self.describe(error))
        }

        defer {
            Task { try? await client.close() }
        }

        // 把 stderr 合并进 stdout：Citadel 的 executeCommand 在收到 stderr 时会直接报错
        let wrapped = "( \(command) ) 2>&1"
        do {
            let buffer = try await client.executeCommand(wrapped, maxResponseSize: 400_000)
            // 用标准库解码，避免依赖 NIOFoundationCompat
            return truncate(String(decoding: buffer.readableBytesView, as: UTF8.self))
        } catch {
            throw SSHError.execute(Self.describe(error))
        }
    }

    private static func truncate(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "(命令执行完成，没有输出)" }
        guard trimmed.count > maxOutputCharacters else { return trimmed }
        let head = String(trimmed.prefix(maxOutputCharacters))
        return head + "\n…（输出过长，已截断，共 \(trimmed.count) 个字符）"
    }

    private static func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }
}