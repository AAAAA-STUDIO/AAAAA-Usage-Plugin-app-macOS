import AppKit
import Foundation
import WebKit

@MainActor
@main
final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    private let provider = UsageProvider()
    private let oauth = DeepSeekOAuth()
    private let availableTools = ToolAvailability.detect()
    private var window: NSWindow!
    private var webView: WKWebView!
    private var hud: HUDController!
    private var refreshTimer: Timer?
    private var refreshInFlight = false
    private var pageReady = false
    private var latestSnapshot: [String: Any] = [:]
    private let usageAlertThresholdKey = "usage.alertThresholdPercent"
    private let defaultUsageAlertThresholdPercent = 20
    private let deepSeekBalanceAlertThresholdKey = "usage.deepSeekBalanceAlertThreshold"
    private let deepSeekBalanceAlertCurrencyKey = "usage.deepSeekBalanceAlertCurrency"
    private let defaultDeepSeekBalanceAlertThreshold = 10.0

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()
        let contentController = WKUserContentController()
        contentController.add(self, name: "aaaaa")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = contentController
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 790),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "用量监控"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 880, height: 620)
        window.backgroundColor = NSColor(calibratedRed: 0.055, green: 0.065, blue: 0.085, alpha: 1)
        window.center()
        window.contentView = webView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        hud = HUDController()
        hud.setUsageAlertThreshold(usageAlertThresholdPercent)
        hud.setDeepSeekBalanceAlert(
            threshold: deepSeekBalanceAlertThreshold,
            currency: deepSeekBalanceAlertCurrency
        )
        hud.onStateChange = { [weak self] in
            self?.pushHUDState()
        }
        hud.onOpenMainApp = { [weak self] in
            guard let self else { return }
            self.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        hud.setToolAvailability(availableTools)
        let page = Bundle.main.resourceURL!.appendingPathComponent("Resources/index.html")
        webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { window.makeKeyAndOrderFront(nil) }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let action = body["action"] as? String else { return }
        switch action {
        case "refresh":
            refresh()
        case "loginDeepSeek":
            startDeepSeekLogin()
        case "logoutDeepSeek":
            startDeepSeekLogout()
        case "toggleHUD":
            hud.setEnabled((body["enabled"] as? Bool) ?? false)
            pushHUDState()
        case "setUsageAlertThreshold":
            guard let number = body["value"] as? NSNumber else { return }
            let threshold = min(100, max(0, number.intValue))
            UserDefaults.standard.set(threshold, forKey: usageAlertThresholdKey)
            hud.setUsageAlertThreshold(threshold)
            pushHUDState()
        case "setDeepSeekBalanceAlert":
            guard let number = body["threshold"] as? NSNumber else { return }
            let threshold = max(0, number.doubleValue)
            let currency = (body["currency"] as? String) == "USD" ? "USD" : "CNY"
            UserDefaults.standard.set(threshold, forKey: deepSeekBalanceAlertThresholdKey)
            UserDefaults.standard.set(currency, forKey: deepSeekBalanceAlertCurrencyKey)
            hud.setDeepSeekBalanceAlert(threshold: threshold, currency: currency)
            pushHUDState()
        case "openUsage":
            NSWorkspace.shared.open(URL(string: "https://platform.deepseek.com/usage")!)
        case "openTopUp":
            NSWorkspace.shared.open(URL(string: "https://platform.deepseek.com/top_up")!)
        default:
            break
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageReady = true
        pushToolAvailability()
        pushHUDState()
        if !latestSnapshot.isEmpty { sendSnapshot(latestSnapshot) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        if url.isFileURL {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            if url.scheme == "https" { NSWorkspace.shared.open(url) }
        }
    }

    private func refresh() {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        Task {
            let snapshot = await provider.snapshot(availableTools: availableTools)
            latestSnapshot = snapshot
            hud.render(snapshot)
            sendSnapshot(snapshot)
            refreshInFlight = false
        }
    }

    private func startDeepSeekLogin() {
        setNotice("正在打开 DeepSeek 官方浏览器授权…", isError: false)
        Task {
            do {
                try await oauth.signIn()
                setNotice("DeepSeek 官方账户已连接。", isError: false)
                refresh()
            } catch {
                setNotice(error.localizedDescription, isError: true)
            }
        }
    }

    private func startDeepSeekLogout() {
        Task {
            await oauth.signOut()
            setNotice("DeepSeek 账户已从本机退出。", isError: false)
            refresh()
        }
    }

    private func sendSnapshot(_ snapshot: [String: Any]) {
        guard pageReady,
              let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.fragmentsAllowed]),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.AAAAAUsage && window.AAAAAUsage.render(\(json));")
    }

    private func setNotice(_ text: String, isError: Bool) {
        guard pageReady,
              let data = try? JSONSerialization.data(withJSONObject: ["text": text, "isError": isError]),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.AAAAAUsage && window.AAAAAUsage.notice(\(json));")
    }

    private func pushHUDState() {
        guard pageReady else { return }
        webView.evaluateJavaScript("window.AAAAAUsage && window.AAAAAUsage.setUsageAlertThreshold(\(usageAlertThresholdPercent)); window.AAAAAUsage && window.AAAAAUsage.setDeepSeekBalanceAlert(\(deepSeekBalanceAlertThreshold), '\(deepSeekBalanceAlertCurrency)'); window.AAAAAUsage && window.AAAAAUsage.setHUDEnabled(\(hud.isEnabled()), \(hud.isVisible()));")
    }

    private func pushToolAvailability() {
        guard pageReady,
              let data = try? JSONSerialization.data(withJSONObject: availableTools.dictionary),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.AAAAAUsage && window.AAAAAUsage.setToolAvailability(\(json));")
    }

    private var usageAlertThresholdPercent: Int {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: usageAlertThresholdKey) != nil else {
            return defaultUsageAlertThresholdPercent
        }
        return min(100, max(0, defaults.integer(forKey: usageAlertThresholdKey)))
    }

    private var deepSeekBalanceAlertThreshold: Double {
        let defaults = UserDefaults.standard
        guard let value = defaults.object(forKey: deepSeekBalanceAlertThresholdKey) as? NSNumber else {
            return defaultDeepSeekBalanceAlertThreshold
        }
        return max(0, value.doubleValue)
    }

    private var deepSeekBalanceAlertCurrency: String {
        UserDefaults.standard.string(forKey: deepSeekBalanceAlertCurrencyKey) == "USD" ? "USD" : "CNY"
    }

    private func installMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let hide = NSMenuItem(title: "隐藏用量监控", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hide.target = NSApp
        let quit = NSMenuItem(title: "退出用量监控", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        appMenu.addItem(hide)
        appMenu.addItem(.separator())
        appMenu.addItem(quit)
        appItem.submenu = appMenu
        menu.addItem(appItem)
        NSApp.mainMenu = menu
    }
}
