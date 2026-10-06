import ApplicationServices
import AppKit
import Foundation
import SwiftUI

enum HyperTapAction: String, CaseIterable, Codable, Identifiable {
    case escape
    case capsLock
    case nothing

    var id: String { rawValue }
    var title: String {
        switch self {
        case .escape: return "Escape"
        case .capsLock: return "Caps Lock toggle"
        case .nothing: return "Nothing"
        }
    }
}

enum HyperShortcutAction: String, CaseIterable, Codable, Identifiable {
    case openApp
    case openURL
    case runShortcut

    var id: String { rawValue }
    var title: String {
        switch self {
        case .openApp: return "Open app"
        case .openURL: return "Open URL"
        case .runShortcut: return "Run Shortcut"
        }
    }
    var targetPrompt: String {
        switch self {
        case .openApp: return "Bundle identifier"
        case .openURL: return "URL"
        case .runShortcut: return "Shortcut name"
        }
    }
}

struct HyperShortcut: Codable, Equatable, Identifiable {
    var id: UUID
    var key: String
    var action: HyperShortcutAction
    var target: String

    init(id: UUID = UUID(), key: String = "", action: HyperShortcutAction = .openApp, target: String = "") {
        self.id = id
        self.key = key
        self.action = action
        self.target = target
    }
}

enum HyperShortcutCodec {
    static let defaultsKey = "notch.keys.shortcuts"
    static let maximumEntries = 20

    static func decode(_ data: Data?) -> [HyperShortcut] {
        guard let data,
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return rows.prefix(maximumEntries).compactMap { row in
            guard let actionRaw = row["action"] as? String,
                  let action = HyperShortcutAction(rawValue: actionRaw),
                  let key = row["key"] as? String,
                  let target = row["target"] as? String else { return nil }
            let id = (row["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
            return HyperShortcut(
                id: id,
                key: String(key.prefix(64)),
                action: action,
                target: String(target.prefix(512))
            )
        }
    }

    static func encode(_ shortcuts: [HyperShortcut]) -> Data? {
        let rows: [[String: Any]] = shortcuts.prefix(maximumEntries).map { shortcut in
            [
                "id": shortcut.id.uuidString,
                "key": String(shortcut.key.prefix(64)),
                "action": shortcut.action.rawValue,
                "target": String(shortcut.target.prefix(512))
            ]
        }
        return try? JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
    }

    static func normalizedKey(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 1, !trimmed.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains) else {
            return nil
        }
        return trimmed.uppercased()
    }

    static func runtimeEntries(_ shortcuts: [HyperShortcut]) -> [[String: String]] {
        shortcuts.prefix(maximumEntries).compactMap { shortcut in
            guard let key = normalizedKey(shortcut.key) else { return nil }
            let target = shortcut.target.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !target.isEmpty else { return nil }
            return ["key": key, "action": shortcut.action.rawValue, "target": String(target.prefix(512))]
        }
    }

    static func load(defaults: UserDefaults = .standard) -> [HyperShortcut] {
        decode(defaults.data(forKey: defaultsKey))
    }

    static func save(_ shortcuts: [HyperShortcut], defaults: UserDefaults = .standard) {
        guard let data = encode(shortcuts) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}

struct HyperState: Equatable {
    enum Event: Equatable {
        case f18Down(at: TimeInterval)
        case f18Up(at: TimeInterval)
        case otherKeyDown
    }

    enum Effect: Equatable {
        case modifiers(Bool)
        case tap(HyperTapAction)
    }

    static let tapThreshold: TimeInterval = 0.2
    private(set) var isDown = false
    private var downAt: TimeInterval?
    private var sawOtherKey = false

    mutating func process(_ event: Event, tapAction: HyperTapAction) -> [Effect] {
        switch event {
        case let .f18Down(at):
            guard !isDown else { return [] }
            isDown = true
            downAt = at
            sawOtherKey = false
            return [.modifiers(true)]

        case let .f18Up(at):
            guard isDown else { return [] }
            let elapsed = max(0, at - (downAt ?? at))
            let isTap = !sawOtherKey && elapsed < Self.tapThreshold
            isDown = false
            downAt = nil
            sawOtherKey = false
            return isTap ? [.modifiers(false), .tap(tapAction)] : [.modifiers(false)]

        case .otherKeyDown:
            if isDown { sawOtherKey = true }
            return []
        }
    }
}

struct UserKeyMappingEntry: Codable, Equatable {
    var source: UInt64
    var destination: UInt64
}

enum UserKeyMapping {
    static let capsLockToF18 = UserKeyMappingEntry(source: 0x700000039, destination: 0x70000006D)

    static func merge(existing: [UserKeyMappingEntry], adding entry: UserKeyMappingEntry) -> [UserKeyMappingEntry] {
        var result = existing.filter { $0.source != entry.source }
        result.append(entry)
        return result
    }

    static func remove(existing: [UserKeyMappingEntry], removing entry: UserKeyMappingEntry = capsLockToF18) -> [UserKeyMappingEntry] {
        existing.filter { $0 != entry }
    }

    /// Parses the property-list style output from `hidutil property --get UserKeyMapping`.
    static func parse(_ output: String) -> [UserKeyMappingEntry]? {
        guard output.localizedCaseInsensitiveContains("UserKeyMapping") else { return nil }
        let blocks = matches(in: output, pattern: #"\{[^{}]*\}"#)
        if blocks.isEmpty {
            let tail = output.components(separatedBy: ":").dropFirst().joined(separator: ":")
            let compact = tail.filter { !$0.isWhitespace }
            return compact == "()" || compact == "[]" ? [] : nil
        }
        var entries: [UserKeyMappingEntry] = []
        for block in blocks {
            guard let source = number(named: "HIDKeyboardModifierMappingSrc", in: block),
                  let destination = number(named: "HIDKeyboardModifierMappingDst", in: block) else { return nil }
            entries.append(UserKeyMappingEntry(source: source, destination: destination))
        }
        return entries
    }

    private static func number(named name: String, in text: String) -> UInt64? {
        let pattern = #"[\"']?\#(name)[\"']?\s*(?:=|:)\s*[\"']?(0[xX][0-9a-fA-F]+|[0-9]+)"#
        guard let value = matches(in: text, pattern: pattern).first else { return nil }
        if value.hasPrefix("0x") || value.hasPrefix("0X") { return UInt64(value.dropFirst(2), radix: 16) }
        return UInt64(value)
    }

    private static func matches(in text: String, pattern: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            guard let range = Range(match.range(at: match.numberOfRanges > 1 ? 1 : 0), in: text) else { return nil }
            return String(text[range])
        }
    }
}

enum KeysFeature {
    private static let tapActionKey = "notch.keys.tapAction"

    static func apply(_ feature: NotchFeature, enabled: Bool) {
        guard feature == .superKey else { return }
        guard enabled else {
            NotchSystemHelperClient.shared.perform("keys", "disable")
            return
        }
        guard AXIsProcessTrusted() else {
            NotchSystemHelperClient.shared.perform("keys", "disable")
            return
        }

        let defaults = UserDefaults.standard
        let tapAction = HyperTapAction(rawValue: defaults.string(forKey: tapActionKey) ?? "") ?? .escape
        NotchSystemHelperClient.shared.perform(
            "keys",
            "enable",
            args: [
                "tapAction": tapAction.rawValue,
                "shortcuts": HyperShortcutCodec.runtimeEntries(HyperShortcutCodec.load(defaults: defaults))
            ],
            timeout: 2
        )
    }

    static func tapAction(defaults: UserDefaults = .standard) -> HyperTapAction {
        HyperTapAction(rawValue: defaults.string(forKey: tapActionKey) ?? "") ?? .escape
    }

    static func setTapAction(_ action: HyperTapAction, defaults: UserDefaults = .standard) {
        defaults.set(action.rawValue, forKey: tapActionKey)
    }
}

struct KeyboardSettingsSection: View {
    @AppStorage("notch.feature.superKey") private var featureEnabled = NotchFeature.superKey.defaultEnabled
    @State private var tapAction = KeysFeature.tapAction()
    @State private var shortcuts = HyperShortcutCodec.load()
    @State private var appHasAccessibility = AXIsProcessTrusted()
    @State private var helperHasAccessibility: Bool?

    private var accessibilityMissing: Bool {
        !appHasAccessibility || helperHasAccessibility == false
    }

    var body: some View {
        Section("Keyboard") {
            NotchFeatureToggle(.superKey, "Super key", detail: "Use Caps Lock as Hyper and trigger keyboard shortcuts.")

            Picker("When tapped alone", selection: $tapAction) {
                ForEach(HyperTapAction.allCases) { action in
                    Text(action.title).tag(action)
                }
            }
            .help("Choose what a quick Caps Lock tap sends.")
            .accessibilityIdentifier("keys-tap-action")
            .onChange(of: tapAction) { _, value in
                KeysFeature.setTapAction(value)
                if featureEnabled { KeysFeature.apply(.superKey, enabled: true) }
            }

            if accessibilityMissing {
                HStack(spacing: 8) {
                    Text("Accessibility is needed to remap Caps Lock and read Hyper shortcuts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open Settings") {
                        if let url = NotchPermission.accessibility.settingsURL { NSWorkspace.shared.open(url) }
                    }
                    .frame(minHeight: 28)
                    .contentShape(Rectangle())
                    .help("Open Accessibility privacy settings.")
                    .accessibilityIdentifier("keys-open-accessibility-settings")
                    Button("Check Again") { refreshPermission() }
                        .frame(minHeight: 28)
                        .contentShape(Rectangle())
                        .help("Check Accessibility permission again.")
                        .accessibilityIdentifier("keys-check-accessibility")
                }
            }

            HStack(spacing: 8) {
                Text("Hyper + key").font(.caption).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                Text("Action").font(.caption).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
                Text("Target").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: 28)
            }
            ForEach($shortcuts) { $shortcut in
                HStack(spacing: 8) {
                    TextField("Key", text: $shortcut.key)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .frame(minHeight: 28)
                        .help("Type one key to combine with Hyper.")
                        .accessibilityIdentifier("keys-shortcut-key-\(shortcut.id.uuidString)")
                    Picker("Action", selection: $shortcut.action) {
                        ForEach(HyperShortcutAction.allCases) { action in
                            Text(action.title).tag(action)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                    .frame(minHeight: 28)
                    .help("Choose what this Hyper shortcut does.")
                    .accessibilityLabel("Action for Hyper + \(shortcut.key.isEmpty ? "key" : shortcut.key)")
                    .accessibilityIdentifier("keys-shortcut-action-\(shortcut.id.uuidString)")
                    TextField(shortcut.action.targetPrompt, text: $shortcut.target)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 28)
                        .help(shortcut.action.targetPrompt)
                        .accessibilityIdentifier("keys-shortcut-target-\(shortcut.id.uuidString)")
                    Button {
                        shortcuts.removeAll { $0.id == shortcut.id }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
                    .help("Delete this Hyper shortcut.")
                    .accessibilityLabel("Delete Hyper shortcut")
                    .accessibilityIdentifier("keys-shortcut-delete-\(shortcut.id.uuidString)")
                }
                .frame(minHeight: 28)
            }
            Button {
                guard shortcuts.count < HyperShortcutCodec.maximumEntries else { return }
                shortcuts.append(HyperShortcut())
            } label: {
                Label("Add Shortcut", systemImage: "plus")
            }
            .disabled(shortcuts.count >= HyperShortcutCodec.maximumEntries)
            .frame(minHeight: 28)
            .contentShape(Rectangle())
            .help("Add a Hyper shortcut. Up to 20 entries are supported.")
            .accessibilityIdentifier("keys-shortcut-add")
        }
        .onAppear(perform: refreshPermission)
        .onChange(of: featureEnabled) { _, enabled in
            KeysFeature.apply(.superKey, enabled: enabled)
            refreshPermission()
        }
        .onChange(of: shortcuts) { _, value in
            HyperShortcutCodec.save(value)
            if featureEnabled { KeysFeature.apply(.superKey, enabled: true) }
        }
    }

    private func refreshPermission() {
        appHasAccessibility = AXIsProcessTrusted()
        guard appHasAccessibility else {
            helperHasAccessibility = false
            return
        }
        NotchSystemHelperClient.shared.perform("keys", "status", timeout: 2) { response in
            DispatchQueue.main.async {
                helperHasAccessibility = response?["accessibilityTrusted"] as? Bool
            }
        }
    }
}
