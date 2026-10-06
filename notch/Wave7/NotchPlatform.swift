import AppKit
import ApplicationServices
import CoreFoundation
import CoreGraphics
import Foundation

extension NotchFeature {
    var localizedTitle: String { String(localized: titleKey) }

    var summary: String { String(localized: summaryKey) }

    private var summaryKey: String.LocalizationValue {
        switch group {
        case .music: return "Add playback controls, lyrics, and music shortcuts."
        case .island: return "Show live activities and monitor your downloads."
        case .sound: return "Adjust app audio and headphone behavior."
        case .windows: return "Switch, arrange, and manage app windows."
        case .pointer: return "Customize pointer, scrolling, and mouse buttons."
        case .keys: return "Customize keyboard shortcuts and modifier keys."
        case .clipboard: return "Manage clipboard content, pasting, and Finder actions."
        case .capture: return "Capture screenshots and watch selected screen areas."
        case .mediaTools: return "Convert audio and video files with local tools."
        case .productivity: return "Open apps, actions, quick controls, and cleaning tools."
        case .maintenance: return "Review cleanup, uninstall, and system upkeep tools."
        }
    }

    private var titleKey: String.LocalizationValue {
        switch self {
        case .upNext: return "Up Next"
        case .lyrics: return "Lyrics"
        case .musicKeyGuard: return "Music Launch Guard"
        case .islandActivities: return "Live Activities"
        case .downloadsPage: return "Downloads"
        case .appMixer: return "App Mixer"
        case .appRouting: return "App Output Routing"
        case .headphoneGuard: return "Headphone Guard"
        case .windowSwitcher: return "Window Switcher"
        case .windowSnapping: return "Window Snapping"
        case .greenButtonMaximize: return "Green Button Maximizes"
        case .quitOnLastWindow: return "Quit When Last Window Closes"
        case .quitProtection: return "Quit Protection"
        case .smoothScrolling: return "Smooth Mouse Scrolling"
        case .linearPointer: return "Linear Pointer"
        case .focusFollowsMouse: return "Focus Follows Mouse"
        case .separateScrollDirection: return "Separate Scroll Direction"
        case .horizontalScrollKey: return "Horizontal Scroll Modifier"
        case .mouseBackForward: return "Mouse Back and Forward Buttons"
        case .mouseButtonShortcuts: return "Mouse Button Shortcuts"
        case .threeFingerMiddleClick: return "Three-Finger Middle Click"
        case .doubleClickFilter: return "Double-Click Filter"
        case .keyDebounce: return "Keyboard Chatter Debounce"
        case .superKey: return "Super Key"
        case .clipboardAutoClear: return "Auto-Clear Clipboard"
        case .plainTextPaste: return "Paste as Plain Text"
        case .finderTools: return "Finder Tools"
        case .capture: return "Capture"
        case .watchRegion: return "Watch Region"
        case .mediaTools: return "Media Tools"
        case .commandBar: return "Command Bar"
        case .quickPanel: return "Quick Panel"
        case .quickToggles: return "Quick Toggles"
        case .radialMenu: return "Radial Menu"
        case .cleaningMode: return "Cleaning Mode"
        case .maintenance: return "Maintenance"
        }
    }

}

extension NotchFeatureGroup {
    var localizedTitle: String {
        switch self {
        case .music: return String(localized: "Music")
        case .island: return String(localized: "Island")
        case .sound: return String(localized: "Sound")
        case .windows: return String(localized: "Windows")
        case .pointer: return String(localized: "Mouse & Trackpad")
        case .keys: return String(localized: "Keyboard")
        case .clipboard: return String(localized: "Clipboard & Finder")
        case .capture: return String(localized: "Capture")
        case .mediaTools: return String(localized: "Convert")
        case .productivity: return String(localized: "Productivity")
        case .maintenance: return String(localized: "Maintenance")
        }
    }
}

extension NotchPermission {
    static let allCases: [NotchPermission] = [
        .accessibility, .inputMonitoring, .screenRecording, .systemAudio, .automation, .fullDisk
    ]

    var localizedTitle: String {
        switch self {
        case .accessibility: return String(localized: "Accessibility")
        case .inputMonitoring: return String(localized: "Input Monitoring")
        case .screenRecording: return String(localized: "Screen & System Audio Recording")
        case .systemAudio: return String(localized: "System Audio Recording")
        case .automation: return String(localized: "Automation")
        case .fullDisk: return String(localized: "Full Disk Access")
        }
    }

    var why: String {
        switch self {
        case .accessibility:
            return String(localized: "Notch uses Accessibility to control windows and keyboard actions, and never grants this permission itself.")
        case .inputMonitoring:
            return String(localized: "Notch uses Input Monitoring to detect selected keyboard and mouse shortcuts, and never grants this permission itself.")
        case .screenRecording:
            return String(localized: "Notch uses Screen Recording to capture screenshots and watch a selected region, and never grants this permission itself.")
        case .systemAudio:
            return String(localized: "Notch uses System Audio Recording to read playback for app audio tools, and never grants this permission itself.")
        case .automation:
            return String(localized: "Notch uses Automation only for actions you choose in other apps, and never grants this permission itself.")
        case .fullDisk:
            return String(localized: "Notch uses Full Disk Access to review protected folders during maintenance scans, and never grants this permission itself.")
        }
    }

    var features: [NotchFeature] {
        let declared = NotchFeature.allCases.filter { $0.permission == self }
        return self == .fullDisk ? declared + [.maintenance] : declared
    }
}

enum NotchPermissionStatus {
    static func check(_ permission: NotchPermission) -> Bool? {
        switch permission {
        case .accessibility: return AXIsProcessTrusted()
        case .screenRecording, .systemAudio: return CGPreflightScreenCaptureAccess()
        case .inputMonitoring, .automation, .fullDisk: return nil
        }
    }
}

extension NotchToolkitPage {
    var localizedTitle: String {
        switch self {
        case .notes: return String(localized: "Scratchpad")
        case .capture: return String(localized: "Capture")
        case .tools: return String(localized: "Tools")
        case .downloads: return String(localized: "Downloads")
        case .convert: return String(localized: "Convert")
        case .maintenance: return String(localized: "Maintenance")
        case .awake: return String(localized: "Keep Awake")
        }
    }
}

enum NotchPanelLayout {
    static let orderKey = "notch.panel.toolkitOrder"
    static let hiddenKey = "notch.panel.toolkitHidden"
    static let changed = Notification.Name("notch.panel.layout.changed")

    static var allOrdered: [NotchToolkitPage] {
        ordered(stored: UserDefaults.standard.stringArray(forKey: orderKey) ?? [], hidden: [])
    }

    static var hidden: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: hiddenKey) ?? [])
    }

    static var current: [NotchToolkitPage] {
        ordered(stored: UserDefaults.standard.stringArray(forKey: orderKey) ?? [], hidden: hidden)
    }

    static func ordered(stored: [String], hidden: Set<String>) -> [NotchToolkitPage] {
        var result: [NotchToolkitPage] = []
        var seen = Set<NotchToolkitPage>()
        for rawValue in stored {
            guard let page = NotchToolkitPage(rawValue: rawValue), seen.insert(page).inserted else { continue }
            result.append(page)
        }
        for page in NotchToolkitPage.allCases where seen.insert(page).inserted {
            result.append(page)
        }
        let visible = result.filter { !hidden.contains($0.rawValue) }
        return visible.isEmpty ? [.tools] : visible
    }

    static func move(
        _ page: NotchToolkitPage,
        by offset: Int,
        in pages: [NotchToolkitPage] = NotchToolkitPage.allCases
    ) -> [NotchToolkitPage] {
        guard let source = pages.firstIndex(of: page) else { return pages }
        let destination: Int
        if offset < 0 {
            destination = source + max(offset, -source)
        } else {
            destination = source + min(offset, pages.count - 1 - source)
        }
        guard source != destination else { return pages }
        var result = pages
        result.remove(at: source)
        result.insert(page, at: destination)
        return result
    }

    static func saveOrder(_ pages: [NotchToolkitPage]) {
        UserDefaults.standard.set(pages.map(\.rawValue), forKey: orderKey)
        postChanged()
    }

    static func setHidden(_ isHidden: Bool, for page: NotchToolkitPage) {
        var values = hidden
        if isHidden { values.insert(page.rawValue) } else { values.remove(page.rawValue) }
        guard values != hidden else { return }
        UserDefaults.standard.set(values.sorted(), forKey: hiddenKey)
        postChanged()
    }

    static func postChanged() {
        NotificationCenter.default.post(name: changed, object: nil)
    }
}

enum NotchSettingsTransfer {
    enum TransferError: LocalizedError {
        case malformed, unsupportedVersion

        var errorDescription: String? {
            switch self {
            case .malformed: return String(localized: "The settings file is invalid.")
            case .unsupportedVersion: return String(localized: "This settings file version is not supported.")
            }
        }
    }

    static func export(defaults: UserDefaults = .standard) -> Data {
        var values: [String: Any] = [:]
        for key in defaults.dictionaryRepresentation().keys.sorted() where isTransferableKey(key) {
            if let value = transferableValue(defaults.object(forKey: key)) {
                values[key] = value
            }
        }
        return (try? JSONSerialization.data(
            withJSONObject: ["version": 1, "values": values],
            options: [.sortedKeys]
        )) ?? Data("{\"version\":1,\"values\":{}}".utf8)
    }

    static func importData(_ data: Data, into defaults: UserDefaults = .standard) throws -> Int {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw TransferError.malformed
        }
        guard let root = object as? [String: Any], let version = root["version"] as? NSNumber else {
            throw TransferError.malformed
        }
        guard CFGetTypeID(version) != CFBooleanGetTypeID(), version.stringValue == "1" else {
            throw TransferError.unsupportedVersion
        }
        guard let values = root["values"] as? [String: Any] else { throw TransferError.malformed }

        var accepted: [String: Any] = [:]
        for key in values.keys.sorted() where isTransferableKey(key) {
            if let value = transferableValue(values[key]) { accepted[key] = value }
        }

        var imported = 0
        var panelLayoutChanged = false
        for key in accepted.keys.sorted() {
            guard let value = accepted[key] else { continue }
            if let feature = NotchFeature.allCases.first(where: { $0.defaultsKey == key }) {
                guard let enabled = booleanValue(value) else { continue }
                // Only the live store drives feature lifecycles; other suites just store the value.
                if defaults === UserDefaults.standard {
                    NotchFeatureRegistry.setEnabled(feature, enabled, defaults: defaults)
                }
                defaults.set(enabled, forKey: key)
            } else {
                defaults.set(value, forKey: key)
                if key == NotchPanelLayout.orderKey || key == NotchPanelLayout.hiddenKey {
                    panelLayoutChanged = true
                }
            }
            imported += 1
        }
        if panelLayoutChanged { NotchPanelLayout.postChanged() }
        return imported
    }

    private static func isTransferableKey(_ key: String) -> Bool {
        guard key.hasPrefix("notch.") else { return false }
        let lowercased = key.lowercased()
        return !["token", "secret", "password", "key."].contains(where: lowercased.contains)
    }

    private static func transferableValue(_ value: Any?) -> Any? {
        guard let value else { return nil }
        if let string = value as? String { return string }
        if let strings = value as? [String] { return strings }
        guard let number = value as? NSNumber else { return nil }
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
        let cfNumber = number as CFNumber
        if CFNumberIsFloatType(cfNumber) { return number.doubleValue.isFinite ? number.doubleValue : nil }
        if let integer = Int(number.stringValue) { return integer }
        return number.doubleValue.isFinite ? number.doubleValue : nil
    }

    private static func booleanValue(_ value: Any) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}
