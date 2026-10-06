import ApplicationServices
import AppKit
import Foundation

private struct HelperKeyMappingEntry: Equatable {
    let source: UInt64
    let destination: UInt64
}

private enum HelperKeyMapping {
    static let capsLockToF18 = HelperKeyMappingEntry(source: 0x700000039, destination: 0x70000006D)

    static func merge(existing: [HelperKeyMappingEntry], adding entry: HelperKeyMappingEntry) -> [HelperKeyMappingEntry] {
        var result = existing.filter { $0.source != entry.source }
        result.append(entry)
        return result
    }

    static func remove(existing: [HelperKeyMappingEntry], removing entry: HelperKeyMappingEntry = capsLockToF18) -> [HelperKeyMappingEntry] {
        existing.filter { $0 != entry }
    }

    static func parse(_ output: String) -> [HelperKeyMappingEntry]? {
        guard output.localizedCaseInsensitiveContains("UserKeyMapping") else { return nil }
        let blocks = capture(output, pattern: #"\{[^{}]*\}"#)
        if blocks.isEmpty {
            let tail = output.components(separatedBy: ":").dropFirst().joined(separator: ":")
            let compact = tail.filter { !$0.isWhitespace }
            return compact == "()" || compact == "[]" ? [] : nil
        }
        var entries: [HelperKeyMappingEntry] = []
        for block in blocks {
            guard let source = number("HIDKeyboardModifierMappingSrc", in: block),
                  let destination = number("HIDKeyboardModifierMappingDst", in: block) else { return nil }
            entries.append(HelperKeyMappingEntry(source: source, destination: destination))
        }
        return entries
    }

    static func propertyValue(_ entries: [HelperKeyMappingEntry]) -> String? {
        let rows: [[String: UInt64]] = entries.map {
            ["HIDKeyboardModifierMappingSrc": $0.source, "HIDKeyboardModifierMappingDst": $0.destination]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: ["UserKeyMapping": rows], options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func number(_ name: String, in text: String) -> UInt64? {
        let pattern = #"[\"']?\#(name)[\"']?\s*(?:=|:)\s*[\"']?(0[xX][0-9a-fA-F]+|[0-9]+)"#
        guard let value = capture(text, pattern: pattern).first else { return nil }
        if value.hasPrefix("0x") || value.hasPrefix("0X") { return UInt64(value.dropFirst(2), radix: 16) }
        return UInt64(value)
    }

    private static func capture(_ text: String, pattern: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            let group = match.numberOfRanges > 1 ? 1 : 0
            guard let matchRange = Range(match.range(at: group), in: text) else { return nil }
            return String(text[matchRange])
        }
    }
}

private enum HelperTapAction: String {
    case escape, capsLock, nothing
}

private enum HelperShortcutAction: String {
    case openApp, openURL, runShortcut
}

private struct HelperShortcut {
    let key: String
    let action: HelperShortcutAction
    let target: String

    init?(_ value: [String: Any]) {
        guard let key = value["key"] as? String,
              key.count == 1,
              let actionValue = value["action"] as? String,
              let action = HelperShortcutAction(rawValue: actionValue),
              let target = value["target"] as? String,
              !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self.key = key.uppercased()
        self.action = action
        self.target = String(target.trimmingCharacters(in: .whitespacesAndNewlines).prefix(512))
    }
}

private struct HelperHyperState {
    static let tapThreshold: TimeInterval = 0.2
    private(set) var isDown = false
    private var downAt: TimeInterval?
    private var sawOtherKey = false

    mutating func keyDown(at time: TimeInterval) {
        guard !isDown else { return }
        isDown = true
        downAt = time
        sawOtherKey = false
    }

    mutating func keyUp(at time: TimeInterval) -> Bool {
        guard isDown else { return false }
        let elapsed = max(0, time - (downAt ?? time))
        let isTap = !sawOtherKey && elapsed < Self.tapThreshold
        isDown = false
        downAt = nil
        sawOtherKey = false
        return isTap
    }

    mutating func otherKeyDown() {
        if isDown { sawOtherKey = true }
    }
}

private final class KeysEventContext {
    private let lock = NSLock()
    private var state = HelperHyperState()
    private var tapAction: HelperTapAction
    private var shortcuts: [HelperShortcut]
    private weak var tap: CFMachPort?

    init(tapAction: HelperTapAction, shortcuts: [HelperShortcut]) {
        self.tapAction = tapAction
        self.shortcuts = shortcuts
    }

    func setTap(_ tap: CFMachPort) { self.tap = tap }

    func update(tapAction: HelperTapAction, shortcuts: [HelperShortcut]) {
        lock.lock()
        self.tapAction = tapAction
        self.shortcuts = shortcuts
        lock.unlock()
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let time = TimeInterval(event.timestamp) / 1_000_000_000
        lock.lock()
        if keyCode == 0x6D, type == .keyDown {
            state.keyDown(at: time)
            lock.unlock()
            return nil
        }
        if keyCode == 0x6D, type == .keyUp {
            let shouldTap = state.keyUp(at: time)
            let configuredTap = tapAction
            lock.unlock()
            if shouldTap { Self.performTap(configuredTap) }
            return nil
        }

        if type == .keyDown {
            state.otherKeyDown()
        }
        let hyperIsDown = state.isDown
        var actionToRun: HelperShortcut?
        if type == .keyDown, hyperIsDown, let key = Self.eventKey(event),
           let shortcut = shortcuts.first(where: { $0.key == key }) {
            actionToRun = shortcut
        }
        lock.unlock()

        if hyperIsDown && (type == .keyDown || type == .keyUp || type == .flagsChanged) {
            event.flags = event.flags
                .union(.maskControl)
                .union(.maskAlternate)
                .union(.maskCommand)
                .union(.maskShift)
        }
        if let actionToRun { Self.run(actionToRun) }
        return Unmanaged.passUnretained(event)
    }

    private static func eventKey(_ event: CGEvent) -> String? {
        var characters = [UniChar](repeating: 0, count: 16)
        var length = 0
        event.keyboardGetUnicodeString(
            maxStringLength: characters.count,
            actualStringLength: &length,
            unicodeString: &characters
        )
        guard length > 0, Int(length) <= characters.count else { return nil }
        let text = String(utf16CodeUnits: characters, count: Int(length))
        return text.count == 1 ? text.uppercased() : nil
    }

    private static func performTap(_ action: HelperTapAction) {
        let keyCode: CGKeyCode
        switch action {
        case .escape: keyCode = 53
        case .capsLock: keyCode = 57
        case .nothing: return
        }
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private static func run(_ shortcut: HelperShortcut) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            switch shortcut.action {
            case .openApp:
                process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                process.arguments = ["-b", shortcut.target]
            case .openURL:
                guard let url = URL(string: shortcut.target), let scheme = url.scheme, !scheme.isEmpty else { return }
                process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                process.arguments = [url.absoluteString]
            case .runShortcut:
                process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
                process.arguments = ["run", shortcut.target]
            }
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                // Invalid or unavailable user targets are ignored.
            }
        }
    }
}

private let keysTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let context = Unmanaged<KeysEventContext>.fromOpaque(userInfo).takeUnretainedValue()
    return context.handle(type: type, event: event)
}

private final class KeysHelperRuntime {
    static let shared = KeysHelperRuntime()

    private let lock = NSRecursiveLock()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var context: KeysEventContext?
    private var ownsMapping = false

    private init() {
        atexit { KeysHelperRuntime.shared.shutdown() }
    }

    func status() -> HelperArgs {
        lock.lock()
        let enabled = eventTap != nil
        lock.unlock()
        return [
            "ok": true,
            "accessibilityTrusted": AXIsProcessTrusted(),
            "enabled": enabled
        ]
    }

    func enable(args: HelperArgs) -> HelperArgs {
        lock.lock()
        defer { lock.unlock() }

        guard AXIsProcessTrusted() else {
            disableLocked()
            return ["ok": false, "accessibilityTrusted": false, "error": "Accessibility permission is required."]
        }
        let action = HelperTapAction(rawValue: args["tapAction"] as? String ?? "") ?? .escape
        let shortcuts = (args["shortcuts"] as? [[String: Any]] ?? []).prefix(20).compactMap(HelperShortcut.init)
        if let context {
            context.update(tapAction: action, shortcuts: shortcuts)
        }
        guard installMapping() else {
            disableLocked()
            return ["ok": false, "accessibilityTrusted": true, "error": "Caps Lock already has a different user mapping or hidutil failed."]
        }
        guard eventTap != nil || installTap(action: action, shortcuts: shortcuts) else {
            restoreMapping()
            return ["ok": false, "accessibilityTrusted": true, "error": "The keyboard event tap could not be started."]
        }
        return ["ok": true, "accessibilityTrusted": true, "enabled": true]
    }

    func disable() -> HelperArgs {
        lock.lock()
        defer { lock.unlock() }
        disableLocked()
        return ["ok": true, "enabled": false]
    }

    func shutdown() {
        lock.lock()
        disableLocked()
        lock.unlock()
    }

    private func disableLocked() {
        disableTapLocked()
        restoreMapping()
    }

    private func disableTapLocked() {
        if let runLoopSource { HelperRunLoop.shared.remove(runLoopSource) }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        runLoopSource = nil
        eventTap = nil
        context = nil
    }

    private func installTap(action: HelperTapAction, shortcuts: [HelperShortcut]) -> Bool {
        let mask = [CGEventType.keyDown, .keyUp, .flagsChanged]
            .reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let context = KeysEventContext(tapAction: action, shortcuts: shortcuts)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: keysTapCallback,
            userInfo: Unmanaged.passUnretained(context).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return false }
        context.setTap(tap)
        self.context = context
        eventTap = tap
        runLoopSource = source
        HelperRunLoop.shared.add(source)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func installMapping() -> Bool {
        guard let existing = readMapping() else { return false }
        guard !existing.contains(where: { $0.source == HelperKeyMapping.capsLockToF18.source && $0 != HelperKeyMapping.capsLockToF18 }) else { return false }
        let merged = HelperKeyMapping.merge(existing: existing, adding: HelperKeyMapping.capsLockToF18)
        if merged != existing {
            guard writeMapping(merged) else { return false }
            ownsMapping = true
        }
        return true
    }

    private func restoreMapping() {
        guard ownsMapping else { return }
        guard let existing = readMapping() else { return }
        let restored = HelperKeyMapping.remove(existing: existing)
        guard restored != existing else {
            ownsMapping = false
            return
        }
        if writeMapping(restored) { ownsMapping = false }
    }

    private func readMapping() -> [HelperKeyMappingEntry]? {
        guard let result = runHidutil(["property", "--get", "UserKeyMapping"]), result.status == 0 else { return nil }
        return HelperKeyMapping.parse(result.output)
    }

    private func writeMapping(_ entries: [HelperKeyMappingEntry]) -> Bool {
        guard let value = HelperKeyMapping.propertyValue(entries),
              let result = runHidutil(["property", "--set", value]) else { return false }
        return result.status == 0
    }

    private func runHidutil(_ arguments: [String]) -> (status: Int32, output: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch {
            return nil
        }
    }
}

enum KeysHelperHandler: HelperHandler {
    static func handle(action: String, args: HelperArgs, reply: @escaping (HelperArgs?) -> Void) {
        switch action {
        case "status": reply(KeysHelperRuntime.shared.status())
        case "enable": reply(KeysHelperRuntime.shared.enable(args: args))
        case "disable": reply(KeysHelperRuntime.shared.disable())
        case "ping": reply(["ok": true])
        default: reply(HelperRouter.unknown(action))
        }
    }
}
