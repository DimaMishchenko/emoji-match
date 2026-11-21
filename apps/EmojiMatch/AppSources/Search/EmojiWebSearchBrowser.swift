import Foundation
import WebKit

@MainActor
final class EmojiWebSearchBrowser {
  private struct Request {
    let id: UUID
    let continuation: CheckedContinuation<(Data, HTTPURLResponse), any Error>
    let delegate: NavigationDelegate
    var navigation: WKNavigation?
    var response: HTTPURLResponse?
    var committed = false
    var timeout: Task<Void, Never>?
  }

  private var request: Request?
  private var gate = EmojiWebSearchBrowserGate()
  private var retainedWebView: WKWebView?
  private let messages = MessageHandler()
  private let profileIdentifier: UUID?
  private var contentRules: WKContentRuleList?
  private var preparation: Task<Void, Never>?

  init(
    profileIdentifier: UUID? = UUID(
      uuid: (
        0xEC, 0x3F, 0x80, 0x2C, 0x48, 0x17, 0x4B, 0xDB,
        0xAD, 0x01, 0x41, 0x13, 0x9A, 0xE4, 0xDD, 0xA0
      ))
  ) {
    self.profileIdentifier = profileIdentifier
    messages.browser = self
  }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    try Task.checkCancellation()
    guard EmojiWebSearchBrowserPolicy.allows(request.url) else {
      throw DuckDuckGoEmojiSearchError.malformedResponse
    }
    if let error = gate.dispatchError(at: Date()) { throw error }
    await prepareContentRules()
    try Task.checkCancellation()
    while gate.spacingDelay(at: .now) > .zero {
      try await Task.sleep(for: gate.spacingDelay(at: .now))
      try Task.checkCancellation()
    }
    if let error = gate.dispatchError(at: Date()) { throw error }
    if let previous = self.request {
      finish(previous.id, with: .failure(CancellationError()))
    }
    let id = UUID()
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        let delegate = NavigationDelegate(browser: self, id: id)
        self.request = Request(id: id, continuation: continuation, delegate: delegate)
        gate.begin(id)
        let browser = webView
        browser.configuration.userContentController.removeAllUserScripts()
        browser.configuration.userContentController.addUserScript(
          WKUserScript(
            source: Self.script(nonce: id), injectionTime: .atDocumentStart,
            forMainFrameOnly: true, in: .world(name: "EmojiMatchSearch")))
        browser.navigationDelegate = delegate
        self.request?.navigation = browser.load(request)
        guard self.request?.navigation != nil else {
          finish(id, with: .failure(DuckDuckGoEmojiSearchError.transportFailure))
          return
        }
        self.request?.timeout = Task { [weak self] in
          do { try await Task.sleep(for: .seconds(10)) } catch { return }
          self?.finish(id, with: .failure(EmojiSearchIssue(.timedOut)))
        }
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        self?.finish(id, with: .failure(CancellationError()))
      }
    }
  }

  private func prepareContentRules() async {
    if let preparation {
      await preparation.value
      return
    }
    let preparation = Task { @MainActor [weak self] in
      let rules =
        #"[{"trigger":{"url-filter":".*","resource-type":["image","media","font"]},"action":{"type":"block"}}]"#
      self?.contentRules = try? await WKContentRuleListStore.default()
        .compileContentRuleList(
          forIdentifier: "EmojiMatchSearchMedia-v1", encodedContentRuleList: rules)
    }
    self.preparation = preparation
    await preparation.value
  }

  private var webView: WKWebView {
    if let retainedWebView { return retainedWebView }
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore =
      profileIdentifier.map { WKWebsiteDataStore(forIdentifier: $0) }
      ?? .nonPersistent()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = false
    if let contentRules { configuration.userContentController.add(contentRules) }
    configuration.userContentController.add(
      messages, contentWorld: .world(name: "EmojiMatchSearch"), name: "searchDOM")
    let browser = WKWebView(frame: .zero, configuration: configuration)
    retainedWebView = browser
    return browser
  }

  private func finish(_ id: UUID, with result: Result<(Data, HTTPURLResponse), any Error>) {
    guard gate.end(id), let pending = request, pending.id == id else { return }
    request = nil
    pending.timeout?.cancel()
    retainedWebView?.stopLoading()
    pending.continuation.resume(with: result)
  }

  private func receive(_ message: WKScriptMessage) {
    guard message.frameInfo.isMainFrame,
      EmojiWebSearchBrowserPolicy.allows(message.frameInfo.request.url),
      let body = message.body as? [String: Any],
      let nonce = body["nonce"] as? String, let id = UUID(uuidString: nonce),
      gate.accepts(id), request?.committed == true
    else { return }
    do {
      let content = try EmojiWebSearchBrowserPolicy.decode(body)
      if content.challenge {
        gate.pause(error: .challenge, response: request?.response, at: Date())
        finish(id, with: .failure(gate.dispatchError(at: Date()) ?? EmojiSearchIssue(.challenge)))
        return
      }
      guard let response = request?.response else {
        throw DuckDuckGoEmojiSearchError.malformedResponse
      }
      finish(id, with: .success((content.data, response)))
    } catch {
      finish(id, with: .failure(error))
    }
  }

  private func response(_ response: WKNavigationResponse, id: UUID) -> WKNavigationResponsePolicy {
    guard gate.accepts(id) else { return .cancel }
    guard response.isForMainFrame else { return .cancel }
    guard let http = response.response as? HTTPURLResponse,
      EmojiWebSearchBrowserPolicy.allows(http.url)
    else {
      finish(id, with: .failure(DuckDuckGoEmojiSearchError.malformedResponse))
      return .cancel
    }
    request?.response = http
    let error: DuckDuckGoEmojiSearchError?
    switch http.statusCode {
    case 200: error = nil
    case 202: error = .challenge
    default: error = .httpStatus(http.statusCode)
    }
    if let error {
      if [202, 403, 429].contains(http.statusCode) {
        gate.pause(error: error, response: http, at: Date())
      }
      finish(
        id,
        with: .failure(
          gate.dispatchError(at: Date())
            ?? EmojiSearchIssue.from(
              error, fallbackMessage: "Web search is unavailable.")))
      return .cancel
    }
    return .allow
  }

  private static func script(nonce: UUID) -> String {
    """
    (() => {
      const nonce = '\(nonce.uuidString)';
      let sent = false;
      let observer;
      function publish() {
        if (sent) return;
        const challenge = !!document.querySelector(
          'form#challenge-form, form#anomaly-form, form[action*="anomaly.js"], .anomaly-modal, [role="dialog"] form[action*="challenge"]');
        if (!challenge && document.readyState === 'loading') return;
        const rows = Array.from(document.querySelectorAll('#links .result, .results .result'))
          .filter(row => !row.matches('.result--ad, .result--no-result') &&
            !row.querySelector('.result__badge, .result__ad') && row.querySelector('a.result__a'))
          .slice(0, 10);
        const empty = document.querySelector('.no-results, .result--no-result');
        if (!challenge && !rows.length && !empty && document.readyState !== 'complete') return;
        const root = document.createElement('html');
        const body = document.createElement('body');
        root.appendChild(body);
        const links = document.createElement('div');
        links.id = 'links'; links.className = 'results'; body.appendChild(links);
        for (const row of rows) links.appendChild(row.cloneNode(true));
        if (empty) links.appendChild(empty.cloneNode(true));
        for (const excluded of root.querySelectorAll('script, style, iframe, object')) excluded.remove();
        const html = root.outerHTML;
        const oversized = new TextEncoder().encode(html).length > 1048576;
        sent = true;
        if (observer) observer.disconnect();
        window.webkit.messageHandlers.searchDOM.postMessage({nonce, challenge, oversized,
          html: oversized ? '' : html});
      }
      observer = new MutationObserver(publish);
      observer.observe(document, {subtree: true, childList: true, attributes: true});
      document.addEventListener('DOMContentLoaded', publish, {once: true});
      document.addEventListener('readystatechange', publish);
      publish();
    })();
    """
  }

  private final class MessageHandler: NSObject, WKScriptMessageHandler {
    weak var browser: EmojiWebSearchBrowser?

    func userContentController(
      _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
    ) {
      browser?.receive(message)
    }
  }

  private final class NavigationDelegate: NSObject, WKNavigationDelegate {
    weak var browser: EmojiWebSearchBrowser?
    let id: UUID

    init(browser: EmojiWebSearchBrowser, id: UUID) {
      self.browser = browser
      self.id = id
    }

    func webView(
      _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
      guard let browser, browser.gate.accepts(id) else {
        decisionHandler(.cancel)
        return
      }
      guard navigationAction.targetFrame?.isMainFrame == true,
        navigationAction.navigationType == .other,
        EmojiWebSearchBrowserPolicy.allows(navigationAction.request.url)
      else {
        decisionHandler(.cancel)
        return
      }
      decisionHandler(.allow)
    }

    func webView(
      _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
      decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
      decisionHandler(browser?.response(navigationResponse, id: id) ?? .cancel)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
      guard let browser, browser.gate.accepts(id), let navigation,
        browser.request?.navigation === navigation
      else { return }
      browser.request?.committed = true
    }

    func webView(
      _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error
    ) {
      fail(navigation, error: error)
    }

    func webView(
      _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
      withError error: any Error
    ) {
      fail(navigation, error: error)
    }

    private func fail(_ navigation: WKNavigation?, error: any Error) {
      guard let browser, let navigation, browser.request?.navigation === navigation else { return }
      let failure: any Error =
        (error as? URLError)?.code == .cancelled
        ? CancellationError()
        : EmojiSearchIssue.from(error, fallbackMessage: "Web search is unavailable.")
      browser.finish(id, with: .failure(failure))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
      browser?.finish(id, with: .failure(DuckDuckGoEmojiSearchError.transportFailure))
    }
  }
}

nonisolated enum EmojiWebSearchBrowserPolicy {
  static let maximumDOMBytes = 1_048_576

  static func allows(_ url: URL?) -> Bool {
    guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return false
    }
    return components.scheme?.lowercased() == "https"
      && components.host?.lowercased() == "html.duckduckgo.com"
      && ["/html", "/html/"].contains(components.path)
      && (components.port == nil || components.port == 443)
      && components.user == nil && components.password == nil && components.fragment == nil
  }

  static func decode(_ body: [String: Any]) throws -> (data: Data, challenge: Bool) {
    guard let challenge = body["challenge"] as? Bool else {
      throw DuckDuckGoEmojiSearchError.malformedResponse
    }
    if challenge { return (Data(), true) }
    guard let oversized = body["oversized"] as? Bool else {
      throw DuckDuckGoEmojiSearchError.malformedResponse
    }
    if oversized { throw DuckDuckGoEmojiSearchError.responseTooLarge }
    guard let html = body["html"] as? String else {
      throw DuckDuckGoEmojiSearchError.malformedResponse
    }
    let data = Data(html.utf8)
    guard data.count <= maximumDOMBytes else { throw DuckDuckGoEmojiSearchError.responseTooLarge }
    return (data, false)
  }

  static func pauseDuration(response: HTTPURLResponse?, at now: Date) -> TimeInterval {
    max(60, EmojiSearchRetryAfter.deadline(response: response, at: now).timeIntervalSince(now))
  }
}

nonisolated struct EmojiWebSearchBrowserGate {
  private var active: UUID?
  private var pauseUntil: Date?
  private var pauseError: EmojiSearchIssue?
  private var lastDispatch: ContinuousClock.Instant?

  mutating func begin(_ id: UUID, at instant: ContinuousClock.Instant = .now) {
    active = id
    lastDispatch = instant
  }

  func spacingDelay(at instant: ContinuousClock.Instant) -> Duration {
    guard let lastDispatch else { return .zero }
    return max(.zero, .seconds(1) - lastDispatch.duration(to: instant))
  }

  func accepts(_ id: UUID) -> Bool { active == id }

  mutating func end(_ id: UUID) -> Bool {
    guard accepts(id) else { return false }
    active = nil
    return true
  }

  mutating func pause(
    error: DuckDuckGoEmojiSearchError, response: HTTPURLResponse?, at now: Date
  ) {
    pauseUntil = now.addingTimeInterval(
      EmojiWebSearchBrowserPolicy.pauseDuration(response: response, at: now))
    let kind: EmojiSearchIssue.Kind
    switch error {
    case .httpStatus(429): kind = .rateLimited
    default: kind = .challenge
    }
    pauseError = EmojiSearchIssue(kind, retryAt: pauseUntil)
  }

  func dispatchError(at now: Date) -> EmojiSearchIssue? {
    guard let pauseUntil, now < pauseUntil else { return nil }
    return pauseError
  }
}
