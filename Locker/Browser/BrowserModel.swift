import AppKit
import WebKit

/// A page that failed to load, as the panel shows it.
struct BrowserFailure: Equatable {
    var message: BrowserErrorText.Message
    /// The address that failed, so Retry works even when nothing was ever loaded.
    var url: String
}

/// One workspace's browser: a live `WKWebView` plus what the toolbar needs. Owned by `BrowserRegistry`, not by
/// SwiftUI, so the page, its scroll position and form input survive switching workspaces.
@MainActor
final class BrowserModel: NSObject, ObservableObject {
    let webView: WKWebView
    /// The address of the page shown (or that failed), for the address bar.
    @Published private(set) var currentURL = ""
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false
    @Published private(set) var failure: BrowserFailure?
    /// Set when what the user typed is not an address.
    @Published var inputError: String?
    /// Called with every http(s) address the page settles on, to remember it.
    var onURLChange: ((String) -> Void)?
    private var observers: [NSKeyValueObservation] = []

    init(initialURL: String?) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()   // cookies and logins are shared by all workspaces
        webView = WKWebView(frame: .zero, configuration: config)
        webView.isInspectable = true
        webView.allowsBackForwardNavigationGestures = true
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observers = [
            webView.observe(\.canGoBack) { [weak self] _, _ in Task { @MainActor in self?.sync() } },
            webView.observe(\.canGoForward) { [weak self] _, _ in Task { @MainActor in self?.sync() } },
            webView.observe(\.isLoading) { [weak self] _, _ in Task { @MainActor in self?.sync() } },
            webView.observe(\.url) { [weak self] _, _ in Task { @MainActor in self?.sync() } },
        ]
        if let initialURL, let url = URLNormalizer.normalize(initialURL) {
            currentURL = url.absoluteString
            webView.load(URLRequest(url: url))
        }
    }

    private func sync() {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        isLoading = webView.isLoading
        if failure == nil, let url = webView.url, Self.isWeb(url) {
            let s = url.absoluteString
            if s != currentURL { currentURL = s; onURLChange?(s) }
        }
    }

    private static func isWeb(_ url: URL) -> Bool { url.scheme == "http" || url.scheme == "https" }

    // MARK: Actions

    /// Loads what the user typed. Returns false (and sets `inputError`) when it is not an address.
    @discardableResult
    func load(_ text: String) -> Bool {
        guard let url = URLNormalizer.normalize(text) else {
            inputError = "Not an address. Try a port like 3000, or localhost:3000."
            return false
        }
        inputError = nil
        failure = nil
        webView.load(URLRequest(url: url))
        return true
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func stop() { webView.stopLoading() }

    /// Reload, or try again after a failure (the failed address may never have loaded, so reload would do nothing).
    func reload() {
        inputError = nil
        if let failure {
            self.failure = nil
            if let url = URL(string: failure.url) { webView.load(URLRequest(url: url)) }
        } else if webView.url != nil {
            webView.reload()
        } else if !currentURL.isEmpty {
            load(currentURL)
        }
    }

    func openInDefaultBrowser() {
        let s = failure?.url ?? currentURL
        if let url = URL(string: s), Self.isWeb(url) { NSWorkspace.shared.open(url) }
    }

    func shutDown() {
        observers.removeAll()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        onURLChange = nil
    }

    // MARK: Failures

    private func fail(_ error: Error) {
        let e = error as NSError
        guard !BrowserErrorText.isIgnorable(domain: e.domain, code: e.code) else { return }
        let failed = (e.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.absoluteString ?? webView.url?.absoluteString ?? currentURL
        let u = URL(string: failed)
        let target = u?.host.map { h in u?.port.map { "\(h):\($0)" } ?? h } ?? failed
        failure = BrowserFailure(
            message: BrowserErrorText.message(domain: e.domain, code: e.code, target: target, fallback: e.localizedDescription),
            url: failed)
        if failed != currentURL { currentURL = failed; if u.map(Self.isWeb) == true { onURLChange?(failed) } }
    }
}

extension BrowserModel: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        switch url.scheme?.lowercased() {
        case "http", "https", "about", "blob", "data": return .allow
        default:
            NSWorkspace.shared.open(url)   // mailto:, custom app schemes…
            return .cancel
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        guard !response.canShowMIMEType, let url = response.response.url else { return .allow }
        NSWorkspace.shared.open(url)   // a download: hand it to the system
        return .cancel
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { failure = nil }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error) }
}

extension BrowserModel: WKUIDelegate {
    /// target=_blank and window.open load in this same panel: there is one page per workspace.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil, let url = action.request.url, Self.isWeb(url) { webView.load(action.request) }
        return nil
    }
}

/// Keeps one live browser per workspace id, created the first time its panel opens.
@MainActor
final class BrowserRegistry {
    private var models: [UUID: BrowserModel] = [:]

    func model(for id: UUID, initialURL: String?, onURLChange: @escaping (String) -> Void) -> BrowserModel {
        if let m = models[id] { return m }
        let m = BrowserModel(initialURL: initialURL)
        m.onURLChange = onURLChange
        models[id] = m
        return m
    }

    /// The browser if it exists, without creating one.
    func existing(_ id: UUID) -> BrowserModel? { models[id] }

    func close(_ id: UUID) {
        models[id]?.shutDown()
        models[id] = nil
    }
}
