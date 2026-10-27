import UIKit
import WebKit

/// Shows one 서재 book (a page of the Mac server) full screen. The app's toolbar drives the page's ink through DocumentSession,
/// and Apple Pencil double-tap and squeeze (never delivered to web content) go to the app like in screen mode.
final class WebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, UIPencilInteractionDelegate, UIGestureRecognizerDelegate {
    private let webView: WKWebView
    private(set) var startURL: URL
    var onChangeServer: () -> Void = {}
    /// Returns to the library shelf; offered in the menu and on the error screen.
    var onLeave: (() -> Void)?
    var onPencil: ((UIPencilPreferredAction, CGPoint?, UIView?) -> Void)?
    weak var session: DocumentSession?

    private let errorView = UIStackView()
    private let errorLabel = UILabel()
    private var leaveButton: UIButton?

    init(startURL: URL) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        // Lets the pages know they run inside the app (no "add to home screen" hint, Pencil gestures available).
        config.applicationNameForUserAgent = "PencilReviewApp/1"
        let messages = MessageRelay()
        config.userContentController.add(messages, name: "pencilReview")
        webView = WKWebView(frame: .zero, configuration: config)
        self.startURL = startURL
        super.init(nibName: nil, bundle: nil)
        messages.owner = self
    }

    func run(_ script: String) {
        webView.evaluateJavaScript(script)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        #if DEBUG
        webView.isInspectable = true
        #endif

        view.addInteraction(UIPencilInteraction(delegate: self))

        // Three fingers held down open the app menu (reload, server address, back to the shelf).
        let menuGesture = UILongPressGestureRecognizer(target: self, action: #selector(showMenu(_:)))
        menuGesture.numberOfTouchesRequired = 3
        menuGesture.minimumPressDuration = 0.8
        menuGesture.cancelsTouchesInView = false
        menuGesture.delegate = self
        view.addGestureRecognizer(menuGesture)

        buildErrorView()
        load(startURL)
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    func load(_ url: URL) {
        startURL = url
        errorView.isHidden = true
        webView.load(URLRequest(url: url))
    }

    // MARK: Apple Pencil

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        onPencil?(UIPencilInteraction.preferredTapAction, tap.hoverPose?.location, interaction.view)
    }

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard squeeze.phase == .ended else { return }
        onPencil?(UIPencilInteraction.preferredSqueezeAction, squeeze.hoverPose?.location, interaction.view)
    }

    // MARK: Navigation

    private func isServer(_ url: URL) -> Bool {
        url.scheme == startURL.scheme && url.host == startURL.host && url.port == startURL.port
    }

    /// Schemes a tapped link may hand to another app; anything else is dropped.
    private static let external: Set<String> = ["http", "https", "mailto", "tel"]

    private func openOutside(_ url: URL) {
        if Self.external.contains(url.scheme?.lowercased() ?? "") { UIApplication.shared.open(url) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        // The page itself never leaves the Mac server: a tapped outside link opens in its own app, and
        // scripted redirects elsewhere are dropped. Frames inside the page load as they like.
        guard let url = action.request.url, action.targetFrame?.isMainFrame != false, !isServer(url) else {
            decisionHandler(.allow)
            return
        }
        if action.navigationType == .linkActivated { openOutside(url) }
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url {
            if isServer(url) { webView.load(action.request) } else if action.navigationType == .linkActivated { openOutside(url) }
        }
        return nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showError(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showError(error)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        errorView.isHidden = true
        session?.push()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    // The overlay asks before deleting notes; WKWebView shows nothing for confirm() unless the app does.
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "취소", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "확인", style: .destructive) { _ in completionHandler(true) })
        present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "확인", style: .default) { _ in completionHandler() })
        present(alert, animated: true)
    }

    // MARK: Error screen and menu

    private func buildErrorView() {
        errorView.axis = .vertical
        errorView.alignment = .center
        errorView.spacing = 16
        errorView.isHidden = true
        errorView.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.numberOfLines = 0
        errorLabel.textAlignment = .center
        errorLabel.font = .preferredFont(forTextStyle: .body)
        let retry = UIButton(configuration: .borderedProminent(), primaryAction: UIAction(title: "다시 시도") { [weak self] _ in
            guard let self else { return }
            self.load(self.startURL)
        })
        let change = UIButton(configuration: .bordered(), primaryAction: UIAction(title: "서버 주소 바꾸기") { [weak self] _ in
            self?.onChangeServer()
        })
        let leave = UIButton(configuration: .borderless(), primaryAction: UIAction(title: "서재로") { [weak self] _ in
            self?.onLeave?()
        })
        errorView.addArrangedSubview(errorLabel)
        errorView.addArrangedSubview(retry)
        errorView.addArrangedSubview(change)
        errorView.addArrangedSubview(leave)
        leaveButton = leave
        view.addSubview(errorView)
        NSLayoutConstraint.activate([
            errorView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            errorView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            errorView.widthAnchor.constraint(lessThanOrEqualToConstant: 480),
        ])
    }

    private func showError(_ error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        leaveButton?.isHidden = onLeave == nil
        errorLabel.text = "맥 서버에 연결할 수 없습니다.\n맥에서 서버가 켜져 있고 같은 Wi-Fi인지 확인해 주세요.\n\n\(startURL.host ?? "")"
        errorView.isHidden = false
        view.bringSubviewToFront(errorView)
    }

    @objc private func showMenu(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        let sheet = UIAlertController(title: "서재", message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "새로고침", style: .default) { [weak self] _ in self?.webView.reload() })
        sheet.addAction(UIAlertAction(title: "서버 주소 바꾸기", style: .default) { [weak self] _ in self?.onChangeServer() })
        if let onLeave {
            sheet.addAction(UIAlertAction(title: "서재로", style: .default) { _ in onLeave() })
        }
        sheet.addAction(UIAlertAction(title: "취소", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(origin: gesture.location(in: view), size: .zero)
        }
        present(sheet, animated: true)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

/// Receives the page's messages without the content controller keeping the view controller alive.
private final class MessageRelay: NSObject, WKScriptMessageHandler {
    weak var owner: WebViewController?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        owner?.session?.receive(body)
    }
}
