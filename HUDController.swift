import AppKit
import Foundation

@MainActor
final class HUDController {
    var onStateChange: (() -> Void)?
    var onOpenMainApp: (() -> Void)?

    private let defaults = UserDefaults.standard
    private let panel: NSPanel
    private let rootView: MovableHUDView
    private let compactStack: NSStackView
    private let expandedStack: NSStackView
    private let compactCodexMetric: NSView
    private let compactDeepSeekMetric: NSView
    private let codexCard: HUDMetricCard
    private let deepSeekCard: HUDMetricCard
    private var expandedMetricsHeightConstraint: NSLayoutConstraint!
    private let compactCodexValue: NSTextField
    private let compactDeepSeekValue: NSTextField
    private let compactUpdatedValue: NSTextField
    private let codexPrimaryValue: NSTextField
    private let codexWeeklyValue: NSTextField
    private let deepSeekBalanceValue: NSTextField
    private let deepSeekSpendValue: NSTextField
    private let tokenValue: NSTextField
    private let updatedValue: NSTextField
    private var anchor = NSPoint.zero
    private var isExpanded = false
    private var enabled = false
    private var expandsRight = true
    private var expandsDown = false
    private var usageAlertThresholdPercent = 20
    private var codexPrimaryRemainingPercent: Int?
    private var codexWeeklyRemainingPercent: Int?
    private var deepSeekBalanceAlertThreshold = 10.0
    private var deepSeekBalanceAlertCurrency = "CNY"
    private var deepSeekBalances: [[String: Any]] = []
    private var deepSeekIsSignedIn = false
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

    init() {
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
        compactCodexValue = compactCodex
        compactDeepSeekValue = compactDeepSeek

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
        let compactHeader = NSStackView(views: [
            compactBrand, NSView(), compactTime, compactExpandButton
        ])
        compactHeader.orientation = .horizontal
        compactHeader.alignment = .centerY
        compactHeader.distribution = .fill
        compactHeader.spacing = 8
        compactBrand.setContentHuggingPriority(.required, for: .horizontal)
        compactTime.setContentHuggingPriority(.required, for: .horizontal)
        compactExpandButton.setContentHuggingPriority(.required, for: .horizontal)
        compactExpandButton.widthAnchor.constraint(equalToConstant: 26).isActive = true
        compactExpandButton.heightAnchor.constraint(equalToConstant: 26).isActive = true

        let compactCodexMetric = HUDCompactMetric(title: "Codex · 5 小时剩余", value: compactCodex)
        let compactDeepSeekMetric = HUDCompactMetric(title: "DeepSeek 余额", value: compactDeepSeek)
        self.compactCodexMetric = compactCodexMetric
        self.compactDeepSeekMetric = compactDeepSeekMetric
        let compactMetrics = NSStackView(views: [compactCodexMetric, compactDeepSeekMetric])
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

        let headerTitle = Self.label("用量监控", size: 13, weight: .semibold, color: .white)
        let openButton = Self.button(
            symbol: "macwindow", fallback: "窗口", accessibilityLabel: "打开主窗口"
        )
        let collapseButton = Self.button(
            symbol: "chevron.down", fallback: "⌄", accessibilityLabel: "折叠用量监控"
        )
        let closeButton = Self.button(
            symbol: "xmark", fallback: "×", accessibilityLabel: "关闭 HUD"
        )
        let header = NSStackView(views: [headerTitle, NSView(), openButton, collapseButton, closeButton])
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
            title: "Codex",
            firstLabel: "5 小时剩余",
            secondLabel: "每周剩余"
        )
        self.codexCard = codexCard
        codexPrimaryValue = codexCard.firstValue
        codexWeeklyValue = codexCard.secondValue
        let deepSeekCard = HUDMetricCard(
            title: "DeepSeek",
            firstLabel: "账户余额 · 官方",
            secondLabel: "累计消费 · 官方"
        )
        self.deepSeekCard = deepSeekCard
        deepSeekBalanceValue = deepSeekCard.firstValue
        deepSeekSpendValue = deepSeekCard.secondValue

        let metrics = NSStackView(views: [codexCard, deepSeekCard])
        metrics.orientation = .vertical
        metrics.alignment = .leading
        metrics.distribution = .fill
        metrics.spacing = 8
        codexCard.widthAnchor.constraint(equalTo: metrics.widthAnchor).isActive = true
        deepSeekCard.widthAnchor.constraint(equalTo: metrics.widthAnchor).isActive = true
        codexCard.heightAnchor.constraint(equalToConstant: 76).isActive = true
        deepSeekCard.heightAnchor.constraint(equalToConstant: 76).isActive = true

        tokenValue = Self.label("Token 合计  —", size: 11, weight: .medium, color: .white)
        updatedValue = Self.label("等待数据", size: 10, weight: .regular, color: .white.withAlphaComponent(0.68))
        updatedValue.alignment = .right
        let footer = NSStackView(views: [tokenValue, NSView(), updatedValue])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.distribution = .fill
        footer.spacing = 8
        tokenValue.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        updatedValue.setContentHuggingPriority(.required, for: .horizontal)

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
        openButton.target = self
        openButton.action = #selector(openMainApp)
        collapseButton.target = self
        collapseButton.action = #selector(toggleExpanded)
        closeButton.target = self
        closeButton.action = #selector(closeHUD)
        root.onMove = { [weak self] in self?.rememberAnchor() }
        root.onDoubleClick = { [weak self] in self?.openMainApp() }

        isExpanded = defaults.bool(forKey: "hud.expanded")
        enabled = defaults.object(forKey: "hud.enabled") as? Bool ?? true
        anchor = loadAnchor()
        updateLayout()
        if enabled { panel.orderFrontRegardless() }

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
        if value {
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
        onStateChange?()
    }

    func isEnabled() -> Bool { enabled }
    func isVisible() -> Bool { panel.isVisible }

    func setUsageAlertThreshold(_ value: Int) {
        usageAlertThresholdPercent = min(100, max(0, value))
        updateUsageAlertColors()
    }

    func setDeepSeekBalanceAlert(threshold: Double, currency: String) {
        deepSeekBalanceAlertThreshold = max(0, threshold)
        deepSeekBalanceAlertCurrency = currency == "USD" ? "USD" : "CNY"
        updateDeepSeekBalanceValues()
        updateUsageAlertColors()
    }

    func setToolAvailability(_ availability: ToolAvailability) {
        compactCodexMetric.isHidden = !availability.codex
        compactDeepSeekMetric.isHidden = !availability.deepSeek
        codexCard.isHidden = !availability.codex
        deepSeekCard.isHidden = !availability.deepSeek

        let visibleMetricCount = (availability.codex ? 1 : 0) + (availability.deepSeek ? 1 : 0)
        expandedMetricsHeightConstraint.constant = CGFloat(visibleMetricCount * 76)
            + CGFloat(max(0, visibleMetricCount - 1) * 8)
        expandedHeight = 76 + expandedMetricsHeightConstraint.constant
        panel.contentMaxSize = NSSize(width: Self.panelWidth, height: expandedHeight)

        if !availability.hasAny {
            isExpanded = false
            defaults.set(false, forKey: "hud.expanded")
            setEnabled(false)
        }
        updateLayout()
        if enabled { panel.orderFrontRegardless() }
    }

    func render(_ snapshot: [String: Any]) {
        let codex = snapshot["codex"] as? [String: Any] ?? [:]
        let deepseek = snapshot["deepseek"] as? [String: Any] ?? [:]
        let codexPrimary = codex["primary"] as? [String: Any] ?? [:]
        let codexWeekly = codex["weekly"] as? [String: Any] ?? [:]
        let primaryRemaining = remainingPercent(codexPrimary["usedPercent"])
        let weeklyRemaining = remainingPercent(codexWeekly["usedPercent"])
        let balances = deepseek["balances"] as? [[String: Any]] ?? []
        let spend = deepseek["officialSpend"] as? [[String: Any]] ?? []
        let cnySpend = spend.first { ($0["currency"] as? String) == "CNY" }?["amount"]
        let tokens = deepseek["tokens"] as? [String: Any] ?? [:]
        let signedIn = deepseek["signedIn"] as? Bool == true

        let codexAvailable = codex["available"] as? Bool == true
        codexPrimaryRemainingPercent = codexAvailable ? primaryRemaining : nil
        codexWeeklyRemainingPercent = codexAvailable ? weeklyRemaining : nil
        deepSeekBalances = balances
        deepSeekIsSignedIn = signedIn

        compactCodexValue.stringValue = codexAvailable ? percentText(primaryRemaining) : "—"
        compactUpdatedValue.stringValue = compactUpdatedTime(snapshot["updatedAt"])
        codexPrimaryValue.stringValue = codexAvailable ? percentText(primaryRemaining) : "—"
        codexWeeklyValue.stringValue = codexAvailable ? percentText(weeklyRemaining) : "—"
        deepSeekSpendValue.stringValue = signedIn ? formattedMoney(cnySpend, currency: "CNY") : "—"
        updateDeepSeekBalanceValues()
        updateUsageAlertColors()

        tokenValue.stringValue = tokens["available"] as? Bool == true
            ? "Token 合计  \(intString(tokens["totalTokens"]))"
            : "本机暂无 Token 记录"
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

    @objc private func openMainApp() {
        onOpenMainApp?()
    }

    private func updateLayout() {
        compactStack.isHidden = isExpanded
        expandedStack.isHidden = !isExpanded
        NSLayoutConstraint.deactivate(isExpanded ? compactLayoutConstraints : expandedLayoutConstraints)
        NSLayoutConstraint.activate(isExpanded ? expandedLayoutConstraints : compactLayoutConstraints)

        let capsule = fit(NSRect(origin: anchor, size: Self.collapsedSize))
        anchor = capsule.origin
        let frame = isExpanded ? expandedFrame(for: capsule) : capsule
        panel.setFrame(frame, display: true, animate: false)
        panel.setContentSize(frame.size)
        panel.setFrameOrigin(frame.origin)
        persistAnchor()
    }

    private func loadAnchor() -> NSPoint {
        if defaults.object(forKey: "hud.anchorX") != nil,
           defaults.object(forKey: "hud.anchorY") != nil {
            let point = NSPoint(
                x: defaults.double(forKey: "hud.anchorX"),
                y: defaults.double(forKey: "hud.anchorY")
            )
            if point.x.isFinite, point.y.isFinite { return point }
        }
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 700)
        return NSPoint(x: visible.maxX - Self.collapsedSize.width - 22, y: visible.minY + 18)
    }

    private func rememberAnchor() {
        let fitted = fit(panel.frame)
        panel.setFrameOrigin(fitted.origin)
        if isExpanded {
            anchor = NSPoint(
                x: expandsRight ? fitted.minX : fitted.maxX - Self.collapsedSize.width,
                y: expandsDown ? fitted.maxY - Self.collapsedSize.height : fitted.minY
            )
        } else {
            anchor = fitted.origin
        }
        persistAnchor()
    }

    private func repositionAfterScreenChange() {
        let fittedCapsule = fit(NSRect(origin: anchor, size: Self.collapsedSize))
        anchor = fittedCapsule.origin
        updateLayout()
    }

    private func persistAnchor() {
        defaults.set(anchor.x, forKey: "hud.anchorX")
        defaults.set(anchor.y, forKey: "hud.anchorY")
    }

    private func fit(_ frame: NSRect) -> NSRect {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        let screen = screen(containing: center, fallbackFrame: frame)
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 700)
        let width = min(frame.width, visible.width)
        let height = min(frame.height, visible.height)
        return NSRect(
            x: min(max(frame.minX, visible.minX), visible.maxX - width),
            y: min(max(frame.minY, visible.minY), visible.maxY - height),
            width: width,
            height: height
        )
    }

    private func expandedFrame(for capsule: NSRect) -> NSRect {
        let screen = screen(
            containing: NSPoint(x: capsule.midX, y: capsule.midY),
            fallbackFrame: capsule
        )
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 700)
        let width = min(expandedSize.width, visible.width)
        let height = min(expandedSize.height, visible.height)
        let extraWidth = max(0, width - capsule.width)
        let extraHeight = max(0, height - capsule.height)
        let roomRight = visible.maxX - capsule.maxX
        let roomLeft = capsule.minX - visible.minX
        let roomDown = capsule.minY - visible.minY
        let roomUp = visible.maxY - capsule.maxY

        expandsRight = roomRight >= extraWidth || (roomLeft < extraWidth && roomRight >= roomLeft)
        expandsDown = roomDown >= extraHeight || (roomUp < extraHeight && roomDown >= roomUp)

        let x = expandsRight ? capsule.minX : capsule.maxX - width
        let y = expandsDown ? capsule.minY - extraHeight : capsule.minY
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private func screen(containing point: NSPoint, fallbackFrame: NSRect) -> NSScreen? {
        NSScreen.screens.first(where: { $0.frame.contains(point) })
            ?? NSScreen.screens.first(where: { $0.frame.intersects(fallbackFrame) })
            ?? NSScreen.main
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

    private func updateUsageAlertColors() {
        let alertColor = NSColor.systemOrange
        compactCodexValue.textColor = isAtOrBelowUsageAlert(codexPrimaryRemainingPercent) ? alertColor : .white
        codexPrimaryValue.textColor = isAtOrBelowUsageAlert(codexPrimaryRemainingPercent) ? alertColor : .white
        codexWeeklyValue.textColor = isAtOrBelowUsageAlert(codexWeeklyRemainingPercent) ? alertColor : .white
        let deepSeekColor = deepSeekBalanceAlertActive ? alertColor : .white
        compactDeepSeekValue.textColor = deepSeekColor
        deepSeekBalanceValue.textColor = deepSeekColor
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
        deepSeekBalanceAlertActive = deepSeekIsSignedIn
            && amountValue.map { $0 <= deepSeekBalanceAlertThreshold } == true
        let formatted = formattedMoney(amount, currency: deepSeekBalanceAlertCurrency)
        compactDeepSeekValue.stringValue = deepSeekIsSignedIn ? formatted : "未登录"
        deepSeekBalanceValue.stringValue = deepSeekIsSignedIn ? formatted : "—"
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

    private static func verticalStack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = spacing
        return stack
    }

    private static func brandIcon() -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(calibratedRed: 0.39, green: 0.48, blue: 0.92, alpha: 0.95).cgColor
        view.layer?.cornerRadius = 7
        let letter = label("A", size: 11, weight: .bold, color: .white)
        letter.alignment = .center
        view.addSubview(letter)
        letter.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 24),
            view.heightAnchor.constraint(equalToConstant: 24),
            letter.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            letter.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
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
    init(title: String, value: NSTextField) {
        let titleField = HUDController.label(
            title,
            size: 10,
            weight: .medium,
            color: .white.withAlphaComponent(0.72)
        )
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.075).cgColor
        layer?.cornerRadius = 9
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        value.alignment = .right
        value.font = .systemFont(ofSize: 12, weight: .semibold)

        for subview in [titleField, value] {
            addSubview(subview)
            subview.translatesAutoresizingMaskIntoConstraints = false
        }
        value.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: value.leadingAnchor, constant: -5),
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

    init(title: String, firstLabel: String, secondLabel: String) {
        let titleField = HUDController.label(title, size: 10, weight: .semibold, color: .white)
        let firstLabelField = HUDController.label(firstLabel, size: 10, weight: .regular, color: .white.withAlphaComponent(0.70))
        let secondLabelField = HUDController.label(secondLabel, size: 10, weight: .regular, color: .white.withAlphaComponent(0.70))
        firstValue = HUDController.label("—", size: 12, weight: .semibold, color: .white)
        secondValue = HUDController.label("—", size: 12, weight: .semibold, color: .white)
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.075).cgColor
        layer?.cornerRadius = 11
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor

        for view in [titleField, firstLabelField, firstValue, secondLabelField, secondValue] {
            addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        firstValue.alignment = .right
        secondValue.alignment = .right
        NSLayoutConstraint.activate([
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            titleField.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -9),

            firstLabelField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            firstLabelField.centerYAnchor.constraint(equalTo: firstValue.centerYAnchor),
            firstValue.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 8),
            firstValue.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11),
            firstLabelField.trailingAnchor.constraint(lessThanOrEqualTo: firstValue.leadingAnchor, constant: -5),

            secondLabelField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            secondLabelField.centerYAnchor.constraint(equalTo: secondValue.centerYAnchor),
            secondValue.topAnchor.constraint(equalTo: firstValue.bottomAnchor, constant: 4),
            secondValue.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11),
            secondLabelField.trailingAnchor.constraint(lessThanOrEqualTo: secondValue.leadingAnchor, constant: -5)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
private final class MovableHUDView: NSVisualEffectView {
    var onMove: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    private var previousScreenPoint: NSPoint?
    private var dragDistance: CGFloat = 0

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit is NSButton { return hit }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        previousScreenPoint = window?.convertPoint(toScreen: event.locationInWindow)
        dragDistance = 0
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let previousScreenPoint else { return }
        let current = window.convertPoint(toScreen: event.locationInWindow)
        let delta = NSPoint(x: current.x - previousScreenPoint.x, y: current.y - previousScreenPoint.y)
        dragDistance += hypot(delta.x, delta.y)
        window.setFrameOrigin(NSPoint(
            x: window.frame.minX + delta.x,
            y: window.frame.minY + delta.y
        ))
        self.previousScreenPoint = current
        onMove?()
    }

    override func mouseUp(with event: NSEvent) {
        if event.clickCount == 2, dragDistance < 4 {
            onDoubleClick?()
        }
        previousScreenPoint = nil
    }
}
