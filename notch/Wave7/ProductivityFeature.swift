import AppKit
import ApplicationServices
import Carbon
import Combine
import Foundation
import SwiftUI

enum FuzzyMatcher {
    /// Scores an ordered character match. A missing subsequence has no score.
    static func score(query: String, candidate: String) -> Double? {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let haystack = candidate.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        guard !needle.isEmpty else { return 0 }
        let q = Array(needle), c = Array(haystack)
        guard q.count <= c.count else { return nil }
        var cursor = 0
        var previous: Int?
        var total = 0.0
        for character in q {
            guard cursor < c.count else { return nil }
            guard let index = c[cursor...].firstIndex(of: character) else { return nil }
            let consecutive = previous.map { index == $0 + 1 } ?? false
            let wordStart = index == 0 || c[index - 1].isWhitespace || c[index - 1] == "-"
            total += 1 + (consecutive ? 1.5 : 0) + (wordStart ? 0.8 : 0)
            previous = index
            cursor = index + 1
        }
        let prefixBonus = haystack.hasPrefix(needle) ? 3.0 : 0
        let compactness = Double(q.count) / Double(max(c.count, 1))
        return total + prefixBonus + compactness
    }
}

enum SafeMath {
    static func evaluate(_ input: String) -> Double? {
        let source = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, source.count <= 256,
              source.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789+-*/(). \t\n").contains($0) }),
              let value = MathSyntax(source).safeValue else { return nil }
        return value
    }
}

private struct MathSyntax {
    private let characters: [Character]
    private var index = 0
    private var depth = 0

    init(_ source: String) { characters = Array(source) }

    var safeValue: Double? {
        var parser = self
        guard let value = parser.parseExpression() else { return nil }
        parser.skipSpaces()
        return parser.index == parser.characters.count && value.isFinite ? value : nil
    }

    private mutating func parseExpression() -> Double? {
        guard var value = parseTerm() else { return nil }
        while true {
            if consume("+") {
                guard let rhs = parseTerm() else { return nil }
                value += rhs
            } else if consume("-") {
                guard let rhs = parseTerm() else { return nil }
                value -= rhs
            } else { break }
            guard value.isFinite else { return nil }
        }
        return value
    }

    private mutating func parseTerm() -> Double? {
        guard var value = parseFactor() else { return nil }
        while true {
            if consume("*") {
                guard let rhs = parseFactor() else { return nil }
                value *= rhs
            } else if consume("/") {
                guard let rhs = parseFactor(), rhs != 0 else { return nil }
                value /= rhs
            } else { break }
            guard value.isFinite else { return nil }
        }
        return value
    }

    private mutating func parseFactor() -> Double? {
        skipSpaces()
        if consume("+") { return parseFactor() }
        if consume("-") { return parseFactor().map { -$0 } }
        if consume("(") {
            depth += 1
            guard depth <= 32, let value = parseExpression(), consume(")") else {
                index = characters.count + 1
                return nil
            }
            depth -= 1
            return value
        }
        let start = index
        var digits = 0
        while peek?.isNumber == true { index += 1; digits += 1 }
        if peek == "." { index += 1; while peek?.isNumber == true { index += 1; digits += 1 } }
        guard digits > 0, index > start else { index = characters.count + 1; return nil }
        return Double(String(characters[start..<index]))
    }

    private var peek: Character? { index < characters.count ? characters[index] : nil }
    private mutating func skipSpaces() { while peek == " " || peek == "\t" || peek == "\n" { index += 1 } }
    @discardableResult private mutating func consume(_ character: Character) -> Bool {
        skipSpaces()
        guard peek == character else { return false }
        index += 1
        return true
    }
}

enum RadialGeometry {
    /// Input is a standard math angle (radians, positive counter-clockwise); slice 0 is at the top.
    static func slice(for angle: Double, count: Int) -> Int {
        guard count > 0, angle.isFinite else { return -1 }
        let full = 2 * Double.pi
        var clockwiseFromTop = (Double.pi / 2 - angle).truncatingRemainder(dividingBy: full)
        if clockwiseFromTop < 0 { clockwiseFromTop += full }
        let width = full / Double(count)
        return Int(floor((clockwiseFromTop + width / 2).truncatingRemainder(dividingBy: full) / width)) % count
    }
}

enum ProductivityUsage {
    static let defaultsKey = "notch.productivity.usage"
    static let maximumKeys = 50
    static let maximumCount = 1_000_000

    static func counts(defaults: UserDefaults = .standard) -> [String: Int] {
        guard let stored = defaults.dictionary(forKey: defaultsKey) else { return [:] }
        let valid: [String: Int] = stored.compactMapValues { value -> Int? in
            guard let number = value as? NSNumber else { return nil }
            return max(0, min(number.intValue, maximumCount))
        }
        let ranked = valid.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
        }
        let bounded = ranked.prefix(maximumKeys)
        return Dictionary(uniqueKeysWithValues: bounded.map { ($0.key, $0.value) })
    }

    static func record(_ id: String, defaults: UserDefaults = .standard) {
        let key = String(id.prefix(100))
        guard !key.isEmpty else { return }
        var values = counts(defaults: defaults)
        values[key] = min((values[key] ?? 0) + 1, maximumCount)
        let kept = values.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
        }.prefix(maximumKeys)
        defaults.set(Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) }), forKey: defaultsKey)
    }

    static func top<T>(_ values: [T], id: (T) -> String, defaults: UserDefaults = .standard, limit: Int = 8) -> [T] {
        let counts = counts(defaults: defaults)
        return values.enumerated().sorted { lhs, rhs in
            let left = counts[id(lhs.element)] ?? 0, right = counts[id(rhs.element)] ?? 0
            return left == right ? lhs.offset < rhs.offset : left > right
        }.prefix(max(0, limit)).map(\.element)
    }
}

struct CleaningModeState: Equatable {
    static let maximumDuration: TimeInterval = 60
    static let escapeHoldDuration: TimeInterval = 2
    private(set) var startedAt: TimeInterval?
    private var escapeStartedAt: TimeInterval?

    var isActive: Bool { startedAt != nil }

    mutating func start(at time: TimeInterval) {
        startedAt = time
        escapeStartedAt = nil
    }

    mutating func escapeDown(at time: TimeInterval) {
        guard isActive, escapeStartedAt == nil else { return }
        escapeStartedAt = time
    }

    mutating func escapeUp(at time: TimeInterval) -> Bool {
        defer { escapeStartedAt = nil }
        guard let start = escapeStartedAt, time - start >= Self.escapeHoldDuration else { return false }
        startedAt = nil
        return true
    }

    mutating func advance(at time: TimeInterval) -> Bool {
        if let escapeStartedAt, time - escapeStartedAt >= Self.escapeHoldDuration {
            self.startedAt = nil
            self.escapeStartedAt = nil
            return true
        }
        return expire(at: time)
    }

    mutating func expire(at time: TimeInterval) -> Bool {
        guard let startedAt, time - startedAt >= Self.maximumDuration else { return false }
        self.startedAt = nil
        escapeStartedAt = nil
        return true
    }
}

enum RadialActionSettings {
    static let maximumActions = 8
    static func decode(_ string: String?, allowed: [String]) -> [String] {
        let defaults = Array(allowed.prefix(maximumActions))
        guard let string else { return defaults }
        let selected = string.split(separator: ",").map(String.init).filter { allowed.contains($0) }
        return Array((selected + defaults.filter { !selected.contains($0) }).prefix(maximumActions))
    }
    static func encode(_ values: [String], allowed: [String]) -> String {
        decode(values.joined(separator: ","), allowed: allowed).joined(separator: ",")
    }
}

private enum ProductivityHotKey: String, CaseIterable, Identifiable {
    case optionSpace, controlOptionK, controlOptionL, controlOptionSpace
    case optionQ, controlOptionP

    var id: String { rawValue }
    var title: String {
        switch self {
        case .optionSpace: "⌥ Space"
        case .controlOptionK: "⌃⌥ K"
        case .controlOptionL: "⌃⌥ L"
        case .controlOptionSpace: "⌃⌥ Space"
        case .optionQ: "⌥ Q"
        case .controlOptionP: "⌃⌥ P"
        }
    }
    var keyCode: UInt32 {
        switch self {
        case .optionSpace: UInt32(kVK_Space)
        case .controlOptionK: UInt32(kVK_ANSI_K)
        case .controlOptionL: UInt32(kVK_ANSI_L)
        case .controlOptionSpace: UInt32(kVK_Space)
        case .optionQ: UInt32(kVK_ANSI_Q)
        case .controlOptionP: UInt32(kVK_ANSI_P)
        }
    }
    var modifiers: UInt32 {
        switch self {
        case .optionSpace, .optionQ: UInt32(optionKey)
        default: UInt32(controlKey | optionKey)
        }
    }
    static let commandBarOptions: [ProductivityHotKey] = [.optionSpace, .controlOptionK, .controlOptionL]
    static let quickPanelOptions: [ProductivityHotKey] = [.optionQ, .controlOptionP]
}

private enum QuickToggleKind: String, CaseIterable, Identifiable {
    case darkMode, hiddenFiles, desktopIcons, focus, keepAwake, nightShift, wifi, bluetooth
    var id: String { rawValue }
    var title: String {
        switch self {
        case .darkMode: "Dark Mode"
        case .hiddenFiles: "Hidden Files"
        case .desktopIcons: "Desktop Icons"
        case .focus: "Do Not Disturb"
        case .keepAwake: "Keep Awake"
        case .nightShift: "Night Shift"
        case .wifi: "Wi-Fi"
        case .bluetooth: "Bluetooth"
        }
    }
    var symbol: String {
        switch self {
        case .darkMode: "moon.fill"
        case .hiddenFiles: "eye.slash"
        case .desktopIcons: "macwindow"
        case .focus: "moon.zzz.fill"
        case .keepAwake: "cup.and.saucer.fill"
        case .nightShift: "sun.horizon.fill"
        case .wifi: "wifi"
        case .bluetooth: "bluetooth"
        }
    }
    var isStateToggle: Bool { [.darkMode, .hiddenFiles, .desktopIcons, .keepAwake, .nightShift].contains(self) }
    var opensSettings: Bool { [.focus, .wifi, .bluetooth].contains(self) }
    var settingURL: URL? {
        let value: String
        switch self {
        case .focus: value = "x-apple.systempreferences:com.apple.Focus"
        case .wifi: value = "x-apple.systempreferences:com.apple.wifi-settings-extension"
        case .bluetooth: value = "x-apple.systempreferences:com.apple.BluetoothSettings"
        default: return nil
        }
        return URL(string: value)
    }
}

private enum ActionDestination {
    case module(NotchModule)
    case tool(NotchToolkitPage)
    case feature(NotchFeature)
    case quickToggle(QuickToggleKind)
}

private struct ProductivityAction: Identifiable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let destination: ActionDestination

    static var all: [ProductivityAction] {
        let modules = NotchModule.allCases.map {
            ProductivityAction(id: "module.\($0.rawValue)", title: "Open \($0.title)", detail: "Notch page", symbol: $0.symbol, destination: .module($0))
        }
        let tools = NotchToolkitPage.allCases.map {
            ProductivityAction(id: "tool.\($0.rawValue)", title: "Open \($0.title)", detail: "Tools page", symbol: $0.symbol, destination: .tool($0))
        }
        let features = NotchFeature.allCases.map {
            ProductivityAction(id: "feature.\($0.rawValue)", title: "Toggle \($0.rawValue.replacingOccurrences(of: "([A-Z])", with: " $1", options: .regularExpression).capitalized)", detail: "Notch feature", symbol: NotchFeatureRegistry.isEnabled($0) ? "checkmark.circle" : "circle", destination: .feature($0))
        }
        let toggles = QuickToggleKind.allCases.filter { _ in NotchFeatureRegistry.isEnabled(.quickToggles) }.map {
            ProductivityAction(id: "toggle.\($0.rawValue)", title: $0.title, detail: "Quick toggle", symbol: $0.symbol, destination: .quickToggle($0))
        }
        return modules + tools + features + toggles
    }
}

private enum ProductivityPanels {
    static let commandKey = "notch.productivity.commandHotKey"
    static let quickKey = "notch.productivity.quickHotKey"

    static func run(_ action: ProductivityAction) {
        if case let .quickToggle(toggle) = action.destination {
            guard NotchFeatureRegistry.isEnabled(.quickToggles) else { return }
            QuickToggleController.perform(toggle)
            return
        }
        ProductivityUsage.record(action.id)
        switch action.destination {
        case let .module(module): NotchModel.shared.select(module)
        case let .tool(page): NotchModel.shared.openTool(page)
        case let .feature(feature): NotchFeatureRegistry.setEnabled(feature, !NotchFeatureRegistry.isEnabled(feature))
        case let .quickToggle(toggle): QuickToggleController.perform(toggle)
        }
    }
}

private final class CarbonHotKeyController {
    static let shared = CarbonHotKeyController()
    private var handler: EventHandlerRef?
    private var registrations: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]

    private init() {}

    func set(_ id: UInt32, key: ProductivityHotKey?, action: @escaping () -> Void) {
        if let old = registrations.removeValue(forKey: id) { UnregisterEventHotKey(old) }
        actions.removeValue(forKey: id)
        guard let key else { removeHandlerIfIdle(); return }
        guard installHandler() else { return }
        var hotKey: EventHotKeyRef?
        var identifier = EventHotKeyID(signature: 0x4E544348, id: id)
        let status = RegisterEventHotKey(key.keyCode, key.modifiers, identifier, GetApplicationEventTarget(), 0, &hotKey)
        guard status == noErr, let hotKey else { return }
        registrations[id] = hotKey
        actions[id] = action
    }

    func fire(_ id: UInt32) { actions[id]?() }

    private func installHandler() -> Bool {
        guard handler == nil else { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        return InstallEventHandler(GetApplicationEventTarget(), productivityHotKeyHandler, 1, &spec,
                                   Unmanaged.passUnretained(self).toOpaque(), &handler) == noErr
    }

    private func removeHandlerIfIdle() {
        guard registrations.isEmpty, let handler else { return }
        RemoveEventHandler(handler)
        self.handler = nil
    }

    deinit {
        for key in registrations.values { UnregisterEventHotKey(key) }
        if let handler { RemoveEventHandler(handler) }
    }
}

private let productivityHotKeyHandler: EventHandlerProcPtr = { _, event, userData in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var identifier = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                   MemoryLayout<EventHotKeyID>.size, nil, &identifier)
    guard status == noErr else { return OSStatus(eventNotHandledErr) }
    let controller = Unmanaged<CarbonHotKeyController>.fromOpaque(userData).takeUnretainedValue()
    DispatchQueue.main.async { controller.fire(identifier.id) }
    return noErr
}

enum ProductivityFeature {
    static func apply(_ feature: NotchFeature, enabled: Bool) {
        guard feature.group == .productivity else { return }
        let update = {
            switch feature {
            case .commandBar:
                let preset = ProductivityHotKey(rawValue: UserDefaults.standard.string(forKey: ProductivityPanels.commandKey) ?? "optionSpace") ?? .optionSpace
                CarbonHotKeyController.shared.set(1, key: enabled ? preset : nil) { ProductivityPanelController.shared.showCommandBar() }
                if !enabled { ProductivityPanelController.shared.closeCommandBar() }
            case .quickPanel:
                let preset = ProductivityHotKey(rawValue: UserDefaults.standard.string(forKey: ProductivityPanels.quickKey) ?? "optionQ") ?? .optionQ
                CarbonHotKeyController.shared.set(2, key: enabled ? preset : nil) { ProductivityPanelController.shared.showQuickPanel() }
                if !enabled { ProductivityPanelController.shared.closeQuickPanel() }
            case .radialMenu:
                CarbonHotKeyController.shared.set(3, key: enabled ? .controlOptionSpace : nil) { ProductivityPanelController.shared.beginRadial() }
                if !enabled { ProductivityPanelController.shared.closeRadial() }
            case .cleaningMode:
                if enabled { CleaningModeController.shared.reassertIfActive() }
                else { CleaningModeController.shared.stop() }
            case .quickToggles: break
            default: break
            }
        }
        if Thread.isMainThread { update() } else { DispatchQueue.main.async(execute: update) }
    }
}

private extension Notification.Name {
    static let productivityCleaningResult = Notification.Name("notch.productivity.cleaning.result")
}

private final class ProductivityPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class ProductivityPanelController {
    static let shared = ProductivityPanelController()
    private var commandPanel: ProductivityPanel?
    private var quickPanel: ProductivityPanel?
    private var radialPanel: ProductivityPanel?
    private var commandMonitor: Any?
    private var quickMonitor: Any?
    private var radialTimer: Timer?
    private var radialActions: [ProductivityAction] = []
    private var radialBridge: RadialSelectionBridge?
    private var radialAnchor = NSPoint.zero

    func showCommandBar() {
        closeQuickPanel()
        closeRadial()
        close(&commandPanel, monitor: &commandMonitor)
        let bridge = CommandBarBridge()
        let panel = makePanel(size: CGSize(width: 540, height: 390), centered: true, at: nil)
        bridge.run = { [weak self] item in
            guard let self else { return }
            self.run(item)
            self.close(&self.commandPanel, monitor: &self.commandMonitor)
        }
        bridge.runCommand = { [weak self] destination, query in
            CommandCatalog.run(destination, query: query)
            guard let self else { return }
            self.close(&self.commandPanel, monitor: &self.commandMonitor)
        }
        panel.contentView = NSHostingView(rootView: CommandBarView(bridge: bridge))
        commandPanel = panel
        installNavigationMonitor(for: panel, kind: .command)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showQuickPanel() {
        closeCommandBar()
        closeRadial()
        close(&quickPanel, monitor: &quickMonitor)
        let actions = ProductivityUsage.top(ProductivityAction.all, id: \.id)
        let bridge = CommandBarBridge()
        let panel = makePanel(size: CGSize(width: 360, height: CGFloat(58 + actions.count * 34)), centered: false, at: NSEvent.mouseLocation)
        bridge.run = { [weak self] item in
            guard let self else { return }
            self.run(item)
            self.close(&self.quickPanel, monitor: &self.quickMonitor)
        }
        panel.contentView = NSHostingView(rootView: QuickPanelView(actions: actions, bridge: bridge))
        quickPanel = panel
        installNavigationMonitor(for: panel, kind: .quick)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func beginRadial() {
        closeRadial()
        let allowed = ProductivityAction.all
        let ids = RadialActionSettings.decode(UserDefaults.standard.string(forKey: "notch.productivity.radialActions"), allowed: allowed.map(\.id))
        radialActions = ids.compactMap { id in allowed.first { $0.id == id } }.prefix(8).map { $0 }
        radialAnchor = NSEvent.mouseLocation
        let panel = makePanel(size: CGSize(width: 286, height: 286), centered: false, at: radialAnchor, centerOnPoint: true)
        let bridge = RadialSelectionBridge()
        radialBridge = bridge
        panel.contentView = NSHostingView(rootView: RadialMenuView(actions: radialActions, bridge: bridge) { [weak self] action in
            self?.run(action)
            self?.closeRadial()
        })
        radialPanel = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        radialTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] timer in
            guard let self, let panel = self.radialPanel else { timer.invalidate(); return }
            let flags = CGEventSource.flagsState(.combinedSessionState)
            let held = flags.contains([.maskControl, .maskAlternate])
                && CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_Space))
            let pointer = NSEvent.mouseLocation
            let dx = pointer.x - self.radialAnchor.x
            let dy = pointer.y - self.radialAnchor.y
            let selected = hypot(dx, dy) < 34 ? -1 : RadialGeometry.slice(for: atan2(dy, dx), count: max(self.radialActions.count, 1))
            self.radialBridge?.selectionChanged?(selected)
            if !held {
                timer.invalidate()
                self.radialTimer = nil
                if self.radialActions.indices.contains(selected) { self.run(self.radialActions[selected]) }
                self.closeRadial()
            }
        }
    }

    func closeRadial() {
        radialTimer?.invalidate(); radialTimer = nil
        radialPanel?.close(); radialPanel = nil
        radialActions = []
        radialBridge = nil
    }

    func closeCommandBar() { close(&commandPanel, monitor: &commandMonitor) }
    func closeQuickPanel() { close(&quickPanel, monitor: &quickMonitor) }

    func closeAll() {
        close(&commandPanel, monitor: &commandMonitor)
        close(&quickPanel, monitor: &quickMonitor)
        closeRadial()
    }

    private func run(_ item: ProductivityAction) { ProductivityPanels.run(item) }

    private enum PanelKind: Equatable { case command, quick }
    private func installNavigationMonitor(for panel: ProductivityPanel, kind: PanelKind) {
        let token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak panel] event in
            guard let panel, event.window === panel else { return event }
            switch event.keyCode {
            case 53:
                DispatchQueue.main.async {
                    guard let self else { return }
                    if kind == .command { self.close(&self.commandPanel, monitor: &self.commandMonitor) }
                    else { self.close(&self.quickPanel, monitor: &self.quickMonitor) }
                }
                return nil
            case 126: NotificationCenter.default.post(name: .productivityMoveSelection, object: -1); return nil
            case 125: NotificationCenter.default.post(name: .productivityMoveSelection, object: 1); return nil
            case 36, 76: NotificationCenter.default.post(name: .productivityRunSelection, object: nil); return nil
            default: return event
            }
        }
        if kind == .command { commandMonitor = token } else { quickMonitor = token }
    }

    private func close(_ panel: inout ProductivityPanel?, monitor: inout Any?) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        panel?.close(); panel = nil
    }

    private func makePanel(size: CGSize, centered: Bool, at point: NSPoint?, centerOnPoint: Bool = false) -> ProductivityPanel {
        let panel = ProductivityPanel(contentRect: NSRect(origin: .zero, size: size),
                                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        if centered, let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2))
        } else if let point {
            let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main
            let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: size.width, height: size.height)
            let offset = centerOnPoint ? NSPoint(x: -size.width / 2, y: -size.height / 2) : NSPoint(x: 12, y: -size.height - 12)
            let x = min(max(point.x + offset.x, visible.minX), visible.maxX - size.width)
            let y = min(max(point.y + offset.y, visible.minY), visible.maxY - size.height)
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        return panel
    }
}

private extension Notification.Name {
    static let productivityMoveSelection = Notification.Name("notch.productivity.moveSelection")
    static let productivityRunSelection = Notification.Name("notch.productivity.runSelection")
}

private final class CommandBarBridge {
    var run: ((ProductivityAction) -> Void)?
    var runCommand: ((CommandDestination, String) -> Void)?
}

private struct CommandBarView: View {
    let bridge: CommandBarBridge
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    private var results: [CommandResult] { CommandCatalog.results(query: query) }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            TextField("Search apps, tools, toggles, or calculate…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .padding(.horizontal, 13).frame(height: 42)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                .focused($focused)
                .help("Search apps and Notch actions. Enter runs the selected result.")
                .accessibilityIdentifier("productivity-command-search")
            VStack(spacing: 3) {
                ForEach(Array(results.prefix(8).enumerated()), id: \.element.id) { index, result in
                    Button {
                        if let action = result.action { bridge.run?(action) }
                        else if let destination = result.destination { bridge.runCommand?(destination, query) }
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: result.symbol).frame(width: 19)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(result.title).font(.system(size: 12, weight: .semibold, design: .rounded))
                                Text(result.detail).font(.system(size: 10, design: .rounded)).foregroundStyle(.white.opacity(0.5))
                            }
                            Spacer(minLength: 4)
                            if index == selected { Image(systemName: "return").font(.system(size: 10)).foregroundStyle(.white.opacity(0.42)) }
                        }
                        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                        .padding(.horizontal, 8)
                        .contentShape(Rectangle())
                        .background(index == selected ? .white.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .help(result.detail)
                    .accessibilityIdentifier("productivity-command-result-\(index)")
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .productivityMoveSelection)) { note in
                selected = min(max(selected + (note.object as? Int ?? 0), 0), max(min(results.count, 8) - 1, 0))
            }
            .onReceive(NotificationCenter.default.publisher(for: .productivityRunSelection)) { _ in runSelected() }
        }
        .padding(13)
        .foregroundStyle(.white)
        .background(Color.black.opacity(0.97), in: RoundedRectangle(cornerRadius: 15))
        .onChange(of: query) { _, _ in selected = 0 }
        .onAppear { focused = true }
        .accessibilityIdentifier("productivity-command-panel")
    }

    private func runSelected() {
        guard results.indices.contains(selected) else { return }
        let result = results[selected]
        if let action = result.action { bridge.run?(action) }
        else if let destination = result.destination { bridge.runCommand?(destination, query) }
    }
}

private struct CommandResult: Identifiable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let action: ProductivityAction?
    let destination: CommandDestination?
}

private enum CommandDestination {
    case app(QuickLaunchApp)
    case calculator(Double)
    case web(String)
}

private enum CommandCatalog {
    static func results(query: String) -> [CommandResult] {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            return ProductivityUsage.top(ProductivityAction.all, id: \.id).prefix(8).map(result(for:))
        }
        let rankedActions: [(Double, CommandResult)] = ProductivityAction.all.compactMap { action in
            guard let score = FuzzyMatcher.score(query: clean, candidate: "\(action.title) \(action.detail)") else { return nil }
            return (score, result(for: action))
        }
        var rows = rankedActions.sorted { $0.0 > $1.0 }.map { $0.1 }
        let apps = AppLauncherStore.shared.apps.compactMap { app -> (Double, CommandResult)? in
            guard let score = FuzzyMatcher.score(query: clean, candidate: app.name) else { return nil }
            return (score + 0.5, CommandResult(id: "app.\(app.id.uuidString)", title: app.name, detail: "Open application", symbol: "app", action: nil, destination: .app(app)))
        }.sorted { $0.0 > $1.0 }
        rows.append(contentsOf: apps.map(\.1))
        if let value = SafeMath.evaluate(clean) {
            rows.insert(CommandResult(id: "math", title: "Copy \(value.formatted())", detail: "Calculator result", symbol: "plus.forwardslash.minus", action: nil, destination: .calculator(value)), at: 0)
        }
        rows.sort { left, right in
            let leftScore = left.id == "math" ? Double.greatestFiniteMagnitude : (FuzzyMatcher.score(query: clean, candidate: left.title + " " + left.detail) ?? -1)
            let rightScore = right.id == "math" ? Double.greatestFiniteMagnitude : (FuzzyMatcher.score(query: clean, candidate: right.title + " " + right.detail) ?? -1)
            return leftScore > rightScore
        }
        let web = CommandResult(id: "web", title: "Search the web for ‘\(clean)’", detail: "Open Google in your browser", symbol: "globe", action: nil, destination: .web(clean))
        return Array(rows.prefix(7)) + [web]
    }

    static func run(_ destination: CommandDestination, query: String) {
        switch destination {
        case let .app(app): AppLauncherStore.shared.launch(app)
        case let .calculator(value):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value.formatted(), forType: .string)
        case let .web(term):
            var components = URLComponents(string: "https://www.google.com/search")
            components?.queryItems = [URLQueryItem(name: "q", value: term.isEmpty ? query : term)]
            if let url = components?.url { NSWorkspace.shared.open(url) }
        }
    }

    private static func result(for action: ProductivityAction) -> CommandResult {
        CommandResult(id: action.id, title: action.title, detail: action.detail, symbol: action.symbol, action: action, destination: nil)
    }
}

private struct QuickPanelView: View {
    let actions: [ProductivityAction]
    let bridge: CommandBarBridge
    @State private var selected = 0

    var body: some View {
        VStack(spacing: 3) {
            Text("QUICK ACTIONS").font(.system(size: 9, weight: .bold, design: .rounded)).tracking(1.1)
                .foregroundStyle(.white.opacity(0.42)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                Button { bridge.run?(action) } label: {
                    HStack(spacing: 9) {
                        Image(systemName: action.symbol).frame(width: 18)
                        Text(action.title).font(.system(size: 12, weight: .medium, design: .rounded))
                        Spacer()
                        if index == selected { Image(systemName: "return").font(.system(size: 9)) }
                    }
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading).padding(.horizontal, 8)
                    .contentShape(Rectangle())
                    .background(index == selected ? .white.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain).help(action.detail).accessibilityIdentifier("productivity-quick-action-\(index)")
            }
        }
        .padding(10).foregroundStyle(.white).background(Color.black.opacity(0.97), in: RoundedRectangle(cornerRadius: 13))
        .onReceive(NotificationCenter.default.publisher(for: .productivityMoveSelection)) { note in
            selected = min(max(selected + (note.object as? Int ?? 0), 0), max(actions.count - 1, 0))
        }
        .onReceive(NotificationCenter.default.publisher(for: .productivityRunSelection)) { _ in
            if actions.indices.contains(selected) { bridge.run?(actions[selected]) }
        }
    }
}

private final class RadialSelectionBridge {
    var selectionChanged: ((Int) -> Void)?
}

private struct RadialMenuView: View {
    let actions: [ProductivityAction]
    let bridge: RadialSelectionBridge
    let onSelect: (ProductivityAction) -> Void
    @State private var selected = 0

    var body: some View {
        ZStack {
            Circle().fill(Color.black.opacity(0.98)).overlay(Circle().stroke(.white.opacity(0.12), lineWidth: 1))
            Circle().fill(.white.opacity(0.045)).frame(width: 58, height: 58)
            Image(systemName: "sparkle").foregroundStyle(.white.opacity(0.7))
            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                let angle = -Double.pi / 2 + Double(index) * 2 * Double.pi / Double(max(actions.count, 1))
                Button { onSelect(action) } label: {
                    VStack(spacing: 4) {
                        Image(systemName: action.symbol).font(.system(size: 16, weight: .semibold))
                        Text(action.title.replacingOccurrences(of: "Open ", with: ""))
                            .font(.system(size: 8, weight: .medium, design: .rounded)).lineLimit(1).frame(width: 72)
                    }
                    .foregroundStyle(.white.opacity(selected == index ? 1 : 0.68))
                    .padding(7).frame(minHeight: 32).contentShape(Rectangle())
                    .background(selected == index ? .white.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain).help(action.title)
                .offset(x: cos(angle) * 88, y: sin(angle) * 88)
                .accessibilityIdentifier("productivity-radial-slice-\(index)")
            }
        }
        .frame(width: 286, height: 286)
        .onAppear { bridge.selectionChanged = { selected = $0 } }
        .onDisappear { bridge.selectionChanged = nil }
    }
}

private enum QuickToggleController {
    static func refresh() {
        NotchSystemHelperClient.shared.perform("productivity", "quickToggleStatus") { reply in
            guard let reply else { return }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .productivityQuickStatus, object: nil, userInfo: reply)
            }
        }
    }

    static func perform(_ toggle: QuickToggleKind) {
        ProductivityUsage.record("toggle.\(toggle.rawValue)")
        switch toggle {
        case .focus, .wifi, .bluetooth:
            if let url = toggle.settingURL { NSWorkspace.shared.open(url) }
        case .keepAwake:
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let store = NotchToolkitStore.shared
                    if store.isKeepingAwake { store.stopKeepingAwake() }
                    else { store.startKeepingAwake(minutes: nil, mode: store.keepAwakeMode) }
                }
            }
        case .hiddenFiles, .desktopIcons:
            guard confirmFinderRestart(for: toggle) else { return }
            send(toggle)
        case .darkMode, .nightShift:
            send(toggle)
        }
        refresh()
    }

    private static func send(_ toggle: QuickToggleKind) {
        NotchSystemHelperClient.shared.perform("productivity", "toggleQuickToggle", args: ["name": toggle.rawValue]) { reply in
            guard let reply else { return }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .productivityQuickStatus, object: nil, userInfo: reply)
                if let error = reply["error"] as? String {
                    if toggle == .darkMode && reply["automationAllowed"] as? Bool == false {
                        let alert = NSAlert()
                        alert.messageText = "Automation permission is required."
                        alert.informativeText = "Allow Notch System Helper to control System Events in Privacy & Security → Automation."
                        alert.addButton(withTitle: "Open Settings")
                        alert.addButton(withTitle: "Cancel")
                        if alert.runModal() == .alertFirstButtonReturn,
                           let url = NotchPermission.automation.settingsURL { NSWorkspace.shared.open(url) }
                    }
                    NotificationCenter.default.post(name: .productivityCleaningResult, object: nil, userInfo: ["error": error])
                }
            }
        }
    }

    private static func confirmFinderRestart(for toggle: QuickToggleKind) -> Bool {
        let alert = NSAlert()
        alert.messageText = toggle == .hiddenFiles ? "Change hidden file visibility?" : "Change desktop icon visibility?"
        alert.informativeText = "Finder must relaunch to apply this change."
        alert.addButton(withTitle: "Change and Relaunch Finder")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

private extension Notification.Name {
    static let productivityQuickStatus = Notification.Name("notch.productivity.quickStatus")
}

struct QuickToolsView: View {
    @ObservedObject private var toolkit = NotchToolkitStore.shared
    @ObservedObject private var model = NotchModel.shared
    @State private var status: [String: Any] = [:]
    @State private var cleaningMessage: String?
    @State private var appHasAccessibility = AXIsProcessTrusted()
    @AppStorage(NotchFeature.cleaningMode.defaultsKey) private var featureEnabled = false
    @AppStorage(NotchFeature.quickToggles.defaultsKey) private var quickTogglesEnabled = true

    private var orderedToggles: [QuickToggleKind] {
        ProductivityUsage.top(QuickToggleKind.allCases, id: \.rawValue)
    }

    private var pageIsVisible: Bool {
        model.expansionState == .expanded && model.activeModule == .toolkit && model.toolkitPage == .tools
    }

    var body: some View {
        Group {
            if quickTogglesEnabled { quickToolsContent }
            else { Text("Enable Quick Toggles in Productivity settings.").font(.system(size: 11, design: .rounded)).foregroundStyle(.white.opacity(0.55)) }
        }
        .accessibilityIdentifier("productivity-quick-tools")
    }

    private var quickToolsContent: some View {
        VStack(alignment: .leading, spacing: 7) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 4), spacing: 6) {
                ForEach(orderedToggles) { toggle in
                    toggleButton(toggle)
                }
            }
            HStack(spacing: 8) {
                Button {
                    guard featureEnabled else {
                        cleaningMessage = "Enable Cleaning Mode in Productivity settings first."
                        return
                    }
                    appHasAccessibility = AXIsProcessTrusted()
                    guard appHasAccessibility else { return }
                    CleaningModeController.shared.start()
                } label: {
                    Label("Clean Keyboard", systemImage: "keyboard")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .frame(minWidth: 132, minHeight: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                .help("Temporarily block keyboard and trackpad input for cleaning.")
                .accessibilityIdentifier("productivity-clean-keyboard")
                if !appHasAccessibility {
                    Text("Accessibility lets Cleaning Mode block input.")
                        .font(.system(size: 10, design: .rounded)).foregroundStyle(.white.opacity(0.58)).lineLimit(1)
                    settingsButton(.accessibility, id: "productivity-cleaning-accessibility-settings")
                } else if let note = cleaningMessage {
                    Text(note).font(.system(size: 10, design: .rounded)).foregroundStyle(.white.opacity(0.58)).lineLimit(1)
                    if note.localizedCaseInsensitiveContains("accessibility") {
                        settingsButton(.accessibility, id: "productivity-cleaning-helper-settings")
                    }
                } else if status["automationAllowed"] as? Bool == false {
                    Text("Automation is needed to read or change Dark Mode.")
                        .font(.system(size: 10, design: .rounded)).foregroundStyle(.white.opacity(0.58)).lineLimit(1)
                    settingsButton(.automation, id: "productivity-automation-settings")
                } else {
                    Spacer(minLength: 0)
                }
            }
            .frame(minHeight: 30)
        }
        .foregroundStyle(.white)
        .onAppear {
            appHasAccessibility = AXIsProcessTrusted()
        }
        .onReceive(NotificationCenter.default.publisher(for: .productivityQuickStatus)) { note in
            if let values = note.userInfo as? [String: Any] { status = values }
        }
        .onReceive(NotificationCenter.default.publisher(for: .productivityCleaningResult)) { note in
            if let message = note.userInfo?["error"] as? String { cleaningMessage = message }
        }
        .task(id: pageIsVisible) {
            guard pageIsVisible else { return }
            while !Task.isCancelled {
                QuickToggleController.refresh()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private func toggleButton(_ toggle: QuickToggleKind) -> some View {
        let raw = statusValue(for: toggle)
        let isOn = raw == "On"
        let label = toggle == .keepAwake ? (toolkit.isKeepingAwake ? "On" : "Off") : raw
        return Button {
            QuickToggleController.perform(toggle)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: toggle.symbol).font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isOn ? Color(red: 0.99, green: 0.72, blue: 0.31) : .white.opacity(0.72))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(toggle.title).font(.system(size: 10, weight: .semibold, design: .rounded)).lineLimit(1)
                    Text(label).font(.system(size: 9, design: .rounded)).foregroundStyle(.white.opacity(0.52)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .contentShape(Rectangle())
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(toggle == .nightShift && status["nightShiftAvailable"] as? Bool == false)
        .help(toggle.opensSettings ? "Open \(toggle.title) settings." : "Toggle \(toggle.title.lowercased()).")
        .accessibilityIdentifier("productivity-toggle-\(toggle.rawValue)")
    }

    private func statusValue(for toggle: QuickToggleKind) -> String {
        if toggle == .keepAwake { return toolkit.isKeepingAwake ? "On" : "Off" }
        switch toggle {
        case .darkMode:
            guard status["automationAllowed"] as? Bool == true,
                  let enabled = status["darkMode"] as? Bool else { return "Unavailable" }
            return enabled ? "On" : "Off"
        case .hiddenFiles: return status["hiddenFiles"] as? Bool == true ? "On" : "Off"
        case .desktopIcons: return status["desktopIcons"] as? Bool == true ? "On" : "Off"
        case .nightShift:
            guard status["nightShiftAvailable"] as? Bool == true else { return "Unavailable" }
            return status["nightShift"] as? Bool == true ? "On" : "Off"
        case .focus: return "Open Settings"
        case .wifi: return status["wifiStatus"] as? String ?? "Checking…"
        case .bluetooth: return status["bluetoothStatus"] as? String ?? "Checking…"
        case .keepAwake: return toolkit.isKeepingAwake ? "On" : "Off"
        }
    }

    private func settingsButton(_ permission: NotchPermission, id: String) -> some View {
        Button("Open Settings") {
            if let url = permission.settingsURL { NSWorkspace.shared.open(url) }
        }
        .frame(minHeight: 28).contentShape(Rectangle())
        .help("Open the \(permission.title) privacy settings.")
        .accessibilityIdentifier(id)
    }
}

private final class CleaningModeController {
    static let shared = CleaningModeController()
    private var panel: ProductivityPanel?
    private var pollTimer: Timer?
    private var state = CleaningModeState()
    private var requestPending = false
    private var ownerArguments: [String: Any]?

    func start() {
        guard !state.isActive else { return }
        state.start(at: ProcessInfo.processInfo.systemUptime)
        let app = NSRunningApplication.current
        let arguments: [String: Any] = [
            "on": true,
            "duration": CleaningModeState.maximumDuration,
            "escapeHold": CleaningModeState.escapeHoldDuration,
            "ownerPID": app.processIdentifier,
            "ownerBundle": Bundle.main.bundleIdentifier ?? "sidco.notch",
            "ownerLaunch": app.launchDate?.timeIntervalSince1970 ?? 0
        ]
        ownerArguments = arguments
        NotchSystemHelperClient.shared.perform("productivity", "lockInput", args: arguments, timeout: 2) { [weak self] reply in
            DispatchQueue.main.async {
                guard let self else { return }
                guard reply?["ok"] as? Bool == true else {
                    self.state = CleaningModeState()
                    self.ownerArguments = nil
                    NotchSystemHelperClient.shared.perform("productivity", "lockInput", args: ["on": false])
                    self.postError(reply?["error"] as? String ?? "Accessibility permission is required to lock input.")
                    return
                }
                self.showPanel()
                self.beginStatusPolling()
            }
        }
    }

    func stop() {
        pollTimer?.invalidate(); pollTimer = nil
        state = CleaningModeState()
        ownerArguments = nil
        NotchSystemHelperClient.shared.perform("productivity", "lockInput", args: ["on": false])
        panel?.close(); panel = nil
        requestPending = false
    }

    func reassertIfActive() {
        guard state.isActive, var arguments = ownerArguments, let startedAt = state.startedAt else { return }
        let remaining = max(1, CleaningModeState.maximumDuration - (ProcessInfo.processInfo.systemUptime - startedAt))
        arguments["duration"] = remaining
        NotchSystemHelperClient.shared.perform("productivity", "lockInput", args: arguments, timeout: 2) { [weak self] reply in
            guard reply?["ok"] as? Bool != true else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.finishAfterHelperRelease()
                self.ownerArguments = nil
                self.postError(reply?["error"] as? String ?? "Cleaning Mode could not restore input lock.")
            }
        }
    }

    private func beginStatusPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let now = ProcessInfo.processInfo.systemUptime
            if self.state.expire(at: now) { self.stop(); return }
            guard !self.requestPending else { return }
            self.requestPending = true
            NotchSystemHelperClient.shared.perform("productivity", "lockStatus", timeout: 2) { [weak self] reply in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.requestPending = false
                    if reply?["locked"] as? Bool != true { self.finishAfterHelperRelease() }
                }
            }
        }
    }

    private func finishAfterHelperRelease() {
        pollTimer?.invalidate(); pollTimer = nil
        state = CleaningModeState()
        ownerArguments = nil
        panel?.close(); panel = nil
    }

    private func showPanel() {
        guard panel == nil else { return }
        let frame = NSScreen.screens.reduce(NSRect.null) { $0.union($1.frame) }
        let window = ProductivityPanel(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .screenSaver
        window.isOpaque = true
        window.backgroundColor = .black
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.contentView = NSHostingView(rootView: CleaningModeOverlay())
        panel = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func postError(_ message: String) {
        NotificationCenter.default.post(name: .productivityCleaningResult, object: nil, userInfo: ["error": message])
    }
}

private struct CleaningModeOverlay: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "keyboard.fill").font(.system(size: 34, weight: .light)).foregroundStyle(.white.opacity(0.64))
            Text("Cleaning Mode").font(.system(size: 21, weight: .semibold, design: .rounded))
            Text("Input is locked. Hold Escape for 2 seconds to finish.")
                .font(.system(size: 13, design: .rounded)).foregroundStyle(.white.opacity(0.58))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white).background(Color.black)
    }
}

struct ProductivitySettingsSection: View {
    @AppStorage(ProductivityPanels.commandKey) private var commandHotKey = "optionSpace"
    @AppStorage(ProductivityPanels.quickKey) private var quickHotKey = "optionQ"
    @AppStorage(NotchFeature.commandBar.defaultsKey) private var commandEnabled = false
    @AppStorage(NotchFeature.quickPanel.defaultsKey) private var quickPanelEnabled = false
    @AppStorage(NotchFeature.radialMenu.defaultsKey) private var radialEnabled = false
    @AppStorage(NotchFeature.cleaningMode.defaultsKey) private var cleaningEnabled = false
    @State private var radialActions = RadialActionSettings.decode(nil, allowed: ProductivityAction.all.map(\.id))
    @State private var accessibilityTrusted = AXIsProcessTrusted()

    private var needsAccessibility: Bool { commandEnabled || quickPanelEnabled || radialEnabled || cleaningEnabled }

    private var actionOptions: [ProductivityAction] { ProductivityAction.all }

    var body: some View {
        Section("Productivity") {
            NotchFeatureToggle(.commandBar, "Command Bar", detail: "Search apps, Notch pages, tools, toggles, and math.")
            NotchFeatureToggle(.quickPanel, "Quick Panel", detail: "Open your eight most used Notch actions.")
            NotchFeatureToggle(.quickToggles, "Quick Toggles", detail: "Dark Mode, Finder, Focus, awake, Night Shift, and device status.")
            NotchFeatureToggle(.radialMenu, "Radial Menu", detail: "Hold the shortcut, point to an action, then release.")
            NotchFeatureToggle(.cleaningMode, "Cleaning Mode", detail: "Temporarily block keyboard and trackpad input.")
        }
        Section("Shortcuts") {
            Picker("Command Bar", selection: $commandHotKey) {
                ForEach(ProductivityHotKey.commandBarOptions) { Text($0.title).tag($0.rawValue) }
            }
            .frame(minHeight: 28).help("Choose the global Command Bar shortcut.").accessibilityIdentifier("productivity-command-hotkey")
            .onChange(of: commandHotKey) { _, _ in
                ProductivityFeature.apply(.commandBar, enabled: NotchFeatureRegistry.isEnabled(.commandBar))
            }
            Picker("Quick Panel", selection: $quickHotKey) {
                ForEach(ProductivityHotKey.quickPanelOptions) { Text($0.title).tag($0.rawValue) }
            }
            .frame(minHeight: 28).help("Choose the global Quick Panel shortcut.").accessibilityIdentifier("productivity-quick-hotkey")
            .onChange(of: quickHotKey) { _, _ in
                ProductivityFeature.apply(.quickPanel, enabled: NotchFeatureRegistry.isEnabled(.quickPanel))
            }
            Text("Radial Menu: hold ⌃⌥ Space, move toward an action, and release.")
                .font(.caption).foregroundStyle(.secondary)
            if needsAccessibility && !accessibilityTrusted {
                HStack(spacing: 8) {
                    Text("Accessibility is needed for the enabled Productivity features.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Open Settings") {
                        accessibilityTrusted = AXIsProcessTrusted()
                        if let url = NotchPermission.accessibility.settingsURL { NSWorkspace.shared.open(url) }
                    }
                    .frame(minHeight: 28).contentShape(Rectangle())
                    .help("Open Accessibility privacy settings.")
                    .accessibilityIdentifier("productivity-accessibility-settings")
                }
            }
        }
        Section("Radial Actions") {
            ForEach(0..<RadialActionSettings.maximumActions, id: \.self) { index in
                Picker("Slice \(index + 1)", selection: radialBinding(index)) {
                    ForEach(actionOptions) { Text($0.title).tag($0.id) }
                }
                .frame(minHeight: 28).help("Choose the action for radial slice \(index + 1).")
                .accessibilityIdentifier("productivity-radial-action-\(index)")
            }
        }
        .onAppear {
            accessibilityTrusted = AXIsProcessTrusted()
            radialActions = RadialActionSettings.decode(UserDefaults.standard.string(forKey: "notch.productivity.radialActions"), allowed: actionOptions.map(\.id))
        }
        .onChange(of: radialActions) { _, values in
            UserDefaults.standard.set(RadialActionSettings.encode(values, allowed: actionOptions.map(\.id)), forKey: "notch.productivity.radialActions")
        }
    }

    private func radialBinding(_ index: Int) -> Binding<String> {
        Binding(get: { radialActions.indices.contains(index) ? radialActions[index] : (actionOptions.first?.id ?? "") }, set: { value in
            guard radialActions.indices.contains(index) else { return }
            radialActions[index] = value
        })
    }
}
