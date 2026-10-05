import SwiftUI
import WebKit

/// 请求打开内置浏览器（由 ChatEngine 发布，RootView 负责弹出）
struct BrowserRequest: Identifiable, Equatable {
    let id = UUID()
    let url: URL
}

/// 内置浏览器：地址栏 + 前进/后退/刷新 + 分享。
struct BrowserView: View {
    let initialURL: URL

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = BrowserWebModel()
    @State private var address = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                addressBar
                Divider()
                WebViewContainer(webView: model.webView)
                    .overlay(alignment: .top) {
                        if model.isLoading {
                            ProgressView()
                                .progressViewStyle(.linear)
                        }
                    }
                    .overlay {
                        if model.failureText != nil {
                            errorHint
                        }
                    }
            }
            .navigationTitle(model.pageTitle.isEmpty ? "内置浏览器" : model.pageTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                        .accessibilityIdentifier("browser.done")
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { model.goBack() } label: { Image(systemName: "chevron.backward") }
                        .disabled(!model.canGoBack)
                        .accessibilityLabel("后退")
                    Button { model.goForward() } label: { Image(systemName: "chevron.forward") }
                        .disabled(!model.canGoForward)
                        .accessibilityLabel("前进")
                    Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("刷新")
                    Spacer()
                    ShareLink(item: model.currentURL ?? initialURL) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("分享")
                }
            }
        }
        .onAppear {
            address = initialURL.absoluteString
            model.load(initialURL)
        }
        .onChange(of: model.currentURL) { url in
            guard let url else { return }
            address = url.absoluteString
        }
        .accessibilityIdentifier("browser.sheet")
    }

    private var addressBar: some View {
        HStack(spacing: DSHTheme.Spacing.small) {
            Image(systemName: "globe")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            TextField("输入网址", text: $address)
                .font(.system(size: 14))
                .textFieldStyle(.plain)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit { open(address) }
                .accessibilityIdentifier("browser.address")

            Button {
                open(address)
            } label: {
                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(DSHTheme.brand)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("访问")
        }
        .padding(.horizontal, DSHTheme.Spacing.medium)
        .padding(.vertical, 10)
        .background(DSHTheme.grouped)
    }

    private var errorHint: some View {
        VStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            Text(model.failureText ?? "")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(DSHTheme.Spacing.large)
        .background(DSHTheme.page)
        .clipShape(RoundedRectangle(cornerRadius: DSHTheme.Radius.card, style: .continuous))
    }

    private func open(_ raw: String) {
        guard let url = WebAddress.normalize(raw) else { return }
        address = url.absoluteString
        model.load(url)
    }
}

/// 网址归一化：补全协议、拒绝非法输入
enum WebAddress {
    static func normalize(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil {
            return url
        }
        return URL(string: "https://" + trimmed)
    }
}

// MARK: - 模型

final class BrowserWebModel: NSObject, ObservableObject, WKNavigationDelegate {

    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false
    @Published private(set) var currentURL: URL?
    @Published private(set) var pageTitle = ""
    @Published private(set) var failureText: String?

    let webView: WKWebView

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
    }

    func load(_ url: URL) {
        failureText = nil
        webView.load(URLRequest(url: url))
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        failureText = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        sync(webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        sync(webView)
        failureText = error.localizedDescription
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        sync(webView)
        failureText = error.localizedDescription
    }

    private func sync(_ webView: WKWebView) {
        isLoading = false
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        currentURL = webView.url
        pageTitle = webView.title ?? ""
    }
}

struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// MARK: - 网页正文读取（供智能体工具使用）

enum WebReadError: LocalizedError {
    case invalidURL
    case timeout
    case loadFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "网址无效。"
        case .timeout: return "读取网页超时。"
        case .loadFailed(let detail): return "读取网页失败：\(detail)"
        }
    }
}

/// 使用隐藏的 WKWebView 打开网页并提取正文文本。
@MainActor
final class WebPageReader: NSObject, WKNavigationDelegate {

    static let shared = WebPageReader()

    /// 传给模型的正文上限
    static let maxCharacters = 12_000

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<String, Error>?
    private var timeoutTask: Task<Void, Never>?

    func read(url: URL, timeout: Double = 25) async throws -> String {
        // 同一时间只保留一次读取
        finish(.failure(WebReadError.timeout))
        let webView = self.webView ?? makeWebView()
        self.webView = webView
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.finish(.failure(WebReadError.timeout))
            }
            webView.load(URLRequest(url: url))
        }
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844),
            configuration: configuration
        )
        webView.navigationDelegate = self
        return webView
    }

    private func finish(_ result: Result<String, Error>) {
        timeoutTask?.cancel()
        timeoutTask = nil
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("document.body ? document.body.innerText : ''") { [weak self] value, error in
            guard let self else { return }
            if let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let condensed = text
                    .replacingOccurrences(of: "\n\n\n", with: "\n\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                self.finish(.success(Self.truncate(condensed)))
            } else if let error {
                self.finish(.failure(WebReadError.loadFailed(error.localizedDescription)))
            } else {
                self.finish(.success("(页面没有可读取的正文)"))
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(WebReadError.loadFailed(error.localizedDescription)))
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        finish(.failure(WebReadError.loadFailed(error.localizedDescription)))
    }

    private static func truncate(_ text: String) -> String {
        guard text.count > maxCharacters else { return text }
        return String(text.prefix(maxCharacters)) + "\n…（正文过长，已截断）"
    }
}