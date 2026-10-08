import UIKit
import Vision
import WebKit

/// 屏幕视觉：截取当前界面或内置浏览器页面，并用本地 OCR 识别其中的文字。
/// 智能体通过「查看画面」工具调用它——视觉模型可以直接看到附带截图，
/// 纯文本模型也能靠 OCR 文本了解画面内容。
enum ScreenVision {

    /// 要查看的位置
    enum Target: String {
        /// App 当前界面
        case screen
        /// 内置浏览器当前页面
        case browser
    }

    /// 返回给模型的 OCR 文本上限（过长会截断，避免占满上下文）
    static let maxTextLength = 4_000

    // MARK: - 截图

    /// 截取 App 当前界面（与用户屏幕上看到的一致）
    @MainActor
    static func captureAppScreen() -> UIImage? {
        guard let window = keyWindow else { return nil }
        let bounds = window.bounds
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        let renderer = UIGraphicsImageRenderer(bounds: bounds)
        return renderer.image { _ in
            window.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
    }

    /// 截取内置浏览器当前页面；浏览器没打开或页面还没就绪时返回 nil
    @MainActor
    static func captureBrowser() async -> (image: UIImage, url: URL?)? {
        guard let webView = BrowserRegistry.activeWebView else { return nil }
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        let snapshot: UIImage? = await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: configuration) { image, _ in
                continuation.resume(returning: image)
            }
        }
        guard let snapshot else { return nil }
        return (snapshot, webView.url)
    }

    // MARK: - OCR

    /// 本地文字识别（中英文），失败或没有文字时返回空串
    static func recognizeText(in image: UIImage) async -> String {
        guard let cgImage = image.cgImage else { return "" }
        return await withCheckedContinuation { continuation in
            // 用一次性标记包住回调：识别失败与完成可能都走到，重复 resume 会崩溃
            let once = ResumeOnce(continuation)
            let request = VNRecognizeTextRequest { request, _ in
                let lines = (request.results as? [VNRecognizedTextObservation] ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                once.finish(with: lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["zh-Hans", "en-US"]

            DispatchQueue.global(qos: .userInitiated).async {
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    once.finish(with: "")
                }
            }
        }
    }

    /// 超长识别结果截断（附一句说明，便于模型知道内容不完整）
    static func truncated(_ text: String) -> String {
        guard text.count > maxTextLength else { return text }
        return String(text.prefix(maxTextLength)) + "\n…（识别内容过长，已截断）"
    }

    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
    }
}

/// 保证 continuation 只 resume 一次
private final class ResumeOnce {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Never>?

    init(_ continuation: CheckedContinuation<String, Never>) {
        self.continuation = continuation
    }

    func finish(with value: String) {
        lock.lock()
        let target = continuation
        continuation = nil
        lock.unlock()
        target?.resume(returning: value)
    }
}