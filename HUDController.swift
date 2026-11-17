import AppKit
import CoreGraphics
import Foundation

@MainActor
final class HUDController {
    var onStateChange: (() -> Void)?
    var onOpenMainApp: (() -> Void)?
    var onRefresh: (() -> Void)?

    private let defaults = UserDefaults.standard
    private let panel: NSPanel
    private let rootView: MovableHUDView
    private let compactStack: NSStackView
    private let expandedStack: NSStackView
    private let compactCodexMetric: NSView
    private let compactDeepSeekMetric: NSView
    private let compactKimiMetric: HUDCompactMetric
    private let codexCard: HUDMetricCard
    private let deepSeekCard: HUDMetricCard
    private let kimiCard: HUDMetricCard
    private var expandedMetricsHeightConstraint: NSLayoutConstraint!
    private let compactCodexValue: NSTextField
    private let compactDeepSeekValue: NSTextField
    private let compactKimiValue: NSTextField
    private let compactUpdatedValue: NSTextField
    private let codexPrimaryValue: NSTextField
    private let codexWeeklyValue: NSTextField
    private let deepSeekBalanceValue: NSTextField
    private let deepSeekSpendValue: NSTextField
    private let kimiMonthlyValue: NSTextField
    private let kimiRefreshValue: NSTextField
    private let tokenValue: NSTextField
    private let updatedValue: NSTextField
    private var anchor = NSPoint.zero
    private var selectedDisplayID: UInt32?
    private var isExpanded = false
    private var enabled = false
    private var currentAvailability: ToolAvailability?
    private var providerVisibility: [String: Bool] = [
        "codex": true, "deepseek": true, "kimi": true
    ]
    private var expandsRight = true
    private var expandsDown = false
    private var usageAlertThresholdPercent = 20
    private var codexPrimaryRemainingPercent: Int?
    private var codexWeeklyRemainingPercent: Int?
    private var kimiMonthlyAlertThresholdPercent = 20
    private var kimiMonthlyRemainingPercent: Int?
    private var deepSeekBalanceAlertThreshold = 10.0
    private var deepSeekBalanceAlertCurrency = "CNY"
    private var deepSeekBalances: [[String: Any]] = []
    private var deepSeekCredentialAvailable = false
    private var deepSeekBalanceAlertActive = false
    private var compactLayoutConstraints: [NSLayoutConstraint] = []
    private var expandedLayoutConstraints: [NSLayoutConstraint] = []
    private var screenChangeObserver: NSObjectProtocol?

    private static let panelWidth: CGFloat = 368
    private static let collapsedHeight: CGFloat = 79
    private var expandedHeight: CGFloat = 236
    private static var collapsedSize: NSSize {
        NSSize(width: panelWidth, height: collapsedHeight)
    }
    private var expandedSize: NSSize {
        NSSize(width: Self.panelWidth, height: expandedHeight)
    }

    init(availableTools: ToolAvailability) {
        let root = MovableHUDView(frame: NSRect(origin: .zero, size: Self.collapsedSize))
        root.material = .hudWindow
        root.blendingMode = .behindWindow
        root.state = .active
        root.appearance = NSAppearance(named: .darkAqua)
        root.wantsLayer = true
        root.layer?.cornerRadius = 18
        root.layer?.masksToBounds = true
        root.layer?.borderWidth = 1
        root.layer?.borderColor = NSColor.white.withAlphaComponent(0.17).cgColor
        let tint = NSView()
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor(
            calibratedRed: 0.055,
            green: 0.065,
            blue: 0.085,
            alpha: 0.80
        ).cgColor
        tint.layer?.cornerRadius = 18
        root.addSubview(tint)
        rootView = root

        let compactCodex = Self.label("—", size: 12, weight: .semibold, color: .white)
        let compactDeepSeek = Self.label("—", size: 12, weight: .semibold, color: .white)
        let compactKimi = Self.label("—", size: 12, weight: .semibold, color: .white)
        compactCodexValue = compactCodex
        compactDeepSeekValue = compactDeepSeek
        compactKimiValue = compactKimi

        let compactBrandIcon = Self.brandIcon()
        let compactBrandTitle = Self.label("用量监控", size: 11, weight: .semibold, color: .white)
        let compactBrand = NSStackView(views: [compactBrandIcon, compactBrandTitle])
        compactBrand.orientation = .horizontal
        compactBrand.alignment = .centerY
        compactBrand.spacing = 7
        let compactTime = Self.label("等待数据", size: 9, weight: .regular, color: .white.withAlphaComponent(0.68))
        compactTime.alignment = .right
        compactUpdatedValue = compactTime
        let compactExpandButton = Self.button(
            symbol: "chevron.up", fallback: "⌃", accessibilityLabel: "展开用量监控"
        )
        let compactRefreshButton = Self.button(
            symbol: "arrow.clockwise", fallback: "↻", accessibilityLabel: "刷新用量"
        )
        let compactHeader = NSStackView(views: [
            compactBrand, NSView(), compactTime, compactRefreshButton, compactExpandButton
        ])
        compactHeader.orientation = .horizontal
        compactHeader.alignment = .centerY
        compactHeader.distribution = .fill
        compactHeader.spacing = 8
        compactBrand.setContentHuggingPriority(.required, for: .horizontal)
        compactTime.setContentHuggingPriority(.required, for: .horizontal)
        compactRefreshButton.setContentHuggingPriority(.required, for: .horizontal)
        compactExpandButton.setContentHuggingPriority(.required, for: .horizontal)
        compactRefreshButton.widthAnchor.constraint(equalToConstant: 26).isActive = true
        compactRefreshButton.heightAnchor.constraint(equalToConstant: 26).isActive = true
        compactExpandButton.widthAnchor.constraint(equalToConstant: 26).isActive = true
        compactExpandButton.heightAnchor.constraint(equalToConstant: 26).isActive = true

        let compactCodexMetric = HUDCompactMetric(
            value: compactCodex, icon: Self.providerIcon("chatgpt-icon")
        )
        let compactDeepSeekMetric = HUDCompactMetric(
            value: compactDeepSeek, icon: Self.providerIcon("deepseek-icon")
        )
        let compactKimiMetric = HUDCompactMetric(
            value: compactKimi, icon: Self.providerIcon("kimi-icon")
        )
        self.compactCodexMetric = compactCodexMetric
        self.compactDeepSeekMetric = compactDeepSeekMetric
        self.compactKimiMetric = compactKimiMetric
        let compactMetrics = NSStackView(views: [compactCodexMetric, compactDeepSeekMetric, compactKimiMetric])
        compactMetrics.orientation = .horizontal
        compactMetrics.alignment = .centerY
        compactMetrics.distribution = .fillEqually
        compactMetrics.spacing = 9

        compactStack = Self.verticalStack([compactHeader, compactMetrics], spacing: 7)
        compactStack.distribution = .fill
        for view in [compactHeader, compactMetrics] {
            view.widthAnchor.constraint(equalTo: compactStack.widthAnchor).isActive = true
        }
        compactHeader.heightAnchor.constraint(equalToConstant: 24).isActive = true
        compactMetrics.heightAnchor.constraint(equalToConstant: 30).isActive = true

        let expandedBrandIcon = Self.brandIcon()
        let headerTitle = Self.label("用量监控", size: 13, weight: .semibold, color: .white)
        let openButton = Self.button(
            symbol: "macwindow", fallback: "窗口", accessibilityLabel: "打开主窗口"
        )
        let collapseButton = Self.button(
            symbol: "chevron.down", fallback: "⌄", accessibilityLabel: "折叠用量监控"
        )
        let closeButton = Self.button(
            symbol: "xmark", fallback: "×", accessibilityLabel: "关闭悬浮窗"
        )
        let header = NSStackView(views: [expandedBrandIcon, headerTitle, NSView(), openButton, collapseButton, closeButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.distribution = .fill
        header.spacing = 7

        for button in [openButton, collapseButton, closeButton] {
            button.widthAnchor.constraint(equalToConstant: 25).isActive = true
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }
        headerTitle.setContentHuggingPriority(.required, for: .horizontal)

        let codexCard = HUDMetricCard(
            title: "ChatGPT",
            firstLabel: "5 小时剩余",
            secondLabel: "每周剩余",
            icon: Self.providerIcon("chatgpt-icon")
        )
        self.codexCard = codexCard
        codexPrimaryValue = codexCard.firstValue
        codexWeeklyValue = codexCard.secondValue
        let deepSeekCard = HUDMetricCard(
            title: "DeepSeek",
            firstLabel: "账户余额 · 官方",
            secondLabel: "累计消费 · 官方",
            icon: Self.providerIcon("deepseek-icon")
        )
        self.deepSeekCard = deepSeekCard
        deepSeekBalanceValue = deepSeekCard.firstValue
        deepSeekSpendValue = deepSeekCard.secondValue
        let kimiCard = HUDMetricCard(
            title: "Kimi",
            firstLabel: "会员月额度剩余",
            secondLabel: "下次刷新",
            icon: Self.providerIcon("kimi-icon")
        )
        self.kimiCard = kimiCard
        kimiMonthlyValue = kimiCard.firstValue
        kimiRefreshValue = kimiCard.secondValue

        let metrics = NSStackView(views: [codexCard, deepSeekCard, kimiCard])
        metrics.orientation = .vertical
        metrics.alignment = .leading
        metrics.distribution = .fill
        metrics.spacing = 8
        codexCard.widthAnchor.constraint(equalTo: metrics.widthAnchor).isActive = true
        deepSeekCard.widthAnchor.constraint(equalTo: metrics.widthAnchor).isActive = true
        kimiCard.widthAnchor.constraint(equalTo: metrics.widthAnchor).isActive = true
        codexCard.heightAnchor.constraint(equalToConstant: 76).isActive = true
        deepSeekCard.heightAnchor.constraint(equalToConstant: 76).isActive = true
        kimiCard.heightAnchor.constraint(equalToConstant: 76).isActive = true

        tokenValue = Self.label("今日 Token 合计  —", size: 11, weight: .medium, color: .white)
        updatedValue = Self.label("等待数据", size: 10, weight: .regular, color: .white.withAlphaComponent(0.68))
        updatedValue.alignment = .right
        let expandedRefreshButton = Self.button(
            symbol: "arrow.clockwise", fallback: "↻", accessibilityLabel: "刷新用量"
        )
        let footer = NSStackView(views: [tokenValue, NSView(), updatedValue, expandedRefreshButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.distribution = .fill
        footer.spacing = 8
        tokenValue.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        updatedValue.setContentHuggingPriority(.required, for: .horizontal)
        expandedRefreshButton.setContentHuggingPriority(.required, for: .horizontal)
        expandedRefreshButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        expandedRefreshButton.heightAnchor.constraint(equalToConstant: 24).isActive = true

        expandedStack = NSStackView(views: [header, metrics, footer])
        expandedStack.orientation = .vertical
        expandedStack.alignment = .leading
        expandedStack.distribution = .fill
        expandedStack.spacing = 8

        for view in [header, metrics, footer] {
            view.widthAnchor.constraint(equalTo: expandedStack.widthAnchor).isActive = true
        }
        header.heightAnchor.constraint(equalToConstant: 24).isActive = true
        expandedMetricsHeightConstraint = metrics.heightAnchor.constraint(equalToConstant: 160)
        expandedMetricsHeightConstraint.isActive = true
        footer.heightAnchor.constraint(equalToConstant: 16).isActive = true

        root.addSubview(compactStack)
        root.addSubview(expandedStack)
        tint.translatesAutoresizingMaskIntoConstraints = false
        compactStack.translatesAutoresizingMaskIntoConstraints = false
        expandedStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tint.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tint.topAnchor.constraint(equalTo: root.topAnchor),
            tint.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            compactStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            compactStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            expandedStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            expandedStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12)
        ])
        compactLayoutConstraints = [
            compactStack.topAnchor.constraint(equalTo: root.topAnchor, constant: 9),
            compactStack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -9)
        ]
        expandedLayoutConstraints = [
            expandedStack.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            expandedStack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10)
        ]

        let hudPanel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.collapsedSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        hudPanel.contentView = root
        hudPanel.contentMinSize = NSSize(width: Self.panelWidth, height: Self.collapsedHeight)
        hudPanel.contentMaxSize = NSSize(width: Self.panelWidth, height: expandedHeight)
        hudPanel.isOpaque = false
        hudPanel.backgroundColor = .clear
        hudPanel.hasShadow = true
        hudPanel.level = .floating
        hudPanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        hudPanel.hidesOnDeactivate = false
        hudPanel.isFloatingPanel = true
        hudPanel.isMovableByWindowBackground = false
        hudPanel.animationBehavior = .utilityWindow
        panel = hudPanel

        compactExpandButton.target = self
        compactExpandButton.action = #selector(toggleExpanded)
        compactRefreshButton.target = self
        compactRefreshButton.action = #selector(refreshUsage)
        expandedRefreshButton.target = self
        expandedRefreshButton.action = #selector(refreshUsage)
        openButton.target = self
        openButton.action = #selector(openMainApp)
        collapseButton.target = self
        collapseButton.action = #selector(toggleExpanded)
        closeButton.target = self
        closeButton.action = #selector(closeHUD)
        root.onMoveFinished = { [weak self] point in self?.finishHUDDrag(at: point) }
        root.onDoubleClick = { [weak self] in self?.openMainApp() }

        isExpanded = defaults.bool(forKey: "hud.expanded")
        enabled = defaults.object(forKey: "hud.enabled") as? Bool ?? true
        if let savedDisplayID = defaults.object(forKey: "hud.displayID") as? NSNumber {
            selectedDisplayID = savedDisplayID.uint32Value
        }
        anchor = loadAnchor()
        setToolAvailability(availableTools)
        updateLayout()
        if enabled && availableTools.hasAny { panel.orderFrontRegardless() }

        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.repositionAfterScreenChange() }
        }
    }

    deinit {
        if let screenChangeObserver {
            NotificationCenter.default.removeObserver(screenChangeObserver)
        }
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        defaults.set(value, forKey: "hud.enabled")
        if value && hasVisibleProvider {
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
        onStateChange?()
    }

    func isEnabled() -> Bool { enabled }
    func isVisible() -> Bool { panel.isVisible }

    func availableDisplays() -> [[String: Any]] {
        NSScreen.screens.map { screen in
            let displayID = displayID(for: screen)
            let isMain = displayID == CGMainDisplayID()
            let name = screen.localizedName.isEmpty ? "显示器" : screen.localizedName
            let dimensions = "\(Int(screen.frame.width)) × \(Int(screen.frame.height))"
            return [
                "id": displayID.map(String.init) ?? "",
                "label": "\(name) · \(dimensions)\(isMain ? "（主显示器）" : "")",
                "selected": displayID == selectedDisplayID
            ]
        }
    }

    func moveToDisplay(_ rawDisplayID: String) {
        guard let displayID = UInt32(rawDisplayID),
              let destination = screen(withDisplayID: displayID),
              displayID != selectedDisplayID else { return }

        let current = screen(
            for: NSRect(origin: anchor, size: Self.collapsedSize),
            preferredDisplayID: selectedDisplayID
        ) ?? NSScreen.main ?? destination
        let (x, y) = normalizedPosition(of: anchor, on: current)
        selectedDisplayID = displayID
        anchor = origin(forNormalizedX: x, y: y, on: destination)
        updateLayout()
        onStateChange?()
    }

    func setUsageAlertThreshold(_ value: Int) {
        usageAlertThresholdPercent = min(100, max(0, value))
        updateUsageAlertColors()
    }

    func setKimiMonthlyAlertThreshold(_ value: Int) {
        kimiMonthlyAlertThresholdPercent = min(100, max(0, value))
        updateUsageAlertColors()
    }

    func setDeepSeekBalanceAlert(threshold: Double, currency: String) {
        deepSeekBalanceAlertThreshold = max(0, threshold)
        deepSeekBalanceAlertCurrency = currency == "USD" ? "USD" : "CNY"
        updateDeepSeekBalanceValues()
        updateUsageAlertColors()
    }

    func setProviderVisibility(_ visibility: [String: Bool]) {
        providerVisibility = visibility
        applyProviderVisibility()
    }

    func setToolAvailability(_ availability: ToolAvailability) {
        currentAvailability = availability
        applyProviderVisibility()
    }

    private var hasVisibleProvider: Bool {
        guard let availability = currentAvailability else { return false }
        return (availability.codex && providerVisibility["codex"] != false)
            || (availability.deepSeek && providerVisibility["deepseek"] != false)
            || (availability.kimi && providerVisibility["kimi"] != false)
    }

    private func applyProviderVisibility() {
        guard let availability = currentAvailability else { return }
        let showCodex = availability.codex && providerVisibility["codex"] != false
        let showDeepSeek = availability.deepSeek && providerVisibility["deepseek"] != false
        let showKimi = availability.kimi && providerVisibility["kimi"] != false
        compactCodexMetric.isHidden = !showCodex
        compactDeepSeekMetric.isHidden = !showDeepSeek
        compactKimiMetric.isHidden = !showKimi
        codexCard.isHidden = !showCodex
        deepSeekCard.isHidden = !showDeepSeek
        kimiCard.isHidden = !showKimi

        let visibleMetricCount = [showCodex, showDeepSeek, showKimi].filter { $0 }.count
        expandedMetricsHeightConstraint.constant = CGFloat(visibleMetricCount * 76)
            + CGFloat(max(0, visibleMetricCount - 1) * 8)
        expandedHeight = max(Self.collapsedHeight, 76 + expandedMetricsHeightConstraint.constant)
        panel.contentMaxSize = NSSize(width: Self.panelWidth, height: expandedHeight)

        if !hasVisibleProvider { panel.orderOut(nil) }
        updateLayout()
        if enabled && hasVisibleProvider { panel.orderFrontRegardless() }
    }

    func render(_ snapshot: [String: Any]) {
        let codex = snapshot["codex"] as? [String: Any] ?? [:]
        let deepseek = snapshot["deepseek"] as? [String: Any] ?? [:]
        let kimi = snapshot["kimi"] as? [String: Any] ?? [:]
        let codexPrimary = codex["primary"] as? [String: Any] ?? [:]
        let codexWeekly = codex["weekly"] as? [String: Any] ?? [:]
        let primaryRemaining = remainingPercent(codexPrimary["usedPercent"])
        let weeklyRemaining = remainingPercent(codexWeekly["usedPercent"])
        let balances = deepseek["balances"] as? [[String: Any]] ?? []
        let spend = deepseek["officialSpend"] as? [[String: Any]] ?? []
        let cnySpend = spend.first { ($0["currency"] as? String) == "CNY" }?["amount"]
        let hasDeepSeekCredential = deepseek["credentialAvailable"] as? Bool == true
        let kimiAvailable = kimi["available"] as? Bool == true
        let kimiMonthly = kimi["monthly"] as? [String: Any] ?? [:]
        let tokenSources = [codex, deepseek, kimi]
            .compactMap { $0["tokens"] as? [String: Any] }
            .filter { $0["todayAvailable"] as? Bool == true }
        let hasTokenData = !tokenSources.isEmpty
        let todayTokenTotal = tokenSources.reduce(0.0) { total, source in
            total + ((source["todayTokens"] as? NSNumber)?.doubleValue ?? 0)
        }

        let codexAvailable = codex["available"] as? Bool == true
        codexPrimaryRemainingPercent = codexAvailable ? primaryRemaining : nil
        codexWeeklyRemainingPercent = codexAvailable ? weeklyRemaining : nil
        kimiMonthlyRemainingPercent = kimiAvailable ? remainingPercent(kimiMonthly["usedPercent"]) : nil
        deepSeekBalances = balances
        deepSeekCredentialAvailable = hasDeepSeekCredential

        compactCodexValue.stringValue = codexAvailable ? percentText(primaryRemaining) : "—"
        compactKimiValue.stringValue = kimiAvailable
            ? percentText(remainingPercent(kimiMonthly["usedPercent"])) : "—"
        compactUpdatedValue.stringValue = compactUpdatedTime(snapshot["updatedAt"])
        codexCard.firstLabel.stringValue = usageWindowLabel(
            "5 小时剩余", resetAt: codexPrimary["resetAt"]
        )
        codexCard.secondLabel.stringValue = usageWindowLabel(
            "每周剩余", resetAt: codexWeekly["resetAt"]
        )
        codexPrimaryValue.stringValue = codexAvailable ? percentText(primaryRemaining) : "—"
        codexWeeklyValue.stringValue = codexAvailable ? percentText(weeklyRemaining) : "—"
        kimiMonthlyValue.stringValue = kimiAvailable
            ? percentText(remainingPercent(kimiMonthly["usedPercent"])) : "—"
        kimiCard.secondLabel.stringValue = "下次刷新"
        kimiRefreshValue.stringValue = kimiAvailable ? resetTimeText(kimiMonthly["resetAt"]) : "—"
        deepSeekSpendValue.stringValue = hasDeepSeekCredential ? formattedMoney(cnySpend, currency: "CNY") : "—"
        updateDeepSeekBalanceValues()
        updateUsageAlertColors()

        tokenValue.stringValue = hasTokenData
            ? "今日 Token 合计  \(intString(NSNumber(value: todayTokenTotal)))"
            : "今日 Token 合计  —"
        tokenValue.toolTip = "按本机时区统计今天 00:00 至次日 00:00 的 Token 用量，汇总当前可读取的 ChatGPT 与 DeepSeek 会话；Kimi 接口不提供 Token 分项数量。"
        updatedValue.stringValue = updatedTime(snapshot["updatedAt"])
    }

    @objc private func toggleExpanded() {
        isExpanded.toggle()
        defaults.set(isExpanded, forKey: "hud.expanded")
        updateLayout()
    }

    @objc private func closeHUD() {
        setEnabled(false)
    }

    @objc private func refreshUsage() {
        onRefresh?()
    }

    @objc private func openMainApp() {
        onOpenMainApp?()
    }

    private func updateLayout() {
        compactStack.isHidden = isExpanded
        expandedStack.isHidden = !isExpanded
        NSLayoutConstraint.deactivate(isExpanded ? compactLayoutConstraints : expandedLayoutConstraints)
        NSLayoutConstraint.activate(isExpanded ? expandedLayoutConstraints : compactLayoutConstraints)

        let capsuleFrame = NSRect(origin: anchor, size: Self.collapsedSize)
        let targetScreen = screen(for: capsuleFrame, preferredDisplayID: selectedDisplayID)
        let capsule = fit(capsuleFrame, on: targetScreen)
        selectedDisplayID = displayID(for: targetScreen)
        anchor = capsule.origin
        let frame = isExpanded ? expandedFrame(for: capsule) : capsule
        panel.setFrame(frame, display: true, animate: false)
        panel.setContentSize(frame.size)
        panel.setFrameOrigin(frame.origin)
        persistAnchor()
    }

    private func loadAnchor() -> NSPoint {
        let normalizedX = defaults.object(forKey: "hud.positionX") as? Double
        let normalizedY = defaults.object(forKey: "hud.positionY") as? Double
        if let normalizedX, let normalizedY,
           let target = screen(withDisplayID: selectedDisplayID) ?? NSScreen.main ?? NSScreen.screens.first {
            selectedDisplayID = displayID(for: target)
            return origin(forNormalizedX: normalizedX, y: normalizedY, on: target)
        }

        if defaults.object(forKey: "hud.anchorX") != nil,
           defaults.object(forKey: "hud.anchorY") != nil {
            let point = NSPoint(
                x: defaults.double(forKey: "hud.anchorX"),
                y: defaults.double(forKey: "hud.anchorY")
            )
            if point.x.isFinite, point.y.isFinite {
                let frame = NSRect(origin: point, size: Self.collapsedSize)
                let target = screen(for: frame, preferredDisplayID: selectedDisplayID)
                selectedDisplayID = displayID(for: target)
                return fit(frame, on: target).origin
            }
        }

        let target = NSScreen.main ?? NSScreen.screens.first
        selectedDisplayID = displayID(for: target)
        let bounds = target?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 700)
        let initial = NSRect(
            x: bounds.maxX - Self.collapsedSize.width - 22,
            y: bounds.minY + 18,
            width: Self.collapsedSize.width,
            height: Self.collapsedSize.height
        )
        return fit(initial, on: target).origin
    }

    private func finishHUDDrag(at cursor: NSPoint) {
        let oldDisplayID = selectedDisplayID
        let screens = NSScreen.screens
        let target = HUDDragGeometry.screenIndex(
            containing: cursor,
            frames: screens.map(\.frame)
        ).map { screens[$0] }
            ?? screen(for: panel.frame, preferredDisplayID: selectedDisplayID)
        selectedDisplayID = displayID(for: target)
        if isExpanded {
            anchor = NSPoint(
                x: expandsRight ? panel.frame.minX : panel.frame.maxX - Self.collapsedSize.width,
                y: expandsDown ? panel.frame.maxY - Self.collapsedSize.height : panel.frame.minY
            )
        } else {
            anchor = panel.frame.origin
        }
        persistAnchor()
        if oldDisplayID != selectedDisplayID { onStateChange?() }
    }

    private func repositionAfterScreenChange() {
        if let normalizedX = defaults.object(forKey: "hud.positionX") as? Double,
           let normalizedY = defaults.object(forKey: "hud.positionY") as? Double,
           let target = screen(withDisplayID: selectedDisplayID) ?? NSScreen.main ?? NSScreen.screens.first {
            selectedDisplayID = displayID(for: target)
            anchor = origin(forNormalizedX: normalizedX, y: normalizedY, on: target)
        }
        updateLayout()
        onStateChange?()
    }

    private func persistAnchor() {
        defaults.set(anchor.x, forKey: "hud.anchorX")
        defaults.set(anchor.y, forKey: "hud.anchorY")
        guard let target = screen(withDisplayID: selectedDisplayID) else { return }
        defaults.set(selectedDisplayID, forKey: "hud.displayID")
        let (x, y) = normalizedPosition(of: anchor, on: target)
        defaults.set(x, forKey: "hud.positionX")
        defaults.set(y, forKey: "hud.positionY")
    }

    private func fit(_ frame: NSRect, on screen: NSScreen?) -> NSRect {
        let bounds = screen?.frame ?? NSRect(x: 0, y: 0, width: 1000, height: 700)
        let width = min(frame.width, bounds.width)
        let height = min(frame.height, bounds.height)
        return NSRect(
            x: min(max(frame.minX, bounds.minX), bounds.maxX - width),
            y: min(max(frame.minY, bounds.minY), bounds.maxY - height),
            width: width,
            height: height
        )
    }

    private func normalizedPosition(of point: NSPoint, on screen: NSScreen) -> (Double, Double) {
        let bounds = screen.frame
        let width = max(0, bounds.width - Self.collapsedSize.width)
        let height = max(0, bounds.height - Self.collapsedSize.height)
        let x = width == 0 ? 0 : (point.x - bounds.minX) / width
        let y = height == 0 ? 0 : (point.y - bounds.minY) / height
        return (Double(x), Double(y))
    }

    private func origin(forNormalizedX x: Double, y: Double, on screen: NSScreen) -> NSPoint {
        let bounds = screen.frame
        let width = max(0, bounds.width - Self.collapsedSize.width)
        let height = max(0, bounds.height - Self.collapsedSize.height)
        let clampedX = min(1, max(0, x))
        let clampedY = min(1, max(0, y))
        return NSPoint(
            x: bounds.minX + width * clampedX,
            y: bounds.minY + height * clampedY
        )
    }

    private func screen(
        for frame: NSRect,
        preferredDisplayID: UInt32?
    ) -> NSScreen? {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        if let containing = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
            return containing
        }

        let intersections = NSScreen.screens.compactMap { screen -> (NSScreen, CGFloat)? in
            let intersection = frame.intersection(screen.frame)
            guard !intersection.isNull else { return nil }
            return (screen, intersection.width * intersection.height)
        }
        if let maximumArea = intersections.map(\.1).max() {
            if let preferred = intersections.first(where: {
                displayID(for: $0.0) == preferredDisplayID && $0.1 == maximumArea
            })?.0 {
                return preferred
            }
            return intersections.first(where: { $0.1 == maximumArea })?.0
        }
        return screen(withDisplayID: preferredDisplayID) ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func expandedFrame(for capsule: NSRect) -> NSRect {
        let screen = screen(for: capsule, preferredDisplayID: selectedDisplayID)
        let bounds = screen?.frame ?? NSRect(x: 0, y: 0, width: 1000, height: 700)
        let width = min(expandedSize.width, bounds.width)
        let height = min(expandedSize.height, bounds.height)
        let extraWidth = max(0, width - capsule.width)
        let extraHeight = max(0, height - capsule.height)
        let roomRight = bounds.maxX - capsule.maxX
        let roomLeft = capsule.minX - bounds.minX
        let roomDown = capsule.minY - bounds.minY
        let roomUp = bounds.maxY - capsule.maxY

        expandsRight = roomRight >= extraWidth || (roomLeft < extraWidth && roomRight >= roomLeft)
        expandsDown = roomDown >= extraHeight || (roomUp < extraHeight && roomDown >= roomUp)

        let x = expandsRight ? capsule.minX : capsule.maxX - width
        let y = expandsDown ? capsule.minY - extraHeight : capsule.minY
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private func screen(withDisplayID displayID: UInt32?) -> NSScreen? {
        guard let displayID else { return nil }
        return NSScreen.screens.first(where: { self.displayID(for: $0) == displayID })
    }

    private func displayID(for screen: NSScreen?) -> UInt32? {
        guard let screen,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return number.uint32Value
    }

    private func remainingPercent(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        let used = min(100, max(0, number.doubleValue))
        return Int((100 - used).rounded())
    }

    private func percentText(_ value: Int?) -> String {
        guard let value else { return "—" }
        return "\(value)%"
    }

    private func resetTimeText(_ value: Any?) -> String {
        let timestamp: Double?
        if let number = value as? NSNumber {
            timestamp = number.doubleValue
        } else if let string = value as? String, let number = Double(string) {
            timestamp = number
        } else if let string = value as? String {
            if let date = ISO8601DateFormatter().date(from: string) {
                timestamp = date.timeIntervalSince1970 * 1000
            } else {
                timestamp = nil
            }
        } else {
            timestamp = nil
        }
        guard let timestamp, timestamp > 0 else { return "—" }
        let seconds = timestamp > 100_000_000_000 ? timestamp / 1000 : timestamp
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M/d HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: seconds))
    }

    private func usageWindowLabel(_ label: String, resetAt: Any?) -> String {
        let resetTime = resetTimeText(resetAt)
        return resetTime == "—" ? label : "\(label) · 下次刷新 \(resetTime)"
    }

    private func updateUsageAlertColors() {
        let alertColor = NSColor.systemOrange
        compactCodexValue.textColor = isAtOrBelowUsageAlert(codexPrimaryRemainingPercent) ? alertColor : .white
        codexPrimaryValue.textColor = isAtOrBelowUsageAlert(codexPrimaryRemainingPercent) ? alertColor : .white
        codexWeeklyValue.textColor = isAtOrBelowUsageAlert(codexWeeklyRemainingPercent) ? alertColor : .white
        let deepSeekColor = deepSeekBalanceAlertActive ? alertColor : .white
        compactDeepSeekValue.textColor = deepSeekColor
        deepSeekBalanceValue.textColor = deepSeekColor
        let kimiMonthlyAlert = kimiMonthlyRemainingPercent.map {
            $0 <= kimiMonthlyAlertThresholdPercent
        } == true
        kimiMonthlyValue.textColor = kimiMonthlyAlert ? alertColor : .white
        compactKimiValue.textColor = kimiMonthlyAlert ? alertColor : .white
    }

    private func isAtOrBelowUsageAlert(_ remainingPercent: Int?) -> Bool {
        guard let remainingPercent else { return false }
        return remainingPercent <= usageAlertThresholdPercent
    }

    private func updateDeepSeekBalanceValues() {
        let amount = deepSeekBalances.first {
            ($0["currency"] as? String) == deepSeekBalanceAlertCurrency
        }?["amount"]
        let amountValue = numericAmount(amount)
        deepSeekBalanceAlertActive = deepSeekCredentialAvailable
            && amountValue.map { $0 <= deepSeekBalanceAlertThreshold } == true
        let formatted = formattedMoney(amount, currency: deepSeekBalanceAlertCurrency)
        compactDeepSeekValue.stringValue = deepSeekCredentialAvailable ? formatted : "—"
        deepSeekBalanceValue.stringValue = deepSeekCredentialAvailable ? formatted : "—"
    }

    private func numericAmount(_ value: Any?) -> Double? {
        let amount: Double?
        if let string = value as? String {
            amount = Double(string)
        } else if let number = value as? NSNumber {
            amount = number.doubleValue
        } else {
            amount = nil
        }
        guard let amount, amount.isFinite else { return nil }
        return amount
    }

    private func formattedMoney(_ value: Any?, currency: String) -> String {
        let raw: String
        if let string = value as? String {
            raw = string
        } else if let number = value as? NSNumber {
            raw = number.stringValue
        } else {
            return "—"
        }
        guard var decimal = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")) else {
            return "—"
        }
        var rounded = Decimal()
        NSDecimalRound(&rounded, &decimal, 2, .plain)
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        guard let formatted = formatter.string(from: NSDecimalNumber(decimal: rounded)) else {
            return "—"
        }
        let symbol = currency == "USD" ? "$" : "¥"
        return "\(symbol)\(formatted)"
    }

    private func intString(_ value: Any?) -> String {
        guard let number = value as? NSNumber else { return "0" }
        return NumberFormatter.localizedString(from: number, number: .decimal)
    }

    private func updatedTime(_ value: Any?) -> String {
        guard let raw = value as? String else { return "等待数据" }
        let iso = ISO8601DateFormatter()
        guard let date = iso.date(from: raw) else { return "等待数据" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return "更新于 \(formatter.string(from: date))"
    }

    private func compactUpdatedTime(_ value: Any?) -> String {
        guard let raw = value as? String else { return "等待数据" }
        let iso = ISO8601DateFormatter()
        guard let date = iso.date(from: raw) else { return "等待数据" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    fileprivate static func label(
        _ text: String,
        size: CGFloat,
        weight: NSFont.Weight,
        color: NSColor
    ) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    fileprivate static func providerIcon(_ name: String) -> NSImage? {
        guard let url = Bundle.main.url(
            forResource: name,
            withExtension: "png",
            subdirectory: "Resources"
        ) else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

    private static func verticalStack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = spacing
        return stack
    }

    private static func brandIcon() -> NSView {
        let view = NSImageView(frame: .zero)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.image = providerIcon("app-icon")
        view.imageScaling = .scaleProportionallyUpOrDown
        view.setAccessibilityLabel("用量监控 App 图标")
        view.wantsLayer = true
        view.layer?.cornerRadius = 7
        view.layer?.masksToBounds = true
        view.widthAnchor.constraint(equalToConstant: 24).isActive = true
        view.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return view
    }

    private static func divider(vertical: Bool) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.19).cgColor
        if vertical {
            view.widthAnchor.constraint(equalToConstant: 1).isActive = true
            view.heightAnchor.constraint(equalToConstant: 30).isActive = true
        } else {
            view.heightAnchor.constraint(equalToConstant: 1).isActive = true
        }
        return view
    }

    private static func button(
        symbol: String,
        fallback: String,
        accessibilityLabel: String
    ) -> NSButton {
        let button = NSButton(title: fallback, target: nil, action: nil)
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibilityLabel) {
            button.image = image
            button.imagePosition = .imageOnly
        }
        button.bezelStyle = .rounded
        button.isBordered = true
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11, weight: .semibold)
        button.contentTintColor = .white
        button.setButtonType(.momentaryPushIn)
        button.toolTip = accessibilityLabel
        button.setAccessibilityLabel(accessibilityLabel)
        return button
    }
}

@MainActor
private final class HUDCompactMetric: NSView {
    init(value: NSTextField, icon: NSImage?) {
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.075).cgColor
        layer?.cornerRadius = 9
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        value.alignment = .right
        value.font = .systemFont(ofSize: 12, weight: .semibold)
        let iconView = NSImageView(frame: .zero)
        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.isHidden = icon == nil

        for subview in [iconView, value] {
            addSubview(subview)
            subview.translatesAutoresizingMaskIntoConstraints = false
        }
        value.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),
            value.leadingAnchor.constraint(greaterThanOrEqualTo: iconView.trailingAnchor, constant: 5),
            value.centerYAnchor.constraint(equalTo: centerYAnchor),
            value.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
private final class HUDMetricCard: NSView {
    let firstValue: NSTextField
    let secondValue: NSTextField
    let firstLabel: NSTextField
    let secondLabel: NSTextField

    init(title: String, firstLabel: String, secondLabel: String, icon: NSImage?) {
        let titleField = HUDController.label(title, size: 10, weight: .semibold, color: .white)
        let iconView = NSImageView(frame: .zero)
        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.isHidden = icon == nil
        let firstLabelField = HUDController.label(firstLabel, size: 10, weight: .regular, color: .white.withAlphaComponent(0.70))
        self.firstLabel = firstLabelField
        self.secondLabel = HUDController.label(secondLabel, size: 10, weight: .regular, color: .white.withAlphaComponent(0.70))
        firstValue = HUDController.label("—", size: 12, weight: .semibold, color: .white)
        secondValue = HUDController.label("—", size: 12, weight: .semibold, color: .white)
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.075).cgColor
        layer?.cornerRadius = 11
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor

        for view in [iconView, titleField, firstLabelField, firstValue, self.secondLabel, secondValue] {
            addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        firstValue.alignment = .right
        secondValue.alignment = .right
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            iconView.centerYAnchor.constraint(equalTo: titleField.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            titleField.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -9),

            firstLabelField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            firstLabelField.centerYAnchor.constraint(equalTo: firstValue.centerYAnchor),
            firstValue.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 8),
            firstValue.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11),
            firstLabelField.trailingAnchor.constraint(lessThanOrEqualTo: firstValue.leadingAnchor, constant: -5),

            self.secondLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            self.secondLabel.centerYAnchor.constraint(equalTo: secondValue.centerYAnchor),
            secondValue.topAnchor.constraint(equalTo: firstValue.bottomAnchor, constant: 4),
            secondValue.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11),
            self.secondLabel.trailingAnchor.constraint(lessThanOrEqualTo: secondValue.leadingAnchor, constant: -5)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
private final class MovableHUDView: NSVisualEffectView {
    var onMoveFinished: ((NSPoint) -> Void)?
    var onDoubleClick: (() -> Void)?
    private var mouseDownOffset: NSPoint?
    private var mouseDownScreenPoint: NSPoint?
    private var dragDistance: CGFloat = 0

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit is NSButton { return hit }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let pointer = window.convertPoint(toScreen: event.locationInWindow)
        mouseDownOffset = NSPoint(
            x: pointer.x - window.frame.minX,
            y: pointer.y - window.frame.minY
        )
        mouseDownScreenPoint = pointer
        dragDistance = 0
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let mouseDownOffset, let mouseDownScreenPoint else { return }
        let current = NSEvent.mouseLocation
        dragDistance = max(dragDistance, hypot(
            current.x - mouseDownScreenPoint.x,
            current.y - mouseDownScreenPoint.y
        ))
        window.setFrameOrigin(HUDDragGeometry.windowOrigin(at: current, mouseDownOffset: mouseDownOffset))
    }

    override func mouseUp(with event: NSEvent) {
        if let window, let mouseDownOffset {
            let current = NSEvent.mouseLocation
            window.setFrameOrigin(HUDDragGeometry.windowOrigin(at: current, mouseDownOffset: mouseDownOffset))
            onMoveFinished?(current)
        }
        if event.clickCount == 2, dragDistance < 4 {
            onDoubleClick?()
        }
        mouseDownOffset = nil
        mouseDownScreenPoint = nil
    }
}
