import AppKit
import ApplicationServices
import Carbon
import Combine
import SwiftUI

enum SensitiveText {
    static func isLikelySecret(_ text: String) -> Bool {
        guard text.index(text.startIndex, offsetBy: 12, limitedBy: text.endIndex) != nil,
              text.index(text.startIndex, offsetBy: 129, limitedBy: text.endIndex) == nil,
              !text.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains),
              !looksLikeURLOrPath(text) else { return false }

        var punctuationAndSymbols = CharacterSet.punctuationCharacters
        punctuationAndSymbols.formUnion(.symbols)
        var classes = Set<Int>()
        for scalar in text.unicodeScalars {
            if CharacterSet.lowercaseLetters.contains(scalar) { classes.insert(0) }
            if CharacterSet.uppercaseLetters.contains(scalar) { classes.insert(1) }
            if CharacterSet.decimalDigits.contains(scalar) { classes.insert(2) }
            if punctuationAndSymbols.contains(scalar) { classes.insert(3) }
        }
        return classes.count >= 3
    }

    private static func looksLikeURLOrPath(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        if text.contains("/") || text.contains("\\") || lowercased.contains("://") { return true }
        if ["http:", "https:", "ftp:", "file:", "mailto:", "ssh:", "data:", "blob:"].contains(where: lowercased.hasPrefix) { return true }
        if text.contains("@") { return true }
        if text.hasPrefix("~/") || text.hasPrefix("./") || text.hasPrefix("../") { return true }
        if lowercased.hasPrefix("www.") { return true }
        if lowercased.filter({ $0 == ":" }).count > 1,
           lowercased.allSatisfy({ $0.isNumber || ("abcdef:".contains($0)) }) { return true }
        let domainParts = lowercased.split(separator: ".")
        if domainParts.count >= 2 {
            let finalPart = domainParts.last?.split(whereSeparator: { "?&#".contains($0) }).first ?? ""
            let labels = domainParts.dropLast()
            if finalPart.count >= 2,
               finalPart.allSatisfy(\.isLetter),
               labels.allSatisfy({ label in label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }) {
                return true
            }
        }
        return false
    }
}

enum ClipboardSensitivity {
    static let sensitiveTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType"
    ]

    static func isSensitive(types: Set<String>, text: String?) -> Bool {
        !types.isDisjoint(with: sensitiveTypes) || text.map(SensitiveText.isLikelySecret) == true
    }
}

enum ClipboardAutoClearPolicy {
    static func shouldClear(
        capturedChangeCount: Int,
        currentChangeCount: Int,
        elapsed: TimeInterval,
        delay: TimeInterval
    ) -> Bool {
        capturedChangeCount == currentChangeCount && delay > 0 && elapsed >= delay
    }
}

enum ClipboardFeature {
    static func apply(_ feature: NotchFeature, enabled: Bool) {
        guard [.clipboardAutoClear, .plainTextPaste, .finderTools].contains(feature) else { return }
        Task { @MainActor in
            ClipboardFeatureRuntime.shared.apply(feature, enabled: enabled)
        }
    }

    static func updateAutoClearDelay(_ seconds: Int) {
        Task { @MainActor in
            ClipboardFeatureRuntime.shared.updateAutoClearDelay(seconds)
        }
    }
}

@MainActor
private final class ClipboardFeatureRuntime {
    static let shared = ClipboardFeatureRuntime()

    private var autoClearTimer: DispatchSourceTimer?
    private var historyFilterSubscription: AnyCancellable?
    private var autoClearEnabled = false
    private var autoClearDelay = UserDefaults.standard.integer(forKey: "notch.clipboard.autoClearDelay")
    private var lastObservedChangeCount: Int?
    private var pendingClear: PendingClear?
    private var pendingRestore: PendingPasteRestore?

    private struct PendingClear {
        let changeCount: Int
        let startedAt: TimeInterval
    }

    private struct PendingPasteRestore {
        let id: UUID
        let snapshot: PasteboardSnapshot
        let temporaryChangeCount: Int
        let work: DispatchWorkItem
    }

    private init() {
        if ![10, 30, 60, 120].contains(autoClearDelay) { autoClearDelay = 30 }
    }

    func apply(_ feature: NotchFeature, enabled: Bool) {
        switch feature {
        case .clipboardAutoClear:
            setAutoClearEnabled(enabled)
        case .plainTextPaste, .finderTools:
            setHotKeyEnabled(feature, enabled)
        default:
            break
        }
    }

    func updateAutoClearDelay(_ seconds: Int) {
        guard [10, 30, 60, 120].contains(seconds) else { return }
        autoClearDelay = seconds
    }

    private func setAutoClearEnabled(_ enabled: Bool) {
        guard autoClearEnabled != enabled else { return }
        autoClearEnabled = enabled
        if enabled {
            observeSensitiveHistory()
            lastObservedChangeCount = nil
            pollPasteboard()
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(150))
            timer.setEventHandler { [weak self] in
                Task { @MainActor in self?.pollPasteboard() }
            }
            autoClearTimer = timer
            timer.resume()
        } else {
            historyFilterSubscription?.cancel()
            historyFilterSubscription = nil
            autoClearTimer?.setEventHandler {}
            autoClearTimer?.cancel()
            autoClearTimer = nil
            pendingClear = nil
            lastObservedChangeCount = nil
        }
    }

    private func pollPasteboard(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard autoClearEnabled else { return }
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        let types = Set((pasteboard.types ?? []).map(\.rawValue))
        let text = pasteboard.string(forType: .string)

        // ClipboardStore has its own bounded history. Remove heuristic secrets as
        // soon as they are observed so the opt-in history does not retain them.
        removeSensitiveHistory()

        if lastObservedChangeCount != changeCount {
            lastObservedChangeCount = changeCount
            if ClipboardSensitivity.isSensitive(types: types, text: text) {
                pendingClear = PendingClear(changeCount: changeCount, startedAt: now)
            } else {
                pendingClear = nil
            }
        }

        guard let pendingClear,
              ClipboardAutoClearPolicy.shouldClear(
                capturedChangeCount: pendingClear.changeCount,
                currentChangeCount: pasteboard.changeCount,
                elapsed: now - pendingClear.startedAt,
                delay: TimeInterval(autoClearDelay)
              ) else { return }
        pasteboard.clearContents()
        lastObservedChangeCount = pasteboard.changeCount
        self.pendingClear = nil
    }

    private func removeSensitiveHistory() {
        let store = ClipboardStore.shared
        removeSensitiveHistory(in: store.history)
    }

    private func observeSensitiveHistory() {
        historyFilterSubscription?.cancel()
        historyFilterSubscription = ClipboardStore.shared.$history.sink { [weak self] entries in
            let ids = entries
                .filter { SensitiveText.isLikelySecret($0.text) }
                .map(\.id)
            guard !ids.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.removeSensitiveHistory(ids: ids)
            }
        }
    }

    private func removeSensitiveHistory(in entries: [ClipboardEntry]) {
        removeSensitiveHistory(ids: entries.filter { SensitiveText.isLikelySecret($0.text) }.map(\.id))
    }

    private func removeSensitiveHistory(ids: [UUID]) {
        let store = ClipboardStore.shared
        for id in ids { store.remove(id) }
    }

    private func setHotKeyEnabled(_ feature: NotchFeature, _ enabled: Bool) {
        guard enabled else {
            ClipboardHotKeyCenter.shared.setEnabled(feature, false)
            if feature == .plainTextPaste { restorePendingPaste() }
            return
        }
        ClipboardHotKeyCenter.shared.setEnabled(feature, true)
    }

    func handleHotKey(_ id: UInt32) {
        switch id {
        case ClipboardHotKeyCenter.plainTextPasteID:
            pasteAsPlainText()
        case ClipboardHotKeyCenter.copyPathID:
            performFinderAction("copyPath")
        case ClipboardHotKeyCenter.newFileID:
            promptForNewFile()
        case ClipboardHotKeyCenter.openTerminalID:
            performFinderAction("openTerminal")
        default:
            break
        }
    }

    private func pasteAsPlainText() {
        restorePendingPaste()
        guard AXIsProcessTrusted(),
              let text = NSPasteboard.general.string(forType: .string),
              !text.isEmpty,
              let snapshot = PasteboardSnapshot.capture(from: .general) else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            pasteboard.clearContents()
            snapshot.restore(to: pasteboard)
            return
        }

        let id = UUID()
        let count = pasteboard.changeCount
        let work = DispatchWorkItem { [weak self] in self?.restorePendingPaste(id: id) }
        pendingRestore = PendingPasteRestore(id: id, snapshot: snapshot, temporaryChangeCount: count, work: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        NotchSystemHelperClient.shared.perform("clipboard", "pasteKey", timeout: 2) { [weak self] reply in
            guard reply?["ok"] as? Bool != true else { return }
            Task { @MainActor in self?.restorePendingPaste(id: id) }
        }
    }

    private func restorePendingPaste() {
        guard let pendingRestore else { return }
        pendingRestore.work.cancel()
        restorePendingPaste(id: pendingRestore.id)
    }

    private func restorePendingPaste(id: UUID) {
        guard let pendingRestore, pendingRestore.id == id else { return }
        pendingRestore.work.cancel()
        self.pendingRestore = nil
        guard NSPasteboard.general.changeCount == pendingRestore.temporaryChangeCount else { return }
        NSPasteboard.general.clearContents()
        pendingRestore.snapshot.restore(to: .general)
    }

    private func promptForNewFile() {
        guard ClipboardPermissionChecks.hasAutomationAccess(to: "com.apple.finder") else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Create an empty text file"
        alert.informativeText = "Choose a name for the new file in the front Finder folder."
        let nameField = NSTextField(string: "Untitled.txt")
        nameField.frame.size.width = 260
        alert.accessoryView = nameField
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        performFinderAction("newFile", args: ["name": nameField.stringValue])
    }

    private func performFinderAction(_ action: String, args: [String: Any] = [:]) {
        let targets = action == "openTerminal" ? ["com.apple.finder", "com.apple.Terminal"] : ["com.apple.finder"]
        guard targets.allSatisfy(ClipboardPermissionChecks.hasAutomationAccess(to:)) else { return }
        NotchSystemHelperClient.shared.perform("clipboard", action, args: args, timeout: 2)
    }
}

private struct PasteboardSnapshot {
    let items: [NSPasteboardItem]

    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot? {
        guard let sourceItems = pasteboard.pasteboardItems, !sourceItems.isEmpty else { return nil }
        guard sourceItems.count <= 64 else { return nil }
        var copies: [NSPasteboardItem] = []
        copies.reserveCapacity(sourceItems.count)
        var totalBytes = 0
        let maximumSnapshotBytes = 32 * 1024 * 1024
        for item in sourceItems {
            guard item.types.count <= 128 else { return nil }
            let copy = NSPasteboardItem()
            for type in item.types {
                guard let data = item.data(forType: type) else { return nil }
                totalBytes += data.count
                guard totalBytes <= maximumSnapshotBytes else { return nil }
                copy.setData(data, forType: type)
            }
            copies.append(copy)
        }
        return PasteboardSnapshot(items: copies)
    }

    func restore(to pasteboard: NSPasteboard) {
        _ = pasteboard.writeObjects(items)
    }
}

@MainActor
private final class ClipboardHotKeyCenter {
    static let shared = ClipboardHotKeyCenter()
    static let plainTextPasteID: UInt32 = 1
    static let copyPathID: UInt32 = 2
    static let newFileID: UInt32 = 3
    static let openTerminalID: UInt32 = 4

    private static let signature: OSType = 0x4E746368 // Ntch
    private var handler: EventHandlerRef?
    private var registrations: [NotchFeature: [EventHotKeyRef]] = [:]

    private init() {}

    func setEnabled(_ feature: NotchFeature, _ enabled: Bool) {
        if enabled {
            guard registrations[feature] == nil,
                  installHandlerIfNeeded() else { return }
            let shortcuts = Self.shortcuts(for: feature)
            guard !shortcuts.isEmpty else {
                if registrations.isEmpty { removeHandler() }
                return
            }
            var references: [EventHotKeyRef] = []
            for shortcut in shortcuts {
                var reference: EventHotKeyRef?
                let identifier = EventHotKeyID(signature: Self.signature, id: shortcut.id)
                let status = RegisterEventHotKey(
                    shortcut.keyCode,
                    shortcut.modifiers,
                    identifier,
                    GetApplicationEventTarget(),
                    0,
                    &reference
                )
                if status == noErr, let reference { references.append(reference) }
            }
            if references.count == shortcuts.count {
                registrations[feature] = references
            } else {
                for reference in references { UnregisterEventHotKey(reference) }
                if registrations.isEmpty { removeHandler() }
            }
        } else {
            if let references = registrations.removeValue(forKey: feature) {
                for reference in references { UnregisterEventHotKey(reference) }
            }
            if registrations.isEmpty { removeHandler() }
        }
    }

    private func installHandlerIfNeeded() -> Bool {
        guard handler == nil else { return true }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.eventHandler,
            1,
            &eventType,
            nil,
            &handler
        )
        return status == noErr
    }

    private func removeHandler() {
        guard let handler else { return }
        RemoveEventHandler(handler)
        self.handler = nil
    }

    private static let eventHandler: EventHandlerProcPtr = { _, event, _ in
        guard let event else { return OSStatus(eventNotHandledErr) }
        var identifier = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &identifier
        )
        guard status == noErr, identifier.signature == ClipboardHotKeyCenter.signature else {
            return status == noErr ? OSStatus(eventNotHandledErr) : status
        }
        Task { @MainActor in ClipboardFeatureRuntime.shared.handleHotKey(identifier.id) }
        return noErr
    }

    private static func shortcuts(for feature: NotchFeature) -> [(keyCode: UInt32, modifiers: UInt32, id: UInt32)] {
        switch feature {
        case .plainTextPaste:
            return [(UInt32(kVK_ANSI_V), UInt32(cmdKey | optionKey | shiftKey), plainTextPasteID)]
        case .finderTools:
            return [
                (UInt32(kVK_ANSI_C), UInt32(controlKey | optionKey), copyPathID),
                (UInt32(kVK_ANSI_N), UInt32(controlKey | optionKey), newFileID),
                (UInt32(kVK_ANSI_T), UInt32(controlKey | optionKey), openTerminalID)
            ]
        default:
            return []
        }
    }
}

private enum ClipboardPermissionChecks {
    static func hasAutomationAccess(to bundleIdentifier: String) -> Bool {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier)
        return AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, false) == noErr
    }
}

struct ClipboardSettingsSection: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("notch.clipboard.autoClearDelay") private var autoClearDelay = 30
    @AppStorage("notch.feature.clipboardAutoClear") private var autoClearEnabled = false
    @AppStorage("notch.feature.plainTextPaste") private var plainTextPasteEnabled = false
    @AppStorage("notch.feature.finderTools") private var finderToolsEnabled = false
    @State private var accessibilityAllowed = AXIsProcessTrusted()
    @State private var finderAutomationAllowed = ClipboardPermissionChecks.hasAutomationAccess(to: "com.apple.finder")
    @State private var terminalAutomationAllowed = ClipboardPermissionChecks.hasAutomationAccess(to: "com.apple.Terminal")

    var body: some View {
        Section("Clipboard") {
            NotchFeatureToggle(.clipboardAutoClear, "Auto-clear sensitive clipboard", detail: "Clear concealed or password-like text after the selected delay.")
                .help("Clear sensitive clipboard contents after the selected delay.")
            Picker("Clear after", selection: $autoClearDelay) {
                ForEach([10, 30, 60, 120], id: \.self) { seconds in
                    Text("\(seconds) seconds").tag(seconds)
                }
            }
            .disabled(!autoClearEnabled)
            .frame(minHeight: 28)
            .help("Choose how long sensitive clipboard contents remain available.")
            .accessibilityIdentifier("clipboard-auto-clear-delay")
            .onChange(of: autoClearDelay) { _, value in ClipboardFeature.updateAutoClearDelay(value) }

            NotchFeatureToggle(.plainTextPaste, "Paste as plain text", detail: "Use ⌘⌥⇧V to paste without formatting.")
                .help("Register the global ⌘⌥⇧V plain text paste shortcut.")
            Text("Hotkey: ⌘⌥⇧V")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("clipboard-plain-text-hotkey")
            if plainTextPasteEnabled, !accessibilityAllowed {
                permissionRow(.accessibility, explanation: "Plain text paste needs Accessibility to send ⌘V.")
            }
        }

        Section("Finder Tools") {
            NotchFeatureToggle(.finderTools, "Finder tools", detail: "Run common Finder actions from anywhere.")
                .help("Register global shortcuts for Finder path, new file, and Terminal actions.")
            Text("Copy path: ⌃⌥C   ·   New file: ⌃⌥N   ·   Terminal: ⌃⌥T")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("clipboard-finder-hotkeys")
            if finderToolsEnabled, !finderAutomationAllowed || !terminalAutomationAllowed {
                permissionRow(.automation, explanation: "Finder tools need Automation access for Finder and Terminal.")
            }
        }
        .onAppear {
            if ![10, 30, 60, 120].contains(autoClearDelay) { autoClearDelay = 30 }
            refreshPermissions()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshPermissions() }
        }
    }

    @ViewBuilder
    private func permissionRow(_ permission: NotchPermission, explanation: String) -> some View {
        HStack(spacing: 8) {
            Text(explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button("Open Settings") {
                refreshPermissions()
                if let url = permission.settingsURL { NSWorkspace.shared.open(url) }
            }
            .frame(minHeight: 28)
            .contentShape(Rectangle())
            .help("Open \(permission.title) settings.")
            .accessibilityIdentifier("clipboard-open-\(permission.rawValue)-settings")
        }
    }

    private func refreshPermissions() {
        accessibilityAllowed = AXIsProcessTrusted()
        finderAutomationAllowed = ClipboardPermissionChecks.hasAutomationAccess(to: "com.apple.finder")
        terminalAutomationAllowed = ClipboardPermissionChecks.hasAutomationAccess(to: "com.apple.Terminal")
    }
}
