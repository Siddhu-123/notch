import AppKit
import ApplicationServices
import Carbon
import Foundation
import SwiftUI

enum SnapPosition: String, CaseIterable {
    case left, right, top, bottom, maximize, center
}

enum SnapGeometry {
    /// Returns AppKit coordinates by default. Pass the desktop's top y coordinate
    /// to flip the result into AX's top-left global coordinate system.
    static func frame(for position: SnapPosition, in visibleFrame: CGRect, desktopTop: CGFloat? = nil) -> CGRect {
        let halfWidth = floor(visibleFrame.width / 2)
        let halfHeight = floor(visibleFrame.height / 2)
        let appKitFrame: CGRect
        switch position {
        case .left:
            appKitFrame = CGRect(x: visibleFrame.minX, y: visibleFrame.minY, width: halfWidth, height: visibleFrame.height)
        case .right:
            appKitFrame = CGRect(x: visibleFrame.minX + halfWidth, y: visibleFrame.minY, width: visibleFrame.width - halfWidth, height: visibleFrame.height)
        case .top:
            appKitFrame = CGRect(x: visibleFrame.minX, y: visibleFrame.minY + halfHeight, width: visibleFrame.width, height: visibleFrame.height - halfHeight)
        case .bottom:
            appKitFrame = CGRect(x: visibleFrame.minX, y: visibleFrame.minY, width: visibleFrame.width, height: halfHeight)
        case .maximize:
            appKitFrame = visibleFrame
        case .center:
            let size = CGSize(width: halfWidth, height: halfHeight)
            appKitFrame = CGRect(x: visibleFrame.midX - size.width / 2, y: visibleFrame.midY - size.height / 2, width: size.width, height: size.height)
        }
        guard let desktopTop else { return appKitFrame }
        return CGRect(
            x: appKitFrame.minX,
            y: desktopTop - appKitFrame.maxY,
            width: appKitFrame.width,
            height: appKitFrame.height
        )
    }
}

enum QuitPolicy {
    static let finderBundleID = "com.apple.finder"

    static func shouldQuit(bundleID: String, windowCount: Int, excluded: Set<String>) -> Bool {
        guard windowCount == 0 else { return false }
        let bundle = bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !bundle.isEmpty, bundle != finderBundleID else { return false }
        return !excluded.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == bundle }
    }
}

struct QuitGuard: Equatable {
    enum Event: Equatable {
        case commandQDown(at: TimeInterval)
        case commandQUp(at: TimeInterval)
        case holdThresholdReached(at: TimeInterval)
    }

    enum Effect: Equatable {
        case swallowAndPrompt
        case passThrough
        case synthesizeQuit
        case swallow
        case none
    }

    static let doublePressWindow: TimeInterval = 1
    static let holdThreshold: TimeInterval = 0.6

    private var firstPressAt: TimeInterval?
    private var heldSince: TimeInterval?
    private var passingCurrentPress = false
    private var awaitingPhysicalKeyUp = false

    mutating func process(_ event: Event) -> Effect {
        switch event {
        case let .commandQDown(at):
            guard !awaitingPhysicalKeyUp else { return .swallow }
            guard heldSince == nil else { return passingCurrentPress ? .passThrough : .swallow }
            if let firstPressAt, at >= firstPressAt, at - firstPressAt < Self.doublePressWindow {
                self.firstPressAt = nil
                heldSince = at
                passingCurrentPress = true
                return .passThrough
            }
            firstPressAt = at
            heldSince = at
            passingCurrentPress = false
            return .swallowAndPrompt

        case let .commandQUp(at):
            if awaitingPhysicalKeyUp {
                awaitingPhysicalKeyUp = false
                return .swallow
            }
            guard let heldSince else { return .none }
            let elapsed = max(0, at - heldSince)
            self.heldSince = nil
            if passingCurrentPress {
                passingCurrentPress = false
                return .passThrough
            }
            if elapsed + 0.000_000_001 >= Self.holdThreshold {
                firstPressAt = nil
                return .synthesizeQuit
            }
            return .swallow

        case let .holdThresholdReached(at):
            guard let heldSince, !passingCurrentPress,
                  at - heldSince + 0.000_000_001 >= Self.holdThreshold else { return .none }
            self.heldSince = nil
            firstPressAt = nil
            awaitingPhysicalKeyUp = true
            return .synthesizeQuit
        }
    }
}

enum QuitExclusionList {
    static let defaultsKey = "notch.windows.quitExclusions"
    static let maximumEntries = 50

    static func normalize(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard text.count <= 255,
              text.contains("."),
              text.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty }),
              text.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-").contains($0) }) else {
            return nil
        }
        return text
    }

    static func load(defaults: UserDefaults = .standard) -> [String] {
        Array((defaults.stringArray(forKey: defaultsKey) ?? []).prefix(maximumEntries))
    }

    static func adding(_ value: String, to entries: [String]) -> [String] {
        guard let bundleID = normalize(value), entries.count < maximumEntries,
              !entries.contains(where: { $0.caseInsensitiveCompare(bundleID) == .orderedSame }) else { return entries }
        return entries + [bundleID]
    }
}

enum WindowsFeature {
    static func apply(_ feature: NotchFeature, enabled: Bool) {
        guard feature.group == .windows else { return }
        let allowed = enabled && AXIsProcessTrusted()
        DispatchQueue.main.async {
            WindowsAppRuntime.shared.setEnabled(feature, enabled: allowed)
        }
        if allowed {
            NotchSystemHelperClient.shared.perform(
                "windows", "setFeature",
                args: [
                    "feature": feature.rawValue,
                    "enabled": true,
                    "excludedBundleIDs": helperExclusions()
                ],
                timeout: 2
            ) { response in
                guard response?["ok"] as? Bool == true else {
                    NotchSystemHelperClient.shared.perform(
                        "windows", "setFeature",
                        args: ["feature": feature.rawValue, "enabled": false],
                        timeout: 2
                    )
                    DispatchQueue.main.async { WindowsAppRuntime.shared.setEnabled(feature, enabled: false) }
                    return
                }
            }
        } else {
            NotchSystemHelperClient.shared.perform(
                "windows", "setFeature",
                args: ["feature": feature.rawValue, "enabled": false],
                timeout: 2
            )
        }
    }

    static func helperExclusions(defaults: UserDefaults = .standard) -> [String] {
        var values = QuitExclusionList.load(defaults: defaults)
        values.append(QuitPolicy.finderBundleID)
        if let ownBundleID = Bundle.main.bundleIdentifier { values.append(ownBundleID.lowercased()) }
        return Array(Set(values.map { $0.lowercased() }).prefix(QuitExclusionList.maximumEntries + 2))
    }
}

private struct WindowSwitcherItem: Identifiable {
    let pid: Int
    let index: Int
    let windowNumber: Int
    let app: String
    let title: String
    let icon: NSImage

    var id: String { "\(pid)-\(windowNumber)-\(index)" }
}

private struct WindowSwitcherView: View {
    let items: [WindowSwitcherItem]
    let selectedIndex: Int
    let select: (Int) -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Windows").font(.system(size: 15, weight: .semibold, design: .rounded))
                Spacer()
                Text("⌥ Tab to cycle · release ⌥ to focus")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
                Button(action: close) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 15))
                }
                .buttonStyle(.plain)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
                .help("Close the window switcher.")
                .accessibilityIdentifier("windows-switcher-close")
            }
            if items.isEmpty {
                Text("No app windows found.")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.white.opacity(0.68))
                    .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                Button { select(index) } label: {
                                    HStack(spacing: 9) {
                                        Image(nsImage: item.icon).resizable().frame(width: 19, height: 19)
                                        Text(item.title.isEmpty ? "Untitled window" : item.title)
                                            .font(.system(size: 12, weight: .medium, design: .rounded))
                                            .lineLimit(1)
                                        Spacer(minLength: 8)
                                        Text(item.app)
                                            .font(.system(size: 10, design: .rounded))
                                            .foregroundStyle(.white.opacity(0.58))
                                            .lineLimit(1)
                                    }
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 8)
                                    .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32)
                                    .contentShape(Rectangle())
                                    .background(.white.opacity(index == selectedIndex ? 0.13 : 0.05), in: RoundedRectangle(cornerRadius: 12))
                                }
                                .buttonStyle(.plain)
                                .help("Focus \(item.title.isEmpty ? item.app : item.title).")
                                .accessibilityIdentifier("windows-switcher-row-\(index)")
                                .id(index)
                            }
                        }
                    }
                    .frame(maxHeight: 350)
                    .onChange(of: selectedIndex) { _, value in proxy.scrollTo(value, anchor: .center) }
                }
            }
        }
        .padding(12)
        .foregroundStyle(.white)
        .frame(width: 620)
        .background(Color.black, in: RoundedRectangle(cornerRadius: 14))
    }
}

private final class WindowSwitcherPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class WindowsAppRuntime {
    static let shared = WindowsAppRuntime()

    private struct HotKey {
        let keyCode: UInt32
        let modifiers: UInt32
        let id: UInt32
    }

    fileprivate static let signature: OSType = 0x4E574A35 // NWJ5
    private let switcherHotKeyID: UInt32 = 1
    private let reverseSwitcherHotKeyID: UInt32 = 2
    private let snapLeftID: UInt32 = 3
    private let snapRightID: UInt32 = 4
    private let snapTopID: UInt32 = 5
    private let snapMaximizeID: UInt32 = 6

    private var enabledFeatures = Set<String>()
    private var eventHandler: EventHandlerRef?
    private var hotKeys: [UInt32: EventHotKeyRef] = [:]
    private var switcherPanel: WindowSwitcherPanel?
    private var switcherItems: [WindowSwitcherItem] = []
    private var selectedIndex = 0
    private var switcherRequested = false
    private var switcherInitialDirection = 1
    private var switcherListLoaded = false
    private var switcherOptionReleased = false
    private var switcherPendingCycles = 0
    private var eventPollTimer: Timer?
    private var eventPollInFlight = false

    private init() {}

    func setEnabled(_ feature: NotchFeature, enabled: Bool) {
        if enabled { enabledFeatures.insert(feature.rawValue) } else { enabledFeatures.remove(feature.rawValue) }
        if feature == .windowSwitcher, !enabled { closeSwitcher(notifyHelper: true) }
        rebuildHotKeys()
        updateEventPolling()
    }

    func handleHotKey(_ id: UInt32) {
        switch id {
        case switcherHotKeyID:
            if switcherRequested { cycleSelection(forward: true) } else { openSwitcher(forward: true) }
        case reverseSwitcherHotKeyID:
            if switcherRequested { cycleSelection(forward: false) } else { openSwitcher(forward: false) }
        case snapLeftID: sendSnap(.left)
        case snapRightID: sendSnap(.right)
        case snapTopID: sendSnap(.top)
        case snapMaximizeID: sendSnap(.maximize)
        default: break
        }
    }

    private func rebuildHotKeys() {
        for reference in hotKeys.values { UnregisterEventHotKey(reference) }
        hotKeys.removeAll(keepingCapacity: true)

        var bindings: [HotKey] = []
        if enabledFeatures.contains(NotchFeature.windowSwitcher.rawValue) {
            bindings.append(HotKey(keyCode: UInt32(kVK_Tab), modifiers: UInt32(optionKey), id: switcherHotKeyID))
            bindings.append(HotKey(keyCode: UInt32(kVK_Tab), modifiers: UInt32(optionKey | shiftKey), id: reverseSwitcherHotKeyID))
        }
        if enabledFeatures.contains(NotchFeature.windowSnapping.rawValue) {
            let modifiers = UInt32(controlKey | optionKey)
            bindings.append(HotKey(keyCode: UInt32(kVK_LeftArrow), modifiers: modifiers, id: snapLeftID))
            bindings.append(HotKey(keyCode: UInt32(kVK_RightArrow), modifiers: modifiers, id: snapRightID))
            bindings.append(HotKey(keyCode: UInt32(kVK_UpArrow), modifiers: modifiers, id: snapTopID))
            bindings.append(HotKey(keyCode: UInt32(kVK_Return), modifiers: modifiers, id: snapMaximizeID))
        }

        guard !bindings.isEmpty else {
            if let eventHandler { RemoveEventHandler(eventHandler); self.eventHandler = nil }
            return
        }
        installCarbonHandlerIfNeeded()
        for binding in bindings {
            var identifier = EventHotKeyID()
            identifier.signature = Self.signature
            identifier.id = binding.id
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(
                binding.keyCode,
                binding.modifiers,
                identifier,
                GetApplicationEventTarget(),
                0,
                &reference
            )
            if status == noErr, let reference { hotKeys[binding.id] = reference }
        }
    }

    private func installCarbonHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            windowsCarbonEventHandler,
            1,
            &eventType,
            nil,
            &eventHandler
        )
    }

    private func openSwitcher(forward: Bool) {
        guard enabledFeatures.contains(NotchFeature.windowSwitcher.rawValue) else { return }
        switcherRequested = true
        switcherInitialDirection = forward ? 1 : -1
        switcherListLoaded = false
        switcherOptionReleased = false
        switcherPendingCycles = 0
        switcherItems = []
        selectedIndex = forward ? 0 : -1
        NotchSystemHelperClient.shared.perform("windows", "beginSwitcher")
        NotchSystemHelperClient.shared.perform("windows", "listWindows", timeout: 2) { [weak self] response in
            DispatchQueue.main.async {
                guard let self, self.switcherRequested else { return }
                self.switcherItems = Self.windowItems(from: response?["windows"] as? [[String: Any]] ?? [])
                self.selectedIndex = self.switcherItems.isEmpty || self.switcherInitialDirection > 0
                    ? 0
                    : self.switcherItems.count - 1
                if !self.switcherItems.isEmpty, self.switcherPendingCycles != 0 {
                    let count = self.switcherItems.count
                    self.selectedIndex = (self.selectedIndex + self.switcherPendingCycles % count + count) % count
                }
                self.switcherPendingCycles = 0
                self.switcherListLoaded = true
                self.showSwitcher()
                self.updateEventPolling()
                if self.switcherOptionReleased { self.focusWindow(at: self.selectedIndex) }
            }
        }
        showSwitcher()
        updateEventPolling()
    }

    private func showSwitcher() {
        let visibleRows = min(max(switcherItems.count, 1), 10)
        let height = CGFloat(58 + visibleRows * 35)
        let size = CGSize(width: 644, height: height)
        let screen = NSScreen.main ?? NSScreen.screens.first
        let screenFrame = screen?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = CGPoint(x: screenFrame.midX - size.width / 2, y: screenFrame.maxY - size.height - 48)
        let frame = CGRect(origin: origin, size: size)
        if let switcherPanel {
            switcherPanel.setFrame(frame, display: true)
            (switcherPanel.contentView as? NSHostingView<WindowSwitcherView>)?.rootView = makeSwitcherView()
            switcherPanel.orderFrontRegardless()
            return
        }

        let panel = WindowSwitcherPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.animationBehavior = .none
        panel.contentView = NSHostingView(rootView: makeSwitcherView())
        switcherPanel = panel
        panel.orderFrontRegardless()
    }

    private func makeSwitcherView() -> WindowSwitcherView {
        WindowSwitcherView(
            items: switcherItems,
            selectedIndex: selectedIndex,
            select: { [weak self] index in self?.focusWindow(at: index) },
            close: { [weak self] in self?.closeSwitcher(notifyHelper: true) }
        )
    }

    private func cycleSelection(forward: Bool) {
        guard !switcherItems.isEmpty else {
            switcherPendingCycles = min(max(switcherPendingCycles + (forward ? 1 : -1), -500), 500)
            return
        }
        let count = switcherItems.count
        selectedIndex = (selectedIndex + (forward ? 1 : count - 1)) % count
        (switcherPanel?.contentView as? NSHostingView<WindowSwitcherView>)?.rootView = makeSwitcherView()
    }

    private func focusWindow(at index: Int) {
        guard switcherItems.indices.contains(index) else { closeSwitcher(notifyHelper: true); return }
        let item = switcherItems[index]
        NotchSystemHelperClient.shared.perform(
            "windows", "focusWindow", args: ["pid": item.pid, "index": item.index], timeout: 2
        )
        closeSwitcher(notifyHelper: true)
    }

    private func closeSwitcher(notifyHelper: Bool) {
        guard switcherRequested || switcherPanel != nil else { return }
        switcherRequested = false
        switcherPanel?.orderOut(nil)
        switcherPanel = nil
        switcherItems = []
        selectedIndex = 0
        switcherListLoaded = false
        switcherOptionReleased = false
        switcherPendingCycles = 0
        if notifyHelper { NotchSystemHelperClient.shared.perform("windows", "endSwitcher") }
        updateEventPolling()
    }

    private func sendSnap(_ position: SnapPosition) {
        guard enabledFeatures.contains(NotchFeature.windowSnapping.rawValue) else { return }
        NotchSystemHelperClient.shared.perform("windows", "snap", args: ["position": position.rawValue])
    }

    private func updateEventPolling() {
        let shouldPoll = enabledFeatures.contains(NotchFeature.quitProtection.rawValue) || switcherRequested
        if shouldPoll, eventPollTimer == nil {
            eventPollTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
                self?.pollHelperEvents()
            }
        } else if !shouldPoll {
            eventPollTimer?.invalidate()
            eventPollTimer = nil
        }
    }

    private func pollHelperEvents() {
        guard !eventPollInFlight else { return }
        guard enabledFeatures.contains(NotchFeature.quitProtection.rawValue) || switcherRequested else { updateEventPolling(); return }
        eventPollInFlight = true
        NotchSystemHelperClient.shared.perform("windows", "drainEvents", timeout: 1) { [weak self] response in
            let events = response?["events"] as? [[String: Any]] ?? []
            DispatchQueue.main.async {
                guard let self else { return }
                self.eventPollInFlight = false
                guard self.enabledFeatures.contains(NotchFeature.quitProtection.rawValue) || self.switcherRequested else {
                    self.updateEventPolling()
                    return
                }
                for event in events {
                    switch event["kind"] as? String {
                    case "quitPrompt":
                        if self.enabledFeatures.contains(NotchFeature.quitProtection.rawValue),
                           NotchFeatureRegistry.isEnabled(.quitProtection) {
                            NotchModel.shared.presentHUD(HUDState(symbol: "command", title: "Hold ⌘Q to quit", value: 0))
                        }
                    case "switcherOptionReleased":
                        if self.switcherRequested {
                            self.switcherOptionReleased = true
                            if self.switcherListLoaded { self.focusWindow(at: self.selectedIndex) }
                        }
                    default: break
                    }
                }
            }
        }
    }

    private static func windowItems(from rows: [[String: Any]]) -> [WindowSwitcherItem] {
        rows.prefix(500).compactMap { row in
            guard let pidNumber = row["pid"] as? NSNumber,
                  let indexNumber = row["index"] as? NSNumber,
                  let windowNumber = row["windowNumber"] as? NSNumber,
                  let appName = row["app"] as? String,
                  let title = row["title"] as? String else { return nil }
            let pid = pid_t(pidNumber.intValue)
            let icon = NSRunningApplication(processIdentifier: pid)?.icon
                ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)
                ?? NSImage(size: NSSize(width: 20, height: 20))
            return WindowSwitcherItem(
                pid: pidNumber.intValue,
                index: indexNumber.intValue,
                windowNumber: windowNumber.intValue,
                app: String(appName.prefix(128)),
                title: String(title.prefix(512)),
                icon: icon
            )
        }
    }
}

private func windowsCarbonEventHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return noErr }
    var identifier = EventHotKeyID()
    var actualSize = 0
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        &actualSize,
        &identifier
    )
    guard status == noErr, identifier.signature == WindowsAppRuntime.signature else { return noErr }
    DispatchQueue.main.async { WindowsAppRuntime.shared.handleHotKey(identifier.id) }
    return noErr
}

struct WindowsSettingsSection: View {
    @State private var appHasAccessibility = AXIsProcessTrusted()
    @State private var helperHasAccessibility: Bool?
    @State private var exclusions = QuitExclusionList.load()
    @State private var newBundleID = ""
    @AppStorage(NotchFeature.windowSwitcher.defaultsKey) private var windowSwitcherEnabled = false
    @AppStorage(NotchFeature.windowSnapping.defaultsKey) private var windowSnappingEnabled = false
    @AppStorage(NotchFeature.greenButtonMaximize.defaultsKey) private var greenButtonMaximizeEnabled = false
    @AppStorage(NotchFeature.quitOnLastWindow.defaultsKey) private var quitOnLastWindowEnabled = false
    @AppStorage(NotchFeature.quitProtection.defaultsKey) private var quitProtectionEnabled = false

    private var accessibilityMissing: Bool { !appHasAccessibility || helperHasAccessibility == false }
    private var hasEnabledWindowsFeature: Bool {
        windowSwitcherEnabled || windowSnappingEnabled || greenButtonMaximizeEnabled || quitOnLastWindowEnabled || quitProtectionEnabled
    }

    var body: some View {
        Section("Windows") {
            NotchFeatureToggle(.windowSwitcher, "Window switcher", detail: "⌥ Tab cycles app windows; release ⌥ to focus.")
                .help("Show all app windows and cycle with Option-Tab.")
            NotchFeatureToggle(.windowSnapping, "Window snapping", detail: "Drag to a screen edge or use ⌃⌥ arrow keys.")
                .help("Snap the frontmost window to a screen edge.")
            NotchFeatureToggle(.greenButtonMaximize, "Green button maximizes", detail: "Use the green window button to maximize and restore.")
                .help("Make the green window button maximize, then restore the previous size.")
            NotchFeatureToggle(.quitOnLastWindow, "Quit when the last window closes", detail: "Quit regular apps after their final window closes.")
                .help("Quit regular apps after their final window closes.")
            NotchFeatureToggle(.quitProtection, "Protect ⌘Q", detail: "Press ⌘Q twice or hold it for 0.6 seconds to quit.")
                .help("Require a second Command-Q press or a 0.6 second hold.")

            VStack(alignment: .leading, spacing: 4) {
                Text("Hotkeys").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text("Switcher  ⌥ Tab    ·    Snap  ⌃⌥ ← / → / ↑    ·    Maximize  ⌃⌥ Return")
                    .font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary)
            }

            if accessibilityMissing {
                HStack(spacing: 8) {
                    Text("Accessibility is needed to read and control app windows.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Open Settings") {
                        if let url = NotchPermission.accessibility.settingsURL { NSWorkspace.shared.open(url) }
                    }
                    .frame(minHeight: 28).contentShape(Rectangle())
                    .help("Open Accessibility privacy settings.")
                    .accessibilityIdentifier("windows-open-accessibility-settings")
                    Button("Check Again") { refreshPermission(forceHelperCheck: true) }
                        .frame(minHeight: 28).contentShape(Rectangle())
                        .help("Check Accessibility permission again.")
                        .accessibilityIdentifier("windows-check-accessibility")
                }
            }

            if quitOnLastWindowEnabled {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Excluded apps").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    HStack(spacing: 7) {
                        TextField("Bundle identifier (for example com.example.App)", text: $newBundleID)
                            .textFieldStyle(.roundedBorder)
                            .frame(minHeight: 28)
                            .help("Enter a bundle identifier to keep that app open.")
                            .accessibilityIdentifier("windows-exclusion-input")
                        Button("Add", action: addExclusion)
                            .frame(minHeight: 28).contentShape(Rectangle())
                            .help("Add this app to the quit exclusion list.")
                            .accessibilityIdentifier("windows-exclusion-add")
                    }
                    ForEach(exclusions, id: \.self) { bundleID in
                        HStack {
                            Text(bundleID).font(.system(size: 11, design: .rounded)).lineLimit(1)
                            Spacer()
                            Button {
                                exclusions.removeAll { $0 == bundleID }
                                saveExclusions()
                            } label: {
                                Image(systemName: "minus.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .frame(minWidth: 28, minHeight: 28).contentShape(Rectangle())
                            .help("Remove \(bundleID) from the exclusion list.")
                            .accessibilityIdentifier("windows-exclusion-remove-\(bundleID)")
                        }
                    }
                }
            }
        }
        .onAppear { refreshPermission() }
        .onChange(of: hasEnabledWindowsFeature) { _, enabled in
            if enabled { refreshPermission() } else { helperHasAccessibility = nil }
        }
    }

    private func addExclusion() {
        exclusions = QuitExclusionList.adding(newBundleID, to: exclusions)
        newBundleID = ""
        saveExclusions()
    }

    private func saveExclusions() {
        let bounded = Array(exclusions.prefix(QuitExclusionList.maximumEntries))
        exclusions = bounded
        UserDefaults.standard.set(bounded, forKey: QuitExclusionList.defaultsKey)
        if quitOnLastWindowEnabled { WindowsFeature.apply(.quitOnLastWindow, enabled: true) }
    }

    private func refreshPermission(forceHelperCheck: Bool = false) {
        let appTrusted = AXIsProcessTrusted()
        appHasAccessibility = appTrusted
        guard forceHelperCheck || hasEnabledWindowsFeature else {
            helperHasAccessibility = nil
            return
        }
        let enabledFeatures = NotchFeature.allCases.filter {
            $0.group == .windows && NotchFeatureRegistry.isEnabled($0)
        }
        NotchSystemHelperClient.shared.perform("windows", "status", timeout: 2) { response in
            DispatchQueue.main.async {
                let helperTrusted = response?["accessibilityTrusted"] as? Bool
                helperHasAccessibility = helperTrusted
                guard appTrusted, helperTrusted == true else { return }
                for feature in enabledFeatures { WindowsFeature.apply(feature, enabled: true) }
            }
        }
    }
}
