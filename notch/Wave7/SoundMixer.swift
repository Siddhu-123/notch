import AppKit
import CoreAudio
import CoreGraphics
import SwiftUI

struct SoundMixerPreference: Codable, Equatable {
    var gain: Double
    var deviceUID: String?
    var updatedAt: Date

    init(gain: Double = 1, deviceUID: String? = nil, updatedAt: Date = .now) {
        self.gain = MixerGain.clamped(gain)
        self.deviceUID = deviceUID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true ? nil : deviceUID
        self.updatedAt = updatedAt
    }
}

enum MixerGain {
    static func fromPercent(_ percent: Double) -> Double {
        guard percent.isFinite else { return 1 }
        return min(max(percent, 0), 200) / 100
    }

    static func percent(fromGain gain: Double) -> Int {
        Int((clamped(gain) * 100).rounded())
    }

    static func clamped(_ gain: Double) -> Double {
        guard gain.isFinite else { return 1 }
        return min(max(gain, 0), 2)
    }

    /// A short, continuous knee keeps boosted float samples from hard-clipping at full scale.
    static func softClip(_ sample: Double) -> Double {
        guard sample.isFinite else { return 0 }
        let magnitude = abs(sample)
        let sign = sample.sign == .minus ? -1.0 : 1.0
        let knee = 0.98
        guard magnitude > knee else { return sample }
        let excess = magnitude - knee
        return sign * (knee + 0.02 * excess / (0.02 + excess))
    }

    static func process(_ sample: Double, gain: Double) -> Double {
        softClip(sample * clamped(gain))
    }
}

enum HeadphoneGuard {
    enum OutputKind: Equatable {
        case bluetooth, bluetoothLE, headphones, builtInSpeakers, other

        var isHeadphone: Bool {
            switch self {
            case .bluetooth, .bluetoothLE, .headphones: return true
            case .builtInSpeakers, .other: return false
            }
        }
    }

    static func targetVolume(
        previousTransport: OutputKind,
        newTransport: OutputKind,
        current: Double,
        limit: Double
    ) -> Double? {
        guard previousTransport.isHeadphone,
              newTransport == .builtInSpeakers,
              current.isFinite,
              limit.isFinite else { return nil }
        let safeLimit = min(max(limit, 0), 1)
        return current > safeLimit ? safeLimit : nil
    }

    static func outputKind(transport: UInt32, dataSourceName: String?) -> OutputKind {
        if transport == kAudioDeviceTransportTypeBluetooth { return .bluetooth }
        if transport == kAudioDeviceTransportTypeBluetoothLE { return .bluetoothLE }
        if dataSourceName?.localizedCaseInsensitiveContains("headphone") == true { return .headphones }
        return transport == kAudioDeviceTransportTypeBuiltIn ? .builtInSpeakers : .other
    }
}

enum SoundMixerPreferences {
    static let defaultsKey = "notch.soundMixer.preferences"
    static let maximumSavedApps = 64
    private static let lock = NSLock()

    static func decode(_ data: Data?) -> [String: SoundMixerPreference] {
        guard let data,
              let decoded = try? JSONDecoder().decode([String: SoundMixerPreference].self, from: data) else { return [:] }
        let valid = decoded.filter { bundleID, preference in
            !bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                bundleID.count <= 255 && preference.gain.isFinite && preference.updatedAt.timeIntervalSince1970.isFinite
        }
        return Dictionary(valid.sorted { $0.value.updatedAt > $1.value.updatedAt }
            .prefix(maximumSavedApps).map { ($0.key, SoundMixerPreference(gain: $0.value.gain, deviceUID: $0.value.deviceUID, updatedAt: $0.value.updatedAt)) },
            uniquingKeysWith: { first, _ in first })
    }

    static func all(defaults: UserDefaults = .standard) -> [String: SoundMixerPreference] {
        lock.lock()
        defer { lock.unlock() }
        return decode(defaults.data(forKey: defaultsKey))
    }

    static func preference(for bundleID: String, defaults: UserDefaults = .standard) -> SoundMixerPreference {
        all(defaults: defaults)[bundleID] ?? SoundMixerPreference()
    }

    @discardableResult
    static func set(
        _ preference: SoundMixerPreference?,
        for bundleID: String,
        defaults: UserDefaults = .standard
    ) -> [String: SoundMixerPreference] {
        lock.lock()
        defer { lock.unlock() }
        var values = decode(defaults.data(forKey: defaultsKey))
        if let preference,
           preference.gain != 1 || preference.deviceUID != nil {
            values[bundleID] = SoundMixerPreference(gain: preference.gain, deviceUID: preference.deviceUID)
        } else {
            values.removeValue(forKey: bundleID)
        }
        values = Dictionary(values.sorted { $0.value.updatedAt > $1.value.updatedAt }
            .prefix(maximumSavedApps).map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
        if let data = try? JSONEncoder().encode(values) {
            defaults.set(data, forKey: defaultsKey)
        }
        return values
    }

    static func helperConfigs(_ preferences: [String: SoundMixerPreference]) -> [[String: Any]] {
        preferences.keys.sorted().compactMap { bundleID in
            guard let preference = preferences[bundleID] else { return nil }
            return ["bundleID": bundleID, "gain": preference.gain, "deviceUID": preference.deviceUID.map { $0 as Any } ?? NSNull()]
        }
    }
}

struct RunningAudioApp: Identifiable, Equatable {
    let bundleID: String
    let name: String
    let processIDs: [UInt32]
    var id: String { bundleID }

    static func parse(_ reply: [String: Any]?, maximum: Int = 100) -> [RunningAudioApp] {
        guard let rows = reply?["apps"] as? [[String: Any]], maximum > 0 else { return [] }
        var seen = Set<String>()
        return rows.compactMap { row in
            guard let bundleID = row["bundleID"] as? String,
                  !bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  bundleID.count <= 255,
                  seen.insert(bundleID).inserted else { return nil }
            let processIDs = (row["processIDs"] as? [NSNumber] ?? []).compactMap { number -> UInt32? in
                let value = number.int64Value
                return value > 0 && value <= Int64(UInt32.max) ? UInt32(value) : nil
            }
            guard !processIDs.isEmpty else { return nil }
            let rawName = (row["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = String((rawName?.isEmpty == false ? rawName! : bundleID).prefix(120))
            return RunningAudioApp(bundleID: bundleID, name: name, processIDs: Array(Set(processIDs)).sorted())
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        .prefix(maximum)
        .map { $0 }
    }
}

enum SoundMixerFeature {
    private static let workQueue = DispatchQueue(label: "sidco.notch.sound-mixer", qos: .userInitiated)
    private static let guardQueue = DispatchQueue(label: "sidco.notch.headphone-guard", qos: .utility)
    private static var defaultOutputListener: AudioObjectPropertyListenerBlock?
    private static var previousOutputKind: HeadphoneGuard.OutputKind = .other

    static func apply(_ feature: NotchFeature, enabled: Bool) {
        switch feature {
        case .appMixer, .appRouting:
            configureMixer()
        case .headphoneGuard:
            if enabled { enableHeadphoneGuard() } else { disableHeadphoneGuard() }
        default:
            break
        }
    }

    static func updateGain(bundleID: String, gain: Double) -> [String: SoundMixerPreference] {
        let current = SoundMixerPreferences.preference(for: bundleID)
        let updated = SoundMixerPreference(gain: gain, deviceUID: current.deviceUID)
        let values = SoundMixerPreferences.set(updated, for: bundleID)
        guard NotchFeatureRegistry.isEnabled(.appMixer), CGPreflightScreenCaptureAccess() else { return values }
        workQueue.async {
            NotchSystemHelperClient.shared.perform("audio", "setGain", args: ["bundleID": bundleID, "gain": updated.gain])
        }
        return values
    }

    static func updateDevice(bundleID: String, deviceUID: String?) -> [String: SoundMixerPreference] {
        let current = SoundMixerPreferences.preference(for: bundleID)
        let updated = SoundMixerPreference(gain: current.gain, deviceUID: deviceUID)
        let values = SoundMixerPreferences.set(updated, for: bundleID)
        guard NotchFeatureRegistry.isEnabled(.appRouting), CGPreflightScreenCaptureAccess() else { return values }
        workQueue.async {
            NotchSystemHelperClient.shared.perform("audio", "setDevice", args: [
                "bundleID": bundleID,
                "deviceUID": deviceUID ?? NSNull()
            ])
        }
        return values
    }

    static func reset(bundleID: String) -> [String: SoundMixerPreference] {
        let values = SoundMixerPreferences.set(nil, for: bundleID)
        guard canRunMixer else { return values }
        workQueue.async { NotchSystemHelperClient.shared.perform("audio", "reset", args: ["bundleID": bundleID]) }
        return values
    }

    static func synchronize() {
        configureMixer()
    }

    private static var canRunMixer: Bool {
        (NotchFeatureRegistry.isEnabled(.appMixer) || NotchFeatureRegistry.isEnabled(.appRouting)) &&
            CGPreflightScreenCaptureAccess()
    }

    private static func configureMixer() {
        let enabled = NotchFeatureRegistry.isEnabled(.appMixer) || NotchFeatureRegistry.isEnabled(.appRouting)
        workQueue.async {
            guard enabled else {
                NotchSystemHelperClient.shared.perform("audio", "disable")
                return
            }
            guard CGPreflightScreenCaptureAccess() else {
                NotchSystemHelperClient.shared.perform("audio", "disable")
                return
            }
            NotchSystemHelperClient.shared.perform("audio", "enable", args: [
                "mixerEnabled": NotchFeatureRegistry.isEnabled(.appMixer),
                "routingEnabled": NotchFeatureRegistry.isEnabled(.appRouting),
                "configs": SoundMixerPreferences.helperConfigs(SoundMixerPreferences.all()).map { row in
                    var config = row
                    if !NotchFeatureRegistry.isEnabled(.appMixer) { config["gain"] = 1.0 }
                    if !NotchFeatureRegistry.isEnabled(.appRouting) { config["deviceUID"] = NSNull() }
                    return config
                }
            ])
        }
    }

    private static func enableHeadphoneGuard() {
        guardQueue.async {
            guard defaultOutputListener == nil else { return }
            previousOutputKind = currentDefaultOutputKind()
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let listener: AudioObjectPropertyListenerBlock = { _, _ in
                guard let deviceID = CoreAudioBackend.shared.defaultOutputDeviceID() else {
                    previousOutputKind = .other
                    return
                }
                let newKind = outputKind(for: deviceID)
                let previous = previousOutputKind
                previousOutputKind = newKind
                let capabilities = CoreAudioBackend.shared.readCapabilities(device: deviceID)
                guard let target = HeadphoneGuard.targetVolume(
                    previousTransport: previous,
                    newTransport: newKind,
                    current: capabilities.volume,
                    limit: UserDefaults.standard.object(forKey: "notch.soundMixer.headphoneGuard.limit") as? Double ?? 0.25
                ), capabilities.isVolumeAvailable,
                   CoreAudioBackend.shared.defaultOutputDeviceID() == deviceID else { return }
                _ = CoreAudioBackend.shared.writeVolume(target, forDevice: deviceID)
            }
            guard AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, guardQueue, listener
            ) == noErr else { return }
            defaultOutputListener = listener
        }
    }

    private static func disableHeadphoneGuard() {
        guardQueue.async {
            guard let listener = defaultOutputListener else { return }
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, guardQueue, listener
            )
            defaultOutputListener = nil
            previousOutputKind = .other
        }
    }

    private static func currentDefaultOutputKind() -> HeadphoneGuard.OutputKind {
        guard let device = CoreAudioBackend.shared.defaultOutputDeviceID() else { return .other }
        return outputKind(for: device)
    }

    private static func outputKind(for device: AudioDeviceID) -> HeadphoneGuard.OutputKind {
        var transport: UInt32 = 0
        var transportSize = UInt32(MemoryLayout<UInt32>.size)
        var transportAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectGetPropertyData(device, &transportAddress, 0, nil, &transportSize, &transport)
        return HeadphoneGuard.outputKind(transport: transport, dataSourceName: dataSourceName(device))
    }

    private static func dataSourceName(_ device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var source: UInt32 = 0
        var sourceSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &sourceSize, &source) == noErr else { return nil }
        var name: Unmanaged<CFString>?
        address.mSelector = kAudioDevicePropertyDataSourceNameForIDCFString
        let status = withUnsafeMutablePointer(to: &source) { sourcePointer in
            withUnsafeMutablePointer(to: &name) { namePointer in
                var translation = AudioValueTranslation(
                    mInputData: UnsafeMutableRawPointer(sourcePointer),
                    mInputDataSize: UInt32(MemoryLayout<UInt32>.size),
                    mOutputData: UnsafeMutableRawPointer(namePointer),
                    mOutputDataSize: UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
                )
                var translationSize = UInt32(MemoryLayout<AudioValueTranslation>.size)
                return AudioObjectGetPropertyData(device, &address, 0, nil, &translationSize, &translation)
            }
        }
        guard status == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }

}

struct SoundMixerSection: View {
    @AppStorage(NotchFeature.appMixer.defaultsKey) private var mixerEnabled = NotchFeature.appMixer.defaultEnabled
    @AppStorage(NotchFeature.appRouting.defaultsKey) private var routingEnabled = NotchFeature.appRouting.defaultEnabled
    @ObservedObject private var controls = SystemControlCenter.shared
    @State private var apps: [RunningAudioApp] = []
    @State private var preferences = SoundMixerPreferences.all()
    @State private var permissionAvailable = CGPreflightScreenCaptureAccess()

    private var featureEnabled: Bool { mixerEnabled || routingEnabled }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("App mixer", systemImage: "slider.horizontal.3")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.62))
            if !featureEnabled {
                Text("Enable App mixer or App routing in Settings → Features → Sound.")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.52))
                    .lineLimit(2)
            } else if !permissionAvailable {
                HStack(spacing: 8) {
                    Text("System Audio Recording is needed to control app audio.")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.58))
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Settings") {
                        if let url = NotchPermission.systemAudio.settingsURL { NSWorkspace.shared.open(url) }
                    }
                    .frame(minHeight: 28)
                    .contentShape(Rectangle())
                    .help("Open System Audio Recording privacy settings")
                    .accessibilityIdentifier("sound-mixer-open-settings")
                }
            } else if apps.isEmpty {
                Text("Apps producing audio will appear here.")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.52))
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 5) {
                        ForEach(Array(apps.prefix(6))) { app in
                            SoundMixerAppRow(
                                app: app,
                                preference: preferences[app.bundleID] ?? SoundMixerPreference(),
                                devices: controls.outputDevices,
                                defaultDeviceName: controls.currentOutputDevice?.name ?? "Default",
                                onGain: { gain in
                                    preferences = SoundMixerFeature.updateGain(bundleID: app.bundleID, gain: gain)
                                },
                                onDevice: { uid in
                                    preferences = SoundMixerFeature.updateDevice(bundleID: app.bundleID, deviceUID: uid)
                                },
                                onReset: {
                                    preferences = SoundMixerFeature.reset(bundleID: app.bundleID)
                                }
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: 122)
            }
        }
        .padding(7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .task(id: featureEnabled) {
            guard featureEnabled else { apps = []; return }
            var helperIsConfigured = false
            while !Task.isCancelled {
                permissionAvailable = CGPreflightScreenCaptureAccess()
                if permissionAvailable {
                    if !helperIsConfigured {
                        SoundMixerFeature.synchronize()
                        helperIsConfigured = true
                    }
                    let reply = await NotchSystemHelperClient.shared.perform("audio", "list", timeout: 2)
                    apps = RunningAudioApp.parse(reply)
                    preferences = SoundMixerPreferences.all()
                } else {
                    apps = []
                    if helperIsConfigured { SoundMixerFeature.synchronize() }
                    helperIsConfigured = false
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .onAppear { preferences = SoundMixerPreferences.all() }
        .accessibilityIdentifier("sound-mixer-section")
    }
}

private struct SoundMixerAppRow: View {
    let app: RunningAudioApp
    let preference: SoundMixerPreference
    let devices: [AudioOutputDevice]
    let defaultDeviceName: String
    let onGain: (Double) -> Void
    let onDevice: (String?) -> Void
    let onReset: () -> Void

    private var deviceName: String {
        guard NotchFeatureRegistry.isEnabled(.appRouting) else { return "Default" }
        guard let uid = preference.deviceUID else { return "Default" }
        return devices.first(where: { $0.uid == uid })?.name ?? "Unavailable"
    }

    private var displayedGain: Double {
        NotchFeatureRegistry.isEnabled(.appMixer) ? preference.gain : 1
    }

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 6) {
                appIcon
                    .resizable()
                    .frame(width: 20, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                Text(app.name)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: onReset) {
                    Image(systemName: "arrow.counterclockwise")
                        .frame(minWidth: 28, minHeight: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(preference.gain == 1 && preference.deviceUID == nil)
                .help("Reset app volume and output")
                .accessibilityLabel("Reset \(app.name) sound settings")
                .accessibilityIdentifier("sound-mixer-reset-\(app.bundleID)")
            }
            HStack(spacing: 5) {
                Slider(value: Binding(get: { displayedGain }, set: onGain), in: 0...2)
                    .tint(.white)
                    .controlSize(.mini)
                    .disabled(!NotchFeatureRegistry.isEnabled(.appMixer))
                    .help("Set \(app.name) volume from 0 to 200 percent")
                    .accessibilityLabel("\(app.name) volume")
                    .accessibilityValue("\(MixerGain.percent(fromGain: displayedGain)) percent")
                    .accessibilityIdentifier("sound-mixer-gain-\(app.bundleID)")
                Text("\(MixerGain.percent(fromGain: displayedGain))%")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.65))
                    .frame(width: 38, alignment: .trailing)
                Menu {
                    Button {
                        onDevice(nil)
                    } label: {
                        if preference.deviceUID == nil { Label("Default", systemImage: "checkmark") }
                        else { Text("Default") }
                    }
                    .help("Use the system default output")
                    .accessibilityIdentifier("sound-mixer-device-default-\(app.bundleID)")
                    ForEach(devices) { device in
                        Button {
                            onDevice(device.uid)
                        } label: {
                            if preference.deviceUID == device.uid { Label(device.name, systemImage: "checkmark") }
                            else { Text(device.name) }
                        }
                        .help("Route \(app.name) to \(device.name)")
                        .accessibilityIdentifier("sound-mixer-device-\(app.bundleID)-\(device.uid)")
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(deviceName == "Default" ? defaultDeviceName : deviceName)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                    }
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.76))
                    .frame(minWidth: 64, maxWidth: 96, minHeight: 28)
                    .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .help("Output device: \(deviceName)")
                .accessibilityLabel("\(app.name) output device: \(deviceName)")
                .accessibilityIdentifier("sound-mixer-device-menu-\(app.bundleID)")
                .disabled(!NotchFeatureRegistry.isEnabled(.appRouting))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var appIcon: Image {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) {
            return Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
        }
        return Image(systemName: "app.fill")
    }
}

struct SoundSettingsSection: View {
    @AppStorage("notch.soundMixer.headphoneGuard.limit") private var guardLimit = 0.25
    @AppStorage(NotchFeature.headphoneGuard.defaultsKey) private var guardEnabled = NotchFeature.headphoneGuard.defaultEnabled

    var body: some View {
        Section("Per-app sound") {
            NotchFeatureToggle(.appMixer, "App mixer", detail: "Set app volume from 0 to 200%.")
                .help("Enable per-app volume and boost controls")
            NotchFeatureToggle(.appRouting, "App output routing", detail: "Send an app to a separate output device.")
                .help("Enable per-app output device selection")
        }
        Section("Headphone guard") {
            NotchFeatureToggle(.headphoneGuard, "Lower volume on speaker switch", detail: "Reduce volume when headphones disconnect.")
                .help("Lower volume when playback switches from headphones to built-in speakers")
            if guardEnabled {
                HStack {
                    Text("Speaker volume limit")
                    Slider(value: $guardLimit, in: 0.05...0.5, step: 0.05)
                        .help("Maximum volume after switching from headphones to built-in speakers")
                        .accessibilityLabel("Headphone guard volume limit")
                        .accessibilityIdentifier("headphone-guard-limit-slider")
                    Text("\(Int((guardLimit * 100).rounded()))%")
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                }
            }
        }
    }
}
