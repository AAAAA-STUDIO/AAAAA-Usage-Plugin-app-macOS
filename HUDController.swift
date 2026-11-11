import AppKit
import Foundation

@MainActor
final class HUDController {
    private let defaults = UserDefaults.standard
    private let panel: NSPanel
    private let rootView: MovableHUDView
    private let compactStack: NSStackView
    private let expandedStack: NSStackView
    private let compactCodex: NSTextField
    private let compactDeepSeek: NSTextField
    private let codexValue: NSTextField
    private let deepSeekValue: NSTextField
    private let tokenValue: NSTextField
    private var anchor = NSPoint.zero
    private var isExpanded = false
    private var enabled = false
    private var expandedFromTop = true
    private var expandedFromLeft = true

    private let collapsedSize = NSSize(width: 356, height: 56)
    private let expandedSize = NSSize(width: 440, height: 154)

    init() {
        rootView = MovableHUDView(frame: NSRect(origin: .zero, size: collapsedSize))
        rootView.material = .hudWindow
        rootView.blendingMode = .behindWindow
        rootView.state = .active
        rootView.wantsLayer = true
        rootView.layer?.cornerRadius = 17
        rootView.layer?.masksToBounds = true

        compactCodex = Self.label("CODEX  —", size: 11, color: .white)
        compactDeepSeek = Self.label("DEEPSEEK  —", size: 11, color: .white)
        compactStack = NSStackView()
        compactStack.orientation = .horizontal
        compactStack.alignment = .centerY
        compactStack.distribution = .fill
        compactStack.spacing = 11
        compactStack.edgeInsets = NSEdgeInsets(top: 0, left: 13, bottom: 0, right: 10)
        compactStack.addArrangedSubview(Self.label("◈  AAAAA", size: 11, color: .white))
        compactStack.addArrangedSubview(compactCodex)
        compactStack.addArrangedSubview(compactDeepSeek)
        compactStack.addArrangedSubview(Self.button("⌃", target: nil, action: nil))

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.distribution = .fill
        header.spacing = 8
        let title = Self.label("用量监控", size: 13, color: .white)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        header.addArrangedSubview(title)
        header.addArrangedSubview(NSView())
        header.addArrangedSubview(Self.button("⌄", target: nil, action: nil))
        header.addArrangedSubview(Self.button("×", target: nil, action: nil))

        codexValue = Self.label("Codex  —", size: 12, color: .white)
        deepSeekValue = Self.label("DeepSeek  —", size: 12, color: .white)
        tokenValue = Self.label("Token 合计  —", size: 11, color: .secondaryLabelColor)
        let values = NSStackView(views: [codexValue, deepSeekValue])
        values.orientation = .horizontal
        values.alignment = .top
        values.distribution = .fillEqually
        values.spacing = 12

        expandedStack = NSStackView(views: [header, values, tokenValue])
        expandedStack.orientation = .vertical
        expandedStack.alignment = .leading
        expandedStack.distribution = .fill
        expandedStack.spacing = 12
        expandedStack.edgeInsets = NSEdgeInsets(top: 11, left: 13, bottom: 11, right: 13)

        rootView.addSubview(compactStack)
        rootView.addSubview(expandedStack)
        compactStack.translatesAutoresizingMaskIntoConstraints = false
        expandedStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            compactStack.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            compactStack.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            compactStack.topAnchor.constraint(equalTo: rootView.topAnchor),
            compactStack.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            expandedStack.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            expandedStack.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            expandedStack.topAnchor.constraint(equalTo: rootView.topAnchor),
            expandedStack.bottomAnchor.constraint(equalTo: rootView.bottomAnchor)
        ])

        panel = NSPanel(contentRect: NSRect(origin: .zero, size: collapsedSize),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.contentView = rootView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isMovableByWindowBackground = true
        let expandButton = compactStack.arrangedSubviews.last as? NSButton
        expandButton?.target = self
        expandButton?.action = #selector(toggleExpanded)
        let collapseButton = header.arrangedSubviews[2] as? NSButton
        collapseButton?.target = self
        collapseButton?.action = #selector(toggleExpanded)
        let closeButton = header.arrangedSubviews[3] as? NSButton
        closeButton?.target = self
        closeButton?.action = #selector(closeHUD)

        rootView.onMove = { [weak self] in self?.rememberAnchor() }
        isExpanded = defaults.bool(forKey: "hud.expanded")
        enabled = defaults.object(forKey: "hud.enabled") as? Bool ?? true
        anchor = loadAnchor()
        updateLayout()
        if enabled { panel.orderFrontRegardless() }
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        defaults.set(value, forKey: "hud.enabled")
        if value { panel.orderFrontRegardless() }
        else { panel.orderOut(nil) }
    }

    func isEnabled() -> Bool { enabled }

    func isVisible() -> Bool { panel.isVisible }

    func render(_ snapshot: [String: Any]) {
        let codex = snapshot["codex"] as? [String: Any] ?? [:]
        let deepseek = snapshot["deepseek"] as? [String: Any] ?? [:]
        let codexPrimary = codex["primary"] as? [String: Any] ?? [:]
        let codexWeekly = codex["weekly"] as? [String: Any] ?? [:]
        let primaryPercent = percent(codexPrimary["usedPercent"])
        let weeklyPercent = percent(codexWeekly["usedPercent"])
        let balances = deepseek["balances"] as? [[String: Any]] ?? []
        let cnyBalance = balances.first { ($0["currency"] as? String) == "CNY" }?["amount"] as? String
        let spend = deepseek["officialSpend"] as? [[String: Any]] ?? []
        let cnySpend = spend.first { ($0["currency"] as? String) == "CNY" }?["amount"] as? String
        let tokens = deepseek["tokens"] as? [String: Any] ?? [:]
        let totalTokens = intString(tokens["totalTokens"])
        let signedIn = deepseek["signedIn"] as? Bool == true

        compactCodex.stringValue = codex["available"] as? Bool == true
            ? "CODEX  \(primaryPercent)" : "CODEX  —"
        compactDeepSeek.stringValue = signedIn
            ? "DEEPSEEK  \(cnyBalance.map { "¥\($0)" } ?? "—")" : "DEEPSEEK  —"
        codexValue.stringValue = "Codex  5 小时 \(primaryPercent) · 7 天 \(weeklyPercent)"
        deepSeekValue.stringValue = signedIn
            ? "DeepSeek 余额 \(cnyBalance.map { "¥\($0)" } ?? "—") · 官方累计 \(cnySpend.map { "¥\($0)" } ?? "—")"
            : "DeepSeek  尚未登录"
        tokenValue.stringValue = tokens["available"] as? Bool == true
            ? "本机 DeepSeek 会话 Token 合计  \(totalTokens)"
            : "尚无可读取的本机 DeepSeek 会话记录"
    }

    @objc private func toggleExpanded() {
        isExpanded.toggle()
        defaults.set(isExpanded, forKey: "hud.expanded")
        updateLayout()
    }

    @objc private func closeHUD() { setEnabled(false) }

    private func updateLayout() {
        compactStack.isHidden = isExpanded
        expandedStack.isHidden = !isExpanded
        let size = isExpanded ? expandedSize : collapsedSize
        let frame: NSRect
        if isExpanded {
            frame = expandedFrame()
        } else {
            frame = fit(NSRect(origin: anchor, size: size))
        }
        panel.setFrame(frame, display: true, animate: false)
        if !isExpanded {
            anchor = frame.origin
            persistAnchor()
        }
    }

    private func loadAnchor() -> NSPoint {
        if defaults.object(forKey: "hud.anchorX") != nil,
           defaults.object(forKey: "hud.anchorY") != nil {
            return NSPoint(x: defaults.double(forKey: "hud.anchorX"),
                           y: defaults.double(forKey: "hud.anchorY"))
        }
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 700)
        return NSPoint(x: visible.maxX - collapsedSize.width - 22,
                       y: visible.minY + 18)
    }

    private func rememberAnchor() {
        let fitted = fit(NSRect(x: panel.frame.minX, y: panel.frame.minY,
                                width: panel.frame.width, height: panel.frame.height))
        panel.setFrameOrigin(fitted.origin)
        if isExpanded {
            anchor = NSPoint(
                x: expandedFromLeft ? fitted.minX : fitted.maxX - collapsedSize.width,
                y: expandedFromTop ? fitted.maxY - collapsedSize.height : fitted.minY
            )
        } else {
            anchor = fitted.origin
        }
        persistAnchor()
    }

    private func persistAnchor() {
        defaults.set(anchor.x, forKey: "hud.anchorX")
        defaults.set(anchor.y, forKey: "hud.anchorY")
    }

    private func fit(_ frame: NSRect) -> NSRect {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(center) })
            ?? NSScreen.screens.first(where: { $0.frame.intersects(frame) })
            ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 700)
        let width = min(frame.width, visible.width)
        let height = min(frame.height, visible.height)
        return NSRect(
            x: min(max(frame.minX, visible.minX), visible.maxX - width),
            y: min(max(frame.minY, visible.minY), visible.maxY - height),
            width: width, height: height
        )
    }

    private func expandedFrame() -> NSRect {
        let capsule = NSRect(origin: anchor, size: collapsedSize)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: capsule.midX, y: capsule.midY)) })
            ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 700)
        let width = min(expandedSize.width, visible.width)
        let height = min(expandedSize.height, visible.height)
        let horizontalGrowth = max(0, width - collapsedSize.width)
        let verticalGrowth = max(0, height - collapsedSize.height)
        let roomRight = visible.maxX - capsule.maxX
        let roomLeft = capsule.minX - visible.minX
        let roomBelow = capsule.minY - visible.minY
        let roomAbove = visible.maxY - capsule.maxY

        expandedFromLeft = roomRight >= horizontalGrowth || roomLeft < horizontalGrowth
        expandedFromTop = roomBelow >= verticalGrowth || roomAbove < verticalGrowth

        var x = expandedFromLeft ? capsule.minX : capsule.maxX - width
        var y = expandedFromTop ? capsule.minY - verticalGrowth : capsule.minY
        x = min(max(x, visible.minX), visible.maxX - width)
        y = min(max(y, visible.minY), visible.maxY - height)

        // Keep the capsule itself on the same screen edge if both growth directions are tight.
        if roomRight < horizontalGrowth && roomLeft < horizontalGrowth {
            expandedFromLeft = (capsule.midX - visible.midX) <= 0
            x = expandedFromLeft ? capsule.minX : capsule.maxX - width
            x = min(max(x, visible.minX), visible.maxX - width)
        }
        if roomBelow < verticalGrowth && roomAbove < verticalGrowth {
            expandedFromTop = (capsule.midY - visible.midY) >= 0
            y = expandedFromTop ? capsule.minY - verticalGrowth : capsule.minY
            y = min(max(y, visible.minY), visible.maxY - height)
        }
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private func percent(_ value: Any?) -> String {
        guard let number = value as? NSNumber else { return "—" }
        return "\(Int(number.doubleValue.rounded()))%"
    }

    private func intString(_ value: Any?) -> String {
        guard let number = value as? NSNumber else { return "0" }
        return NumberFormatter.localizedString(from: number, number: .decimal)
    }

    private static func label(_ text: String, size: CGFloat, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: .medium)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    private static func button(_ title: String, target: AnyObject?, action: Selector?) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.font = .systemFont(ofSize: 14, weight: .semibold)
        button.contentTintColor = .white
        button.setButtonType(.momentaryPushIn)
        return button
    }
}

@MainActor
private final class MovableHUDView: NSVisualEffectView {
    var onMove: (() -> Void)?
    private var previousScreenPoint: NSPoint?

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit is NSButton { return hit }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        previousScreenPoint = window?.convertPoint(toScreen: event.locationInWindow)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let previousScreenPoint else { return }
        let current = window.convertPoint(toScreen: event.locationInWindow)
        let delta = NSPoint(x: current.x - previousScreenPoint.x, y: current.y - previousScreenPoint.y)
        window.setFrameOrigin(NSPoint(x: window.frame.minX + delta.x,
                                      y: window.frame.minY + delta.y))
        self.previousScreenPoint = current
        onMove?()
    }
}
