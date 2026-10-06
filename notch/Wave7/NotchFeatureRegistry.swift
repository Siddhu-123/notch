import Foundation
import SwiftUI

/// Wave 7 feature groups. One group = one job = one owned file set.
enum NotchFeatureGroup: String, CaseIterable, Identifiable, Codable {
    case music, island, sound, windows, pointer, keys, clipboard, capture, mediaTools, productivity, maintenance
    var id: String { rawValue }
    var title: String {
        switch self {
        case .music: return "Music"
        case .island: return "Island"
        case .sound: return "Sound"
        case .windows: return "Windows"
        case .pointer: return "Mouse & Trackpad"
        case .keys: return "Keyboard"
        case .clipboard: return "Clipboard & Finder"
        case .capture: return "Capture"
        case .mediaTools: return "Convert"
        case .productivity: return "Productivity"
        case .maintenance: return "Maintenance"
        }
    }
}

/// Permissions a feature may need. Notch only explains and links; it never grants.
enum NotchPermission: String, Codable {
    case accessibility, inputMonitoring, screenRecording, systemAudio, automation, fullDisk
    var title: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .inputMonitoring: return "Input Monitoring"
        case .screenRecording: return "Screen & System Audio Recording"
        case .systemAudio: return "System Audio Recording"
        case .automation: return "Automation"
        case .fullDisk: return "Full Disk Access"
        }
    }
    var settingsURL: URL? {
        let anchor: String
        switch self {
        case .accessibility: anchor = "Privacy_Accessibility"
        case .inputMonitoring: anchor = "Privacy_ListenEvent"
        case .screenRecording, .systemAudio: anchor = "Privacy_ScreenCapture"
        case .automation: anchor = "Privacy_Automation"
        case .fullDisk: anchor = "Privacy_AllFiles"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }
}

/// Every switchable wave 7 feature. Heavy or privileged features default off,
/// so a fresh install starts no taps, timers or scanners.
enum NotchFeature: String, CaseIterable, Identifiable, Codable {
    // Music (J1)
    case upNext, lyrics, musicKeyGuard
    // Island (J2)
    case islandActivities, downloadsPage
    // Sound (J3)
    case appMixer, appRouting, headphoneGuard
    // Windows (J5)
    case windowSwitcher, windowSnapping, greenButtonMaximize, quitOnLastWindow, quitProtection
    // Pointer (J6)
    case smoothScrolling, linearPointer, focusFollowsMouse, separateScrollDirection, horizontalScrollKey,
         mouseBackForward, mouseButtonShortcuts, threeFingerMiddleClick, doubleClickFilter, keyDebounce
    // Keys (J7)
    case superKey
    // Clipboard (J8)
    case clipboardAutoClear, plainTextPaste, finderTools
    // Capture (J9)
    case capture, watchRegion
    // Convert (J10)
    case mediaTools
    // Productivity (J11)
    case commandBar, quickPanel, quickToggles, radialMenu, cleaningMode
    // Maintenance (J12)
    case maintenance

    var id: String { rawValue }

    var group: NotchFeatureGroup {
        switch self {
        case .upNext, .lyrics, .musicKeyGuard: return .music
        case .islandActivities, .downloadsPage: return .island
        case .appMixer, .appRouting, .headphoneGuard: return .sound
        case .windowSwitcher, .windowSnapping, .greenButtonMaximize, .quitOnLastWindow, .quitProtection: return .windows
        case .smoothScrolling, .linearPointer, .focusFollowsMouse, .separateScrollDirection, .horizontalScrollKey,
             .mouseBackForward, .mouseButtonShortcuts, .threeFingerMiddleClick, .doubleClickFilter, .keyDebounce: return .pointer
        case .superKey: return .keys
        case .clipboardAutoClear, .plainTextPaste, .finderTools: return .clipboard
        case .capture, .watchRegion: return .capture
        case .mediaTools: return .mediaTools
        case .commandBar, .quickPanel, .quickToggles, .radialMenu, .cleaningMode: return .productivity
        case .maintenance: return .maintenance
        }
    }

    /// Light, permission-free features start on; everything else is opt-in.
    var defaultEnabled: Bool {
        switch self {
        case .upNext, .lyrics, .islandActivities, .downloadsPage, .capture, .mediaTools, .quickToggles, .maintenance: return true
        default: return false
        }
    }

    var permission: NotchPermission? {
        switch self {
        case .musicKeyGuard, .windowSwitcher, .windowSnapping, .greenButtonMaximize, .quitOnLastWindow, .quitProtection,
             .smoothScrolling, .focusFollowsMouse, .separateScrollDirection, .horizontalScrollKey, .mouseBackForward,
             .mouseButtonShortcuts, .threeFingerMiddleClick, .doubleClickFilter, .keyDebounce, .superKey,
             .plainTextPaste, .finderTools, .radialMenu, .cleaningMode, .commandBar, .quickPanel: return .accessibility
        case .appMixer, .appRouting: return .systemAudio
        case .capture, .watchRegion: return .screenRecording
        default: return nil
        }
    }

    var defaultsKey: String { "notch.feature.\(rawValue)" }
}

/// UserDefaults-backed switches. Not an ObservableObject on purpose: views read
/// `@AppStorage(feature.defaultsKey)` so one toggle never republishes the whole app.
enum NotchFeatureRegistry {
    static let changed = Notification.Name("notch.feature.changed")

    static func isEnabled(_ feature: NotchFeature, defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: feature.defaultsKey) as? Bool ?? feature.defaultEnabled
    }

    static func setEnabled(_ feature: NotchFeature, _ enabled: Bool, defaults: UserDefaults = .standard) {
        guard isEnabled(feature, defaults: defaults) != enabled else { return }
        defaults.set(enabled, forKey: feature.defaultsKey)
        NotchFeatureLifecycle.apply(feature, enabled: enabled)
        NotificationCenter.default.post(name: changed, object: feature.rawValue)
    }

    static func binding(_ feature: NotchFeature) -> Binding<Bool> {
        Binding(get: { isEnabled(feature) }, set: { setEnabled(feature, $0) })
    }

    /// Starts every enabled feature once at launch. Disabled features cost nothing.
    static func startEnabled() {
        for feature in NotchFeature.allCases where isEnabled(feature) {
            NotchFeatureLifecycle.apply(feature, enabled: true)
        }
    }
}

/// Routes enable/disable to the job that owns the feature.
enum NotchFeatureLifecycle {
    static func apply(_ feature: NotchFeature, enabled: Bool) {
        switch feature.group {
        case .music: MusicExtrasFeature.apply(feature, enabled: enabled)
        case .island: IslandFeature.apply(feature, enabled: enabled)
        case .sound: SoundMixerFeature.apply(feature, enabled: enabled)
        case .windows: WindowsFeature.apply(feature, enabled: enabled)
        case .pointer: PointerFeature.apply(feature, enabled: enabled)
        case .keys: KeysFeature.apply(feature, enabled: enabled)
        case .clipboard: ClipboardFeature.apply(feature, enabled: enabled)
        case .capture: CaptureFeature.apply(feature, enabled: enabled)
        case .mediaTools: MediaToolsFeature.apply(feature, enabled: enabled)
        case .productivity: ProductivityFeature.apply(feature, enabled: enabled)
        case .maintenance: MaintenanceFeature.apply(feature, enabled: enabled)
        }
    }
}

/// Shared toggle row for every wave 7 settings section: title, permission note, 28 pt target.
struct NotchFeatureToggle: View {
    let feature: NotchFeature
    let title: String
    var detail: String? = nil
    @AppStorage private var stored: Bool

    init(_ feature: NotchFeature, _ title: String, detail: String? = nil) {
        self.feature = feature
        self.title = title
        self.detail = detail
        _stored = AppStorage(wrappedValue: feature.defaultEnabled, feature.defaultsKey)
    }

    var body: some View {
        Toggle(isOn: Binding(get: { stored }, set: { NotchFeatureRegistry.setEnabled(feature, $0); stored = $0 })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                if let permission = feature.permission {
                    Text("Needs \(permission.title)").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .frame(minHeight: 28)
        .accessibilityIdentifier("feature-\(feature.rawValue)")
    }
}
