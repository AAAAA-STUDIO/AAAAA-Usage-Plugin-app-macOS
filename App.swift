import AppKit
import Foundation
import WebKit

@MainActor
@main
final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    private let provider = UsageProvider()
    private let kimiClient = KimiAccountClient()
    private var detectedTools = ToolAvailability.detect()
    private var enabledTools: [String: Bool] = [
        "codex": UserDefaults.standard.object(forKey: "usage.toolEnabled.codex") as? Bool ?? false,
        "deepseek": UserDefaults.standard.object(forKey: "usage.toolEnabled.deepseek") as? Bool ?? false,
        "kimi": UserDefaults.standard.object(forKey: "usage.toolEnabled.kimi") as? Bool ?? false
    ]
    private var availableTools: ToolAvailability {
        ToolAvailability(
            codex: detectedTools.codex && enabledTools["codex"] == true,
            deepSeek: detectedTools.deepSeek && enabledTools["deepseek"] == true,
            kimi: detectedTools.kimi && enabledTools["kimi"] == true
        )
    }
    private var window: NSWindow!
    private var webView: WKWebView!
    private var hud: HUDController!
    private var menuBarExpandedHUD: HUDController!
    private var menuBarUsage: MenuBarUsageController!
    private var refreshTimer: Timer?
    private var refreshInFlight = false
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = 0
    private var todayTokenRefreshInFlight = false
    private var todayTokenRefreshTask: Task<Void, Never>?
    private var todayTokenRefreshGeneration = 0
    private var pageReady = false
    private let autoRefreshEnabledKey = "usage.autoRefreshEnabled"
    private let menuBarHUDEnabledKey = "usage.menuBarHUDEnabled"
    private let modelHUDVisibilityKeyPrefix = "usage.modelHUDVisibility"
    private var latestSnapshot: [String: Any] = [:]
    private var sessionDetailTasks: [String: (provider: String, task: Task<Void, Never>)] = [:]
    private var kimiRefreshAfterOpenTask: Task<Void, Never>?
    private var kimiAppObservers: [NSObjectProtocol] = []
    private var kimiLastMonthlyReadAt: Date?
    private var latestKimiUsage: [String: Any] = [
        "available": false, "sessionDetected": false, "source": "none",
        "sessions": [], "sessionsReason": "当前 Kimi 本机用量读取路径不提供对话历史",
        "monthly": NSNull(), "fiveHour": NSNull(), "codeFiveHour": NSNull(),
        "codeWeekly": NSNull(),
        "tokens": [
            "available": false, "sessions": 0, "inputTokens": 0,
            "cacheReadTokens": 0, "outputTokens": 0, "totalTokens": 0,
            "reason": "Kimi 会员额度接口不提供 Token 分项统计"
        ],
        "error": "正在读取本机 Kimi 桌面会话。"
    ]
    private var kimiQueryInFlight = false
    private var kimiQueryTask: Task<Void, Never>?
    private var kimiQueryGeneration = 0
    private let usageAlertThresholdKey = "usage.alertThresholdPercent"
    private let defaultUsageAlertThresholdPercent = 20
    private let kimiMonthlyAlertThresholdKey = "usage.kimiMonthlyAlertThresholdPercent"
    private let defaultKimiMonthlyAlertThresholdPercent = 20
    private let deepSeekBalanceAlertThresholdKey = "usage.deepSeekBalanceAlertThreshold"
    private let deepSeekBalanceAlertCurrencyKey = "usage.deepSeekBalanceAlertCurrency"
    private let defaultDeepSeekBalanceAlertThreshold = 10.0

    private static var emptyKimiUsage: [String: Any] {
        [
            "available": false, "sessionDetected": false, "source": "none",
            "sessions": [], "sessionsReason": "当前 Kimi 本机用量读取路径不提供对话历史",
            "monthly": NSNull(), "fiveHour": NSNull(), "codeFiveHour": NSNull(),
            "codeWeekly": NSNull(),
            "tokens": [
                "available": false, "sessions": 0, "inputTokens": 0,
                "cacheReadTokens": 0, "outputTokens": 0, "totalTokens": 0,
                "reason": "Kimi 会员额度接口不提供 Token 分项统计"
            ],
            "error": ""
        ]
    }

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
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 880, height: 620)
        window.backgroundColor = NSColor(calibratedRed: 0.055, green: 0.065, blue: 0.085, alpha: 1)
        window.center()
        window.contentView = webView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        hud = HUDController(availableTools: availableTools)
        hud.setProviderVisibility(modelProviderVisibility(for: "globalHUD"))
        hud.setUsageAlertThreshold(usageAlertThresholdPercent)
        hud.setKimiMonthlyAlertThreshold(kimiMonthlyAlertThresholdPercent)
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
        hud.onRefresh = { [weak self] in
            self?.refresh()
        }
        menuBarExpandedHUD = HUDController(
            availableTools: availableTools,
            presentationMode: .menuBarPopover
        )
        menuBarExpandedHUD.setProviderVisibility(modelProviderVisibility(for: "menuBarHUD"))
        menuBarExpandedHUD.setUsageAlertThreshold(usageAlertThresholdPercent)
        menuBarExpandedHUD.setKimiMonthlyAlertThreshold(kimiMonthlyAlertThresholdPercent)
        menuBarExpandedHUD.setDeepSeekBalanceAlert(
            threshold: deepSeekBalanceAlertThreshold,
            currency: deepSeekBalanceAlertCurrency
        )
        menuBarExpandedHUD.onOpenMainApp = { [weak self] in
            guard let self else { return }
            self.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        menuBarExpandedHUD.onRefresh = { [weak self] in
            self?.refresh()
        }
        menuBarUsage = MenuBarUsageController(availableTools: availableTools)
        menuBarUsage.onRefresh = { [weak self] in
            self?.refresh()
        }
        menuBarUsage.onOpenMainApp = { [weak self] in
            guard let self else { return }
            self.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        menuBarUsage.onToggleExpanded = { [weak self] anchorView in
            self?.menuBarExpandedHUD.toggleMenuBarPopover(relativeTo: anchorView)
        }
        menuBarExpandedHUD.onDisableMenuBarHUD = { [weak self] in
            self?.disableMenuBarHUD()
        }
        menuBarUsage.setDeepSeekBalanceCurrency(deepSeekBalanceAlertCurrency)
        menuBarUsage.setProviderVisibility(modelProviderVisibility(for: "menuBarHUD"))
        menuBarUsage.setEnabled(menuBarHUDEnabled)
        menuBarExpandedHUD.setEnabled(menuBarHUDEnabled)
        let page = Bundle.main.resourceURL!.appendingPathComponent("Resources/index.html")
        webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        observeKimiAppLifecycle()

        if availableTools.hasAny {
            updateAutoRefreshTimer()
            refresh()
        }
        if NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.moonshot.kimichat"
        ).isEmpty == false {
            refreshKimiAfterDesktopOpens()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        checkToolAvailability()
        if !hasVisibleWindows { window.makeKeyAndOrderFront(nil) }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        kimiRefreshAfterOpenTask?.cancel()
        let center = NSWorkspace.shared.notificationCenter
        kimiAppObservers.forEach { center.removeObserver($0) }
        kimiAppObservers.removeAll()
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let action = body["action"] as? String else { return }
        switch action {
        case "refresh":
            refresh()
        case "setAutoRefreshEnabled":
            guard let enabled = body["enabled"] as? Bool else { return }
            UserDefaults.standard.set(enabled, forKey: autoRefreshEnabledKey)
            updateAutoRefreshTimer()
            if enabled { refresh() }
            pushHUDState()
        case "setToolEnabled":
            guard let tool = body["tool"] as? String,
                  ["codex", "deepseek", "kimi"].contains(tool),
                  let enabled = body["enabled"] as? Bool else { return }
            setToolEnabled(tool, enabled: enabled)
        case "connectKimi":
            guard availableTools.kimi else { return }
            openKimiDesktop()
        case "openKimiAccount":
            guard availableTools.kimi else { return }
            openKimiDesktop()
        case "openChatGPTApp":
            guard availableTools.codex else { return }
            openDesktopApplication(
                bundleIdentifier: "com.openai.codex",
                applicationName: "ChatGPT",
                fallbackURL: Self.chatGPTURL
            )
        case "openDeepSeekHarness":
            guard availableTools.deepSeek else { return }
            openDesktopApplication(
                bundleIdentifier: "com.deepseek.dsh",
                applicationName: "DeepSeek Harness",
                fallbackURL: Self.deepSeekPlatformURL
            )
        case "toggleHUD":
            guard availableTools.hasAny else { return }
            hud.setEnabled((body["enabled"] as? Bool) ?? false)
            pushHUDState()
        case "toggleMenuBarHUD":
            guard availableTools.hasAny else { return }
            let enabled = (body["enabled"] as? Bool) ?? false
            UserDefaults.standard.set(enabled, forKey: menuBarHUDEnabledKey)
            menuBarUsage.setEnabled(enabled)
            menuBarExpandedHUD.setEnabled(enabled)
            if enabled { refresh() }
            pushHUDState()
        case "setModelHUDVisibility":
            guard let provider = body["provider"] as? String,
                  Self.hudProviders.contains(provider),
                  let surface = body["surface"] as? String,
                  surface == "globalHUD" || surface == "menuBarHUD",
                  let enabled = body["enabled"] as? Bool else { return }
            UserDefaults.standard.set(
                enabled,
                forKey: "\(modelHUDVisibilityKeyPrefix).\(surface).\(provider)"
            )
            hud.setProviderVisibility(modelProviderVisibility(for: "globalHUD"))
            let menuBarVisibility = modelProviderVisibility(for: "menuBarHUD")
            menuBarUsage.setProviderVisibility(menuBarVisibility)
            menuBarExpandedHUD.setProviderVisibility(menuBarVisibility)
            pushHUDState()
        case "moveHUDToDisplay":
            guard availableTools.hasAny,
                  let displayID = body["displayID"] as? String else { return }
            hud.moveToDisplay(displayID)
            pushHUDState()
        case "setUsageAlertThreshold":
            guard availableTools.codex else { return }
            guard let number = body["value"] as? NSNumber else { return }
            let threshold = min(100, max(0, number.intValue))
            UserDefaults.standard.set(threshold, forKey: usageAlertThresholdKey)
            hud.setUsageAlertThreshold(threshold)
            menuBarExpandedHUD.setUsageAlertThreshold(threshold)
            pushHUDState()
        case "setKimiMonthlyAlertThreshold":
            guard availableTools.kimi else { return }
            guard let number = body["value"] as? NSNumber else { return }
            let threshold = min(100, max(0, number.intValue))
            UserDefaults.standard.set(threshold, forKey: kimiMonthlyAlertThresholdKey)
            hud.setKimiMonthlyAlertThreshold(threshold)
            menuBarExpandedHUD.setKimiMonthlyAlertThreshold(threshold)
            pushHUDState()
        case "setDeepSeekBalanceAlert":
            guard availableTools.deepSeek else { return }
            guard let number = body["threshold"] as? NSNumber else { return }
            let threshold = max(0, number.doubleValue)
            let currency = (body["currency"] as? String) == "USD" ? "USD" : "CNY"
            UserDefaults.standard.set(threshold, forKey: deepSeekBalanceAlertThresholdKey)
            UserDefaults.standard.set(currency, forKey: deepSeekBalanceAlertCurrencyKey)
            hud.setDeepSeekBalanceAlert(threshold: threshold, currency: currency)
            menuBarExpandedHUD.setDeepSeekBalanceAlert(threshold: threshold, currency: currency)
            menuBarUsage.setDeepSeekBalanceCurrency(currency)
            pushHUDState()
        case "openUsage":
            guard availableTools.deepSeek else { return }
            NSWorkspace.shared.open(URL(string: "https://platform.deepseek.com/usage")!)
        case "openTopUp":
            guard availableTools.deepSeek else { return }
            NSWorkspace.shared.open(URL(string: "https://platform.deepseek.com/top_up")!)
        case "loadSessionDetail":
            guard let providerName = body["provider"] as? String,
                  let sessionID = body["sessionId"] as? String,
                  let requestID = body["requestId"] as? String,
                  (providerName == "codex" && availableTools.codex)
                    || (providerName == "deepseek" && availableTools.deepSeek) else { return }
            let detailTask = Task { [weak self] in
                guard let self else { return }
                defer { self.sessionDetailTasks.removeValue(forKey: requestID) }
                guard !Task.isCancelled else { return }
                var detail = await self.provider.sessionDetail(provider: providerName, sessionID: sessionID)
                guard !Task.isCancelled,
                    (providerName == "codex" && self.availableTools.codex)
                    || (providerName == "deepseek" && self.availableTools.deepSeek) else { return }
                detail["provider"] = providerName
                detail["requestId"] = requestID
                self.sendSessionDetail(detail)
            }
            sessionDetailTasks[requestID] = (providerName, detailTask)
        default:
            break
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageReady = true
        pushToolAvailability()
        pushToolSettings()
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

    private func disableMenuBarHUD() {
        UserDefaults.standard.set(false, forKey: menuBarHUDEnabledKey)
        menuBarUsage.setEnabled(false)
        menuBarExpandedHUD.setEnabled(false)
        pushHUDState()
    }

    private func refresh() {
        guard availableTools.hasAny else { return }
        requestKimiQuota()
        guard !refreshInFlight else { return }
        refreshInFlight = true
        let refreshingTools = availableTools
        let generation = refreshGeneration
        refreshTask = Task {
            var snapshot = await provider.snapshot(availableTools: refreshingTools)
            guard !Task.isCancelled, generation == refreshGeneration else { return }
            snapshot["kimi"] = latestKimiUsage
            preserveTodayTokenUsage(from: latestSnapshot, in: &snapshot)
            latestSnapshot = filteredSnapshot(snapshot)
            hud.render(latestSnapshot)
            menuBarUsage.render(latestSnapshot)
            menuBarExpandedHUD.render(latestSnapshot)
            sendSnapshot(latestSnapshot)
            refreshInFlight = false
            refreshTask = nil
            refreshTodayTokenUsage(availableTools: refreshingTools)
        }
    }

    private func refreshTodayTokenUsage(availableTools: ToolAvailability) {
        guard !todayTokenRefreshInFlight else { return }
        todayTokenRefreshInFlight = true
        let generation = todayTokenRefreshGeneration
        todayTokenRefreshTask = Task {
            let todayUsage = await provider.todayTokenSnapshot(availableTools: availableTools)
            guard !Task.isCancelled, generation == todayTokenRefreshGeneration else { return }
            todayTokenRefreshInFlight = false
            todayTokenRefreshTask = nil
            guard !latestSnapshot.isEmpty else { return }
            for name in ["codex", "deepseek"] {
                guard self.availableTools.dictionary[name] == true else { continue }
                guard let updates = todayUsage[name] as? [String: Any],
                      var model = latestSnapshot[name] as? [String: Any],
                      var tokens = model["tokens"] as? [String: Any] else { continue }
                tokens["todayAvailable"] = updates["todayAvailable"]
                tokens["todayTokens"] = updates["todayTokens"]
                model["tokens"] = tokens
                latestSnapshot[name] = model
            }
            hud.render(latestSnapshot)
            menuBarUsage.render(latestSnapshot)
            menuBarExpandedHUD.render(latestSnapshot)
            sendSnapshot(latestSnapshot)
        }
    }

    private func preserveTodayTokenUsage(from previous: [String: Any], in snapshot: inout [String: Any]) {
        for name in ["codex", "deepseek"] {
            guard let oldModel = previous[name] as? [String: Any],
                  let oldTokens = oldModel["tokens"] as? [String: Any],
                  oldTokens["todayAvailable"] as? Bool == true,
                  var model = snapshot[name] as? [String: Any],
                  var tokens = model["tokens"] as? [String: Any] else { continue }
            tokens["todayAvailable"] = true
            tokens["todayTokens"] = oldTokens["todayTokens"]
            model["tokens"] = tokens
            snapshot[name] = model
        }
    }

    private func checkToolAvailability() {
        detectedTools = ToolAvailability.detect()
        applyToolAvailability(refreshIfNeeded: true)
    }

    private func setToolEnabled(_ tool: String, enabled: Bool) {
        guard enabledTools[tool] != enabled else { return }
        enabledTools[tool] = enabled
        UserDefaults.standard.set(enabled, forKey: "usage.toolEnabled.\(tool)")

        cancelProviderWork()
        if !enabled {
            let detailRequestIDs = sessionDetailTasks
                .filter { $0.value.provider == tool }
                .map(\.key)
            for requestID in detailRequestIDs {
                sessionDetailTasks.removeValue(forKey: requestID)?.task.cancel()
            }
            latestSnapshot.removeValue(forKey: tool)
            if tool == "kimi" {
                kimiRefreshAfterOpenTask?.cancel()
                kimiRefreshAfterOpenTask = nil
                kimiQueryGeneration += 1
                kimiQueryTask?.cancel()
                kimiQueryTask = nil
                kimiQueryInFlight = false
                kimiLastMonthlyReadAt = nil
                latestKimiUsage = Self.emptyKimiUsage
            }
            latestSnapshot = filteredSnapshot(latestSnapshot)
            hud.render(latestSnapshot)
            menuBarUsage.render(latestSnapshot)
            menuBarExpandedHUD.render(latestSnapshot)
            sendSnapshot(latestSnapshot)
        }
        applyToolAvailability(refreshIfNeeded: true)
    }

    private func applyToolAvailability(refreshIfNeeded: Bool) {
        hud.setToolAvailability(availableTools)
        menuBarUsage.setToolAvailability(availableTools)
        menuBarExpandedHUD.setToolAvailability(availableTools)
        latestSnapshot = filteredSnapshot(latestSnapshot)
        hud.render(latestSnapshot)
        menuBarUsage.render(latestSnapshot)
        menuBarExpandedHUD.render(latestSnapshot)
        pushToolAvailability()
        pushToolSettings()
        pushHUDState()
        updateAutoRefreshTimer()
        if refreshIfNeeded && availableTools.hasAny { refresh() }
    }

    private func cancelProviderWork() {
        refreshGeneration += 1
        refreshTask?.cancel()
        refreshTask = nil
        refreshInFlight = false
        todayTokenRefreshGeneration += 1
        todayTokenRefreshTask?.cancel()
        todayTokenRefreshTask = nil
        todayTokenRefreshInFlight = false
    }

    private func filteredSnapshot(_ snapshot: [String: Any]) -> [String: Any] {
        var filtered = snapshot
        filtered["tools"] = availableTools.dictionary
        if !availableTools.codex { filtered.removeValue(forKey: "codex") }
        if !availableTools.deepSeek { filtered.removeValue(forKey: "deepseek") }
        if !availableTools.kimi { filtered.removeValue(forKey: "kimi") }
        return filtered
    }

    private func updateAutoRefreshTimer() {
        guard availableTools.hasAny, autoRefreshEnabled else {
            refreshTimer?.invalidate()
            refreshTimer = nil
            return
        }
        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func requestKimiQuota() {
        guard availableTools.kimi, !kimiQueryInFlight else { return }
        kimiQueryInFlight = true
        let generation = kimiQueryGeneration
        kimiQueryTask = Task {
            var usage = await self.kimiClient.fetchUsage()
            guard generation == self.kimiQueryGeneration else { return }
            guard !Task.isCancelled, self.availableTools.kimi else {
                self.kimiQueryInFlight = false
                self.kimiQueryTask = nil
                return
            }
            usage["sessions"] = []
            usage["sessionsReason"] = "当前 Kimi 桌面会员接口不提供对话历史"
            self.latestKimiUsage = usage
            if self.hasKimiMonthlyQuota(usage) {
                self.kimiLastMonthlyReadAt = Date()
            }
            self.kimiQueryInFlight = false
            self.kimiQueryTask = nil
            self.updateSnapshotWithKimiUsage()
        }
    }

    private func observeKimiAppLifecycle() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification] {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == "com.moonshot.kimichat" else { return }
                Task { @MainActor in
                    self?.refreshKimiAfterDesktopOpens()
                }
            }
            kimiAppObservers.append(observer)
        }
    }

    private func openKimiDesktop() {
        let bundleIdentifier = "com.moonshot.kimichat"
        if let runningApp = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).first {
            runningApp.activate(options: [.activateIgnoringOtherApps])
        } else if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(Self.kimiSubscriptionURL)
            return
        }
        refreshKimiAfterDesktopOpens()
    }

    private func refreshKimiAfterDesktopOpens() {
        guard availableTools.kimi else { return }
        kimiRefreshAfterOpenTask?.cancel()
        kimiRefreshAfterOpenTask = Task { [weak self] in
            // The Kimi desktop app renews its session when its Chat surface makes a
            // request. Keep rereading its own session store while that startup settles.
            guard let self, self.availableTools.kimi else { return }
            let priorMonthlyReadAt = self.kimiLastMonthlyReadAt
            self.requestKimiQuota()
            for delay in [15, 30, 60, 90] {
                do {
                    try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                guard self.availableTools.kimi else { return }
                if let lastReadAt = self.kimiLastMonthlyReadAt,
                   lastReadAt > (priorMonthlyReadAt ?? .distantPast) {
                    return
                }
                self.requestKimiQuota()
            }
        }
    }

    private func hasKimiMonthlyQuota(_ usage: [String: Any]) -> Bool {
        guard let monthly = usage["monthly"] as? [String: Any],
              let usedPercent = monthly["usedPercent"] as? NSNumber else { return false }
        return usedPercent.doubleValue.isFinite && (0...100).contains(usedPercent.doubleValue)
    }

    private func openDesktopApplication(
        bundleIdentifier: String,
        applicationName: String,
        fallbackURL: URL
    ) {
        let workspace = NSWorkspace.shared
        if let runningApp = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).first {
            runningApp.activate(options: [.activateIgnoringOtherApps])
            return
        }
        if let appURL = workspace.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            workspace.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
            return
        }
        let appPath = applicationName + ".app"
        let roots = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications")
        ]
        if let appURL = roots.map({ $0.appendingPathComponent(appPath) })
            .first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            workspace.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
            return
        }
        workspace.open(fallbackURL)
    }

    private func updateSnapshotWithKimiUsage() {
        guard availableTools.kimi, !latestSnapshot.isEmpty else { return }
        latestSnapshot["kimi"] = latestKimiUsage
        hud.render(latestSnapshot)
        menuBarUsage.render(latestSnapshot)
        menuBarExpandedHUD.render(latestSnapshot)
        sendSnapshot(latestSnapshot)
    }

    private func sendSnapshot(_ snapshot: [String: Any]) {
        guard pageReady,
              let data = try? JSONSerialization.data(withJSONObject: filteredSnapshot(snapshot), options: [.fragmentsAllowed]),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.AAAAAUsage && window.AAAAAUsage.render(\(json));")
    }

    private func sendSessionDetail(_ detail: [String: Any]) {
        guard pageReady,
              let provider = detail["provider"] as? String,
              (provider == "codex" && availableTools.codex)
                || (provider == "deepseek" && availableTools.deepSeek),
              let data = try? JSONSerialization.data(withJSONObject: detail, options: [.fragmentsAllowed]),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.AAAAAUsage && window.AAAAAUsage.receiveSessionDetail(\(json));")
    }

    private func pushHUDState() {
        guard pageReady,
              let data = try? JSONSerialization.data(withJSONObject: hud.availableDisplays()),
              let displaysJSON = String(data: data, encoding: .utf8),
              let visibilityData = try? JSONSerialization.data(withJSONObject: modelHUDVisibilitySettings),
              let visibilityJSON = String(data: visibilityData, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.AAAAAUsage && window.AAAAAUsage.setAutoRefreshEnabled(\(autoRefreshEnabled)); window.AAAAAUsage && window.AAAAAUsage.setUsageAlertThreshold(\(usageAlertThresholdPercent)); window.AAAAAUsage && window.AAAAAUsage.setKimiMonthlyAlertThreshold(\(kimiMonthlyAlertThresholdPercent)); window.AAAAAUsage && window.AAAAAUsage.setDeepSeekBalanceAlert(\(deepSeekBalanceAlertThreshold), '\(deepSeekBalanceAlertCurrency)'); window.AAAAAUsage && window.AAAAAUsage.setHUDEnabled(\(hud.isEnabled()), \(hud.isVisible())); window.AAAAAUsage && window.AAAAAUsage.setMenuBarHUDEnabled(\(menuBarUsage.isEnabled())); window.AAAAAUsage && window.AAAAAUsage.setHUDDisplays(\(displaysJSON)); window.AAAAAUsage && window.AAAAAUsage.setModelHUDVisibility(\(visibilityJSON));")
    }

    private func pushToolAvailability() {
        guard pageReady,
              let data = try? JSONSerialization.data(withJSONObject: availableTools.dictionary),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.AAAAAUsage && window.AAAAAUsage.setToolAvailability(\(json));")
    }

    private func pushToolSettings() {
        guard pageReady,
              let enabledData = try? JSONSerialization.data(withJSONObject: enabledTools),
              let enabledJSON = String(data: enabledData, encoding: .utf8),
              let detectedData = try? JSONSerialization.data(withJSONObject: detectedTools.dictionary),
              let detectedJSON = String(data: detectedData, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.AAAAAUsage && window.AAAAAUsage.setToolSettings(\(enabledJSON), \(detectedJSON));")
    }

    private var usageAlertThresholdPercent: Int {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: usageAlertThresholdKey) != nil else {
            return defaultUsageAlertThresholdPercent
        }
        return min(100, max(0, defaults.integer(forKey: usageAlertThresholdKey)))
    }

    private var autoRefreshEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: autoRefreshEnabledKey) != nil else { return true }
        return defaults.bool(forKey: autoRefreshEnabledKey)
    }

    private var menuBarHUDEnabled: Bool {
        UserDefaults.standard.bool(forKey: menuBarHUDEnabledKey)
    }

    private func modelProviderVisibility(for surface: String) -> [String: Bool] {
        let defaults = UserDefaults.standard
        return Dictionary(uniqueKeysWithValues: Self.hudProviders.map { provider in
            let key = "\(modelHUDVisibilityKeyPrefix).\(surface).\(provider)"
            return (provider, defaults.object(forKey: key) as? Bool ?? true)
        })
    }

    private var modelHUDVisibilitySettings: [String: [String: Bool]] {
        let globalHUD = modelProviderVisibility(for: "globalHUD")
        let menuBarHUD = modelProviderVisibility(for: "menuBarHUD")
        return Dictionary(uniqueKeysWithValues: Self.hudProviders.map { provider in
            (provider, [
                "globalHUD": globalHUD[provider] ?? true,
                "menuBarHUD": menuBarHUD[provider] ?? true
            ])
        })
    }

    private var kimiMonthlyAlertThresholdPercent: Int {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: kimiMonthlyAlertThresholdKey) != nil else {
            return defaultKimiMonthlyAlertThresholdPercent
        }
        return min(100, max(0, defaults.integer(forKey: kimiMonthlyAlertThresholdKey)))
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

    private static let kimiSubscriptionURL = URL(
        string: "https://www.kimi.com/membership/subscription?tab=quota"
    )!
    private static let hudProviders = ["codex", "deepseek", "kimi"]
    private static let chatGPTURL = URL(string: "https://chatgpt.com/")!
    private static let deepSeekPlatformURL = URL(string: "https://platform.deepseek.com/")!

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

@MainActor
private final class MenuBarUsageController: NSObject {
    var onRefresh: (() -> Void)?
    var onOpenMainApp: (() -> Void)?
    var onToggleExpanded: ((NSView) -> Void)?

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var availableTools: ToolAvailability
    private var snapshot: [String: Any] = [:]
    private var enabled = false
    private var deepSeekBalanceCurrency = "CNY"
    private var pendingSingleClick: DispatchWorkItem?
    private var providerVisibility: [String: Bool] = [
        "codex": true, "deepseek": true, "kimi": true
    ]
    private var displayPanels: [UInt32: MenuBarHUDPanel] = [:]
    private var activeDisplayID: UInt32?
    private var displayRefreshTimer: Timer?
    private var displayChangeObserver: NSObjectProtocol?
    private var title = NSAttributedString(string: "")

    init(availableTools: ToolAvailability) {
        self.availableTools = availableTools
        super.init()
        if let button = statusItem.button {
            // Keep the native item as a layout spacer so the per-display panels
            // occupy the exact menu-bar slot reserved by macOS.
            button.title = ""
            button.attributedTitle = NSAttributedString(string: "")
            button.image = nil
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.backgroundColor = NSColor.clear.cgColor
            button.layer?.borderWidth = 0
            button.alphaValue = 0
        }
        displayChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshDisplayPanels() }
        }
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshDisplayPanels() }
        }
        displayRefreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        updateVisibility()
        updateTitle()
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        updateVisibility()
        updateTitle()
    }

    func isEnabled() -> Bool { enabled }

    func setToolAvailability(_ availability: ToolAvailability) {
        availableTools = availability
        updateVisibility()
        updateTitle()
    }

    func setProviderVisibility(_ visibility: [String: Bool]) {
        providerVisibility = visibility
        updateVisibility()
        updateTitle()
    }

    func setDeepSeekBalanceCurrency(_ currency: String) {
        deepSeekBalanceCurrency = currency == "USD" ? "USD" : "CNY"
        updateTitle()
    }

    func render(_ snapshot: [String: Any]) {
        self.snapshot = snapshot
        updateTitle()
    }

    private func handleStatusItemClick(clickCount: Int) {
        if clickCount >= 2 {
            pendingSingleClick?.cancel()
            pendingSingleClick = nil
            onOpenMainApp?()
            return
        }

        pendingSingleClick?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.onRefresh?()
            self?.pendingSingleClick = nil
        }
        pendingSingleClick = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
    }

    private func updateVisibility() {
        let shouldShow = enabled && hasVisibleProvider
        statusItem.isVisible = shouldShow
        if shouldShow {
            DispatchQueue.main.async { [weak self] in self?.refreshDisplayPanels() }
        } else {
            displayPanels.values.forEach { $0.orderOut(nil) }
        }
    }

    private var hasVisibleProvider: Bool {
        (availableTools.codex && providerVisibility["codex"] != false)
            || (availableTools.deepSeek && providerVisibility["deepseek"] != false)
            || (availableTools.kimi && providerVisibility["kimi"] != false)
    }

    private func updateTitle() {
        let codex = snapshot["codex"] as? [String: Any] ?? [:]
        let deepSeek = snapshot["deepseek"] as? [String: Any] ?? [:]
        let kimi = snapshot["kimi"] as? [String: Any] ?? [:]
        let codexPrimary = codex["primary"] as? [String: Any] ?? [:]
        let kimiMonthly = kimi["monthly"] as? [String: Any] ?? [:]
        let balances = deepSeek["balances"] as? [[String: Any]] ?? []
        let appearance = NSApp.effectiveAppearance
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let primaryTextColor = isDark ? NSColor.white : NSColor(calibratedWhite: 0.12, alpha: 1)
        let accentTextColor = isDark ? NSColor.systemOrange : Self.darkOrange

        let updatedTitle = NSMutableAttributedString(string: "  ", attributes: [
            .font: NSFont.systemFont(ofSize: 12)
        ])
        var hasMetric = false
        if availableTools.codex && providerVisibility["codex"] != false {
            appendMetric(icon: "chatgpt-icon", value: codex["available"] as? Bool == true
                         ? remainingText(codexPrimary["usedPercent"]) : "—",
                         color: primaryTextColor, to: updatedTitle, first: !hasMetric)
            hasMetric = true
        }
        if availableTools.deepSeek && providerVisibility["deepseek"] != false {
            let amount = balances.first { ($0["currency"] as? String) == deepSeekBalanceCurrency }?["amount"]
            let value = deepSeek["credentialAvailable"] as? Bool == true
                ? moneyText(amount, currency: deepSeekBalanceCurrency) : "—"
            appendMetric(icon: "deepseek-icon", value: value, color: accentTextColor,
                         to: updatedTitle, first: !hasMetric)
            hasMetric = true
        }
        if availableTools.kimi && providerVisibility["kimi"] != false {
            appendMetric(icon: "kimi-icon", value: kimi["available"] as? Bool == true
                         ? remainingText(kimiMonthly["usedPercent"]) : "—",
                         color: accentTextColor, to: updatedTitle, first: !hasMetric)
        }
        updatedTitle.append(NSAttributedString(string: "  ", attributes: [
            .font: NSFont.systemFont(ofSize: 12)
        ]))
        title = updatedTitle.copy() as? NSAttributedString ?? updatedTitle
        let measuredWidth = title.boundingRect(
            with: NSSize(width: 10_000, height: 100),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).width
        let finiteWidths = [title.size().width, measuredWidth].filter { $0.isFinite && $0 >= 0 }
        let contentWidth = finiteWidths.max() ?? 0
        statusItem.length = ceil(min(600, max(48, contentWidth + 15)))
        displayPanels.values.compactMap { $0.contentView as? MenuBarHUDStatusView }
            .forEach { $0.setTitle(title) }
        DispatchQueue.main.async { [weak self] in self?.refreshDisplayPanels() }
    }

    private func refreshDisplayPanels() {
        guard enabled, hasVisibleProvider else {
            displayPanels.values.forEach { $0.orderOut(nil) }
            return
        }

        let screens = NSScreen.screens
        guard !screens.isEmpty, let placement = statusItemPlacement(on: screens) else { return }
        let currentIDs = Set(screens.map(displayID(for:)))
        for staleID in displayPanels.keys.filter({ !currentIDs.contains($0) }) {
            displayPanels.removeValue(forKey: staleID)?.orderOut(nil)
        }

        let pointer = NSEvent.mouseLocation
        if let hoveredScreen = screens.first(where: { $0.frame.contains(pointer) }) {
            activeDisplayID = displayID(for: hoveredScreen)
        } else if activeDisplayID == nil {
            activeDisplayID = displayID(for: NSScreen.main ?? placement.screen)
        }

        for screen in screens {
            let id = displayID(for: screen)
            guard isReasonableRect(screen.frame) else {
                displayPanels[id]?.orderOut(nil)
                continue
            }
            let panel = displayPanels[id] ?? makePanel(for: id)
            let frame = NSRect(
                x: screen.frame.maxX - placement.rightInset - placement.size.width,
                y: screen.frame.maxY - placement.topInset - placement.size.height,
                width: placement.size.width,
                height: placement.size.height
            )
            guard isReasonableRect(frame, maxWidth: 700, maxHeight: 100) else {
                panel.orderOut(nil)
                continue
            }
            if !NSEqualRects(panel.frame, frame) {
                panel.setFrame(frame, display: true)
            }
            if let view = panel.contentView as? MenuBarHUDStatusView {
                view.setTitle(title)
                view.setAccessibilityValue(id == activeDisplayID
                    ? "当前鼠标所在显示器 · 100%"
                    : "其他显示器 · 30%")
            }
            let targetAlpha: CGFloat = id == activeDisplayID ? 1 : 0.3
            if !panel.isVisible {
                panel.alphaValue = targetAlpha
                panel.orderFrontRegardless()
            } else if abs(panel.alphaValue - targetAlpha) > 0.01 {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.15
                    panel.animator().alphaValue = targetAlpha
                }
            }
        }
    }

    private func makePanel(for displayID: UInt32) -> MenuBarHUDPanel {
        let contentView = MenuBarHUDStatusView(frame: .zero)
        contentView.onClick = { [weak self] count in
            self?.handleStatusItemClick(clickCount: count)
        }
        contentView.onRightClick = { [weak self, weak contentView] in
            guard let contentView else { return }
            self?.onToggleExpanded?(contentView)
        }
        contentView.setAccessibilityElement(true)
        contentView.setAccessibilityRole(.button)
        contentView.setAccessibilityLabel("用量监控菜单栏用量")
        contentView.toolTip = "单击刷新用量，双击打开用量监控，右键展开 HUD"

        let panel = MenuBarHUDPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "用量监控菜单栏 HUD · \(displayID)"
        panel.contentView = contentView
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.alphaValue = 0.3
        displayPanels[displayID] = panel
        return panel
    }

    private func statusItemPlacement(on screens: [NSScreen]) ->
        (screen: NSScreen, rightInset: CGFloat, topInset: CGFloat, size: NSSize)? {
        guard let button = statusItem.button,
              let window = button.window else { return nil }
        let itemRect = window.convertToScreen(button.convert(button.bounds, to: nil))
        guard isReasonableRect(itemRect, maxWidth: 700, maxHeight: 100) else { return nil }
        let screen = window.screen
            ?? screens.first(where: { $0.frame.intersects(itemRect) })
            ?? screens.first
        guard let screen, isReasonableRect(screen.frame) else { return nil }
        let rightInset = screen.frame.maxX - itemRect.maxX
        let topInset = screen.frame.maxY - itemRect.maxY
        guard rightInset.isFinite, topInset.isFinite,
              abs(rightInset) <= 100_000, abs(topInset) <= 100_000 else { return nil }
        return (
            screen,
            max(0, rightInset),
            max(0, topInset),
            itemRect.size
        )
    }

    private func isReasonableRect(
        _ rect: NSRect,
        maxWidth: CGFloat = 100_000,
        maxHeight: CGFloat = 100_000
    ) -> Bool {
        [rect.minX, rect.minY, rect.width, rect.height].allSatisfy { $0.isFinite }
            && abs(rect.minX) <= 100_000
            && abs(rect.minY) <= 100_000
            && rect.width > 0
            && rect.width <= maxWidth
            && rect.height > 0
            && rect.height <= maxHeight
    }

    private func displayID(for screen: NSScreen) -> UInt32 {
        if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return number.uint32Value
        }
        return UInt32(truncatingIfNeeded: ObjectIdentifier(screen).hashValue)
    }

    private func appendMetric(icon: String, value: String, color: NSColor,
                              to title: NSMutableAttributedString, first: Bool) {
        if !first {
            title.append(NSAttributedString(string: "   ", attributes: [.font: NSFont.systemFont(ofSize: 12)]))
        }
        if let url = Bundle.main.url(forResource: icon, withExtension: "png", subdirectory: "Resources"),
           let image = NSImage(contentsOf: url) {
            let iconSide: CGFloat = 15
            let valueFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
            image.size = NSSize(width: iconSide, height: iconSide)
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = NSRect(
                x: 0,
                y: (valueFont.capHeight - iconSide) / 2,
                width: iconSide,
                height: iconSide
            )
            title.append(NSAttributedString(attachment: attachment))
            title.append(NSAttributedString(string: " \(value)", attributes: [
                .font: valueFont,
                .foregroundColor: color
            ]))
            return
        }
        title.append(NSAttributedString(string: " \(value)", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: color
        ]))
    }

    private func remainingText(_ rawValue: Any?) -> String {
        guard let value = rawValue as? NSNumber, value.doubleValue.isFinite else { return "—" }
        let used = min(100, max(0, value.doubleValue))
        return "\(Int((100 - used).rounded()))%"
    }

    private func moneyText(_ rawValue: Any?, currency: String) -> String {
        let amount: Double?
        if let value = rawValue as? NSNumber {
            amount = value.doubleValue
        } else if let value = rawValue as? String {
            amount = Double(value)
        } else {
            amount = nil
        }
        guard let amount, amount.isFinite else { return "—" }
        let number = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), amount)
        return "\(currency == "USD" ? "$" : "¥")\(number)"
    }

    private static let darkOrange = NSColor(calibratedRed: 0.70, green: 0.29, blue: 0.02, alpha: 1)
}

@MainActor
private final class MenuBarHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class MenuBarHUDStatusView: NSView {
    var onClick: ((Int) -> Void)?
    var onRightClick: (() -> Void)?
    private var title = NSAttributedString(string: "")
    private let materialView = NSVisualEffectView(frame: .zero)
    private let tintView = NSView(frame: .zero)
    private let titleField = NSTextField(labelWithAttributedString: NSAttributedString(string: ""))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true

        materialView.material = .menu
        materialView.blendingMode = .behindWindow
        materialView.state = .active
        materialView.wantsLayer = true
        materialView.layer?.masksToBounds = true
        addSubview(materialView)

        tintView.wantsLayer = true
        tintView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
        tintView.layer?.masksToBounds = true
        addSubview(tintView)

        titleField.alignment = .center
        titleField.isEditable = false
        titleField.isSelectable = false
        titleField.isBordered = false
        titleField.drawsBackground = false
        titleField.cell?.wraps = false
        titleField.cell?.lineBreakMode = .byClipping
        addSubview(titleField)
        needsLayout = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func setFrameSize(_ newSize: NSSize) {
        guard newSize.width.isFinite, newSize.height.isFinite,
              newSize.width >= 0, newSize.width <= 700,
              newSize.height >= 0, newSize.height <= 100 else { return }
        super.setFrameSize(newSize)
        needsLayout = true
    }

    func setTitle(_ value: NSAttributedString) {
        title = value.copy() as? NSAttributedString ?? value
        titleField.attributedStringValue = title
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let bounds = self.bounds
        guard [bounds.minX, bounds.minY, bounds.width, bounds.height]
            .allSatisfy({ $0.isFinite }),
              abs(bounds.minX) <= 100_000,
              abs(bounds.minY) <= 100_000,
              bounds.width >= 2, bounds.width <= 700,
              bounds.height >= 2, bounds.height <= 100 else {
            materialView.frame = .zero
            tintView.frame = .zero
            titleField.frame = .zero
            return
        }
        let capsuleRect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let radius = max(0, capsuleRect.height / 2)
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.34).cgColor

        let insetRect = bounds.insetBy(dx: 1, dy: 1)
        materialView.frame = insetRect
        materialView.layer?.cornerRadius = max(0, insetRect.height / 2)
        tintView.frame = insetRect
        tintView.layer?.cornerRadius = max(0, insetRect.height / 2)

        let titleHeight = min(bounds.height, max(1, ceil(title.size().height)))
        titleField.frame = NSRect(
            x: 2,
            y: max(0, (bounds.height - titleHeight) / 2),
            width: max(0, bounds.width - 4),
            height: titleHeight
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if layer?.borderWidth != 1 {
            layer?.borderWidth = 1
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        onClick?(event.clickCount)
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
    }
}
