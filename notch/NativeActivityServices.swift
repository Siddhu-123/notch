import Foundation
import AppKit
import AVFoundation
import Combine
import CoreAudio
import IOKit
import IOKit.ps
import Speech
import Accelerate

// MARK: - Voice commands

/// A command Notch understands from an utterance. Only complete, final transcripts are parsed.
public enum VoiceCommand: Equatable {
    case play, pause, next, previous
    case openShelf, openCalendar, openControls, openMirror
    case startFocus(minutes: Int)
    case pauseFocus, resumeFocus, resetFocus

    public static let focusMinutesRange = 1...180
    public static let defaultFocusMinutes = 25

    /// Deterministic, whole-utterance parser. Anything that is not an exact known phrase returns nil.
    public static func parse(_ transcript: String) -> VoiceCommand? {
        let cleaned = transcript.lowercased()
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) || $0 == " " ? Character($0) : " " }
        let words = String(cleaned).split(separator: " ").map(String.init)
        guard !words.isEmpty, words.count <= 8 else { return nil }
        let phrase = words.joined(separator: " ")

        switch phrase {
        case "play", "play music", "resume music", "resume playback": return .play
        case "pause", "pause music", "pause playback", "stop music": return .pause
        case "next", "next track", "next song", "skip": return .next
        case "previous", "previous track", "previous song", "last track": return .previous
        case "open shelf", "show shelf": return .openShelf
        case "open calendar", "show calendar": return .openCalendar
        case "open controls", "show controls": return .openControls
        case "open mirror", "show mirror": return .openMirror
        case "pause focus", "pause focus timer": return .pauseFocus
        case "resume focus", "resume focus timer": return .resumeFocus
        case "reset focus", "reset focus timer": return .resetFocus
        case "start focus", "start focus timer": return .startFocus(minutes: defaultFocusMinutes)
        default: break
        }

        // "start focus [timer] [for] N minute(s)", "focus N minutes"
        var rest = words[...]
        if rest.first == "start" { rest = rest.dropFirst() }
        guard rest.first == "focus" else { return nil }
        rest = rest.dropFirst()
        if rest.first == "timer" { rest = rest.dropFirst() }
        if rest.first == "for" { rest = rest.dropFirst() }
        guard let first = rest.first, let value = Int(first), first.count <= 4 else { return nil }
        rest = rest.dropFirst()
        guard rest.count == 1, ["minute", "minutes"].contains(rest.first!) else { return nil }
        return .startFocus(minutes: min(max(value, focusMinutesRange.lowerBound), focusMinutesRange.upperBound))
    }
}

// MARK: - Voice backend (injectable)

public enum VoicePermissionResult: Equatable {
    case ready
    case denied(String)
    case unavailable(String)
}

public enum VoiceAvailability: Equatable {
    case unknown
    case ready
    case denied(String)
    case unavailable(String)

    public var message: String {
        switch self {
        case .unknown: return "Voice control asks for permission when you start it."
        case .ready: return "On-device speech recognition is ready."
        case .denied(let m), .unavailable(let m): return m
        }
    }
}

public struct VoiceCaptureHandlers {
    public var onLevel: @MainActor (Float) -> Void
    public var onResult: @MainActor (_ text: String, _ isFinal: Bool) -> Void
    public var onError: @MainActor (String) -> Void

    public init(onLevel: @escaping @MainActor (Float) -> Void,
                onResult: @escaping @MainActor (String, Bool) -> Void,
                onError: @escaping @MainActor (String) -> Void) {
        self.onLevel = onLevel
        self.onResult = onResult
        self.onError = onError
    }
}

@MainActor
public protocol VoiceBackend: AnyObject {
    func requestPermissions(_ completion: @escaping @MainActor (VoicePermissionResult) -> Void)
    func startCapture(handlers: VoiceCaptureHandlers) throws
    func endCapture()
    /// Idempotent: removes the tap, cancels the task and stops the engine.
    func stopCapture()
}

private final class LevelThrottle: @unchecked Sendable {
    private var last: UInt64 = 0
    private let interval: UInt64 = 1_000_000_000 / 15
    func shouldEmit() -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now &- last >= interval else { return false }
        last = now
        return true
    }
}

@MainActor
public final class SystemVoiceBackend: VoiceBackend {
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var hasTap = false
    private var permissionGeneration = 0

    public init() {}

    public func requestPermissions(_ completion: @escaping @MainActor (VoicePermissionResult) -> Void) {
        permissionGeneration += 1
        let token = permissionGeneration
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            completion(.unavailable("Speech recognition is unavailable for your language right now."))
            return
        }
        guard recognizer.supportsOnDeviceRecognition else {
            completion(.unavailable("On-device speech recognition isn't supported for your language. Notch never sends audio to the cloud."))
            return
        }
        self.recognizer = recognizer

        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        switch speechStatus {
        case .authorized:
            checkMicrophoneAccess(token: token, completion: completion)
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { status in
                Task { @MainActor in
                    guard token == self.permissionGeneration else { return }
                    switch status {
                    case .authorized:
                        self.checkMicrophoneAccess(token: token, completion: completion)
                    case .denied:
                        completion(.denied("Speech recognition access is off. Enable it for Notch in System Settings > Privacy & Security > Speech Recognition."))
                    case .restricted:
                        completion(.unavailable("Speech recognition is restricted on this Mac."))
                    case .notDetermined:
                        completion(.unavailable("Speech recognition permission was not granted."))
                    @unknown default:
                        completion(.unavailable("Speech recognition is unavailable."))
                    }
                }
            }
        case .denied:
            completion(.denied("Speech recognition access is off. Enable it for Notch in System Settings > Privacy & Security > Speech Recognition."))
        case .restricted:
            completion(.unavailable("Speech recognition is restricted on this Mac."))
        @unknown default:
            completion(.unavailable("Speech recognition is unavailable."))
        }
    }

    private func checkMicrophoneAccess(token: Int, completion: @escaping @MainActor (VoicePermissionResult) -> Void) {
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        switch micStatus {
        case .authorized:
            completion(.ready)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    guard token == self.permissionGeneration else { return }
                    completion(granted ? .ready : .denied("Microphone access is off. Enable it for Notch in System Settings > Privacy & Security > Microphone."))
                }
            }
        case .denied:
            completion(.denied("Microphone access is off. Enable it for Notch in System Settings > Privacy & Security > Microphone."))
        case .restricted:
            completion(.unavailable("Microphone access is restricted on this Mac."))
        @unknown default:
            completion(.unavailable("Microphone access is unavailable."))
        }
    }

    public func startCapture(handlers: VoiceCaptureHandlers) throws {
        stopCapture()
        guard let recognizer, recognizer.supportsOnDeviceRecognition else {
            throw VoiceError.message("On-device speech recognition is unavailable.")
        }
        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw VoiceError.message("No microphone input is available.")
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format,
                         block: Self.makeTapBlock(request: request, onLevel: handlers.onLevel))
        hasTap = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            hasTap = false
            throw VoiceError.message("Couldn't start the microphone: \(error.localizedDescription)")
        }
        self.engine = engine
        self.request = request
        self.task = Self.makeTask(recognizer: recognizer, request: request, handlers: handlers)
    }

    public func endCapture() {
        if let engine {
            if engine.isRunning { engine.stop() }
            if hasTap { engine.inputNode.removeTap(onBus: 0); hasTap = false }
        }
        request?.endAudio()
    }

    public func stopCapture() {
        permissionGeneration += 1
        endCapture()
        task?.cancel()
        engine = nil
        request = nil
        task = nil
    }

    // Built in nonisolated context so the audio / speech threads never inherit main-actor isolation.
    private nonisolated static func makeTapBlock(request: SFSpeechAudioBufferRecognitionRequest,
                                                 onLevel: @escaping @MainActor (Float) -> Void) -> AVAudioNodeTapBlock {
        let throttle = LevelThrottle()
        return { buffer, _ in
            request.append(buffer)
            guard throttle.shouldEmit(), let data = buffer.floatChannelData, buffer.frameLength > 0 else { return }
            var rms: Float = 0
            vDSP_rmsqv(data[0], 1, &rms, vDSP_Length(buffer.frameLength))
            let db = 20 * log10(max(rms, 1e-7))
            let level = max(0, min(1, (db + 60) / 60))
            Task { @MainActor in onLevel(level) }
        }
    }

    private nonisolated static func makeTask(recognizer: SFSpeechRecognizer,
                                             request: SFSpeechAudioBufferRecognitionRequest,
                                             handlers: VoiceCaptureHandlers) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            if let result {
                let text = result.bestTranscription.formattedString
                let isFinal = result.isFinal
                Task { @MainActor in handlers.onResult(text, isFinal) }
            }
            if let error, result?.isFinal != true {
                let message = error.localizedDescription
                Task { @MainActor in handlers.onError(message) }
            }
        }
    }
}

public enum VoiceError: Error, LocalizedError {
    case message(String)
    public var errorDescription: String? {
        if case .message(let m) = self { return m }
        return nil
    }
}

// MARK: - Voice control store

@MainActor
public final class VoiceControlStore: ObservableObject {
    public static let shared = VoiceControlStore()

    @Published public private(set) var isListening = false
    @Published public private(set) var isStarting = false
    @Published public private(set) var isFinishing = false
    /// In-memory only. The UI decides if/when the user copies or saves it.
    @Published public private(set) var transcript = ""
    @Published public private(set) var inputLevel: Float = 0
    @Published public private(set) var lastError: String?
    @Published public private(set) var availability: VoiceAvailability = .unknown
    @Published public private(set) var lastCommand: VoiceCommand?
    /// Commands must be deliberately enabled for a capture; ordinary dictation is the default.
    @Published public var isCommandModeEnabled = false

    /// Called once per final transcript that parses to a command. Never called for partial results.
    public var onCommand: ((VoiceCommand) -> Void)?
    /// Optional preflight check. Return a non-nil failure message to abort execution and surface that error.
    public var preflightCommand: ((VoiceCommand) -> String?)?

    private let backend: VoiceBackend
    private let timeout: TimeInterval
    private let startupTimeout: TimeInterval
    private var generation = 0
    private var timeoutTask: Task<Void, Never>?

    /// Construction never touches permissions or the microphone.
    public init(backend: VoiceBackend? = nil, timeout: TimeInterval = 30, startupTimeout: TimeInterval = 60) {
        self.backend = backend ?? SystemVoiceBackend()
        self.timeout = timeout
        self.startupTimeout = startupTimeout
    }

    public func start() {
        guard !isListening, !isStarting else { return }
        generation += 1
        let token = generation
        isStarting = true
        lastError = nil
        lastCommand = nil

        timeoutTask?.cancel()
        timeoutTask = Task { [weak self, startupTimeout] in
            try? await Task.sleep(nanoseconds: UInt64(startupTimeout * 1_000_000_000))
            guard !Task.isCancelled, let self, token == self.generation, self.isStarting else { return }
            self.fail("Voice control startup timed out. Check Microphone and Speech Recognition permissions in System Settings > Privacy & Security and try again.")
        }

        backend.requestPermissions { [weak self] result in
            guard let self, token == self.generation, self.isStarting else { return }
            self.timeoutTask?.cancel()
            self.timeoutTask = nil
            switch result {
            case .ready:
                self.availability = .ready
                self.beginCapture(token: token)
            case .denied(let message):
                self.availability = .denied(message)
                self.fail(message)
            case .unavailable(let message):
                self.availability = .unavailable(message)
                self.fail(message)
            }
        }
    }

    public func stop() {
        generation += 1
        teardown()
    }

    public func clear() {
        transcript = ""
        lastError = nil
        lastCommand = nil
    }

    /// Finish the utterance; leaving the view instead cancels with stop().
    public func finishListening() {
        guard isListening, !isFinishing else { return }
        isFinishing = true
        inputLevel = 0
        timeoutTask?.cancel()
        let token = generation
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self, token == self.generation else { return }
            self.fail("Couldn't finish transcription. Try again.")
        }
        backend.endCapture()
    }

    private func beginCapture(token: Int) {
        transcript = ""
        let handlers = VoiceCaptureHandlers(
            onLevel: { [weak self] level in
                guard let self, token == self.generation, self.isListening, !self.isFinishing else { return }
                self.inputLevel = level
            },
            onResult: { [weak self] text, isFinal in
                guard let self, token == self.generation, self.isListening else { return }
                self.transcript = text
                if isFinal { self.finish(with: text) }
            },
            onError: { [weak self] message in
                guard let self, token == self.generation, self.isListening else { return }
                self.generation += 1
                self.teardown()
                self.lastError = message
            })
        isStarting = false
        isListening = true
        do {
            try backend.startCapture(handlers: handlers)
        } catch {
            fail(error.localizedDescription)
            return
        }
        guard token == self.generation, self.isListening else { return }
        timeoutTask = Task { [weak self, timeout] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled, let self, token == self.generation else { return }
            self.generation += 1
            self.teardown()
            self.lastError = "Stopped listening after \(Int(timeout)) seconds."
        }
    }

    private func finish(with text: String) {
        generation += 1
        teardown()
        guard isCommandModeEnabled else { return }
        guard let command = VoiceCommand.parse(text) else {
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.isEmpty {
                lastError = "No command recognized: silence"
            } else {
                lastError = "No supported command recognized."
            }
            return
        }
        lastCommand = command
        if let preflight = preflightCommand, let errorMessage = preflight(command) {
            lastError = errorMessage
            return
        }
        onCommand?(command)
    }

    private func fail(_ message: String) {
        generation += 1
        teardown()
        lastError = message
    }

    private func teardown() {
        timeoutTask?.cancel()
        timeoutTask = nil
        backend.stopCapture()
        isListening = false
        isStarting = false
        inputLevel = 0
        isFinishing = false
    }
}

// MARK: - Accessory batteries

public struct AccessoryBatteryDevice: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let percentage: Int
    public let isCharging: Bool

    public init(id: String, name: String, percentage: Int, isCharging: Bool) {
        self.id = id
        self.name = name
        self.percentage = percentage
        self.isCharging = isCharging
    }
}

public enum AccessoryBatteryParser {
    private static let percentKeys = ["BatteryPercent", "BatteryLevel", "Battery Percent"]
    private static let nameKeys = ["Product", "DeviceName", "Name"]
    private static let idKeys = ["DeviceAddress", "SerialNumber", "Power Source ID"]
    private static let chargingKeys = ["IsCharging", "BatteryIsCharging", "Is Charging"]

    private static func isBool(_ value: Any) -> Bool {
        guard let n = value as? NSNumber else { return value is Bool }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    /// A real number in 0...100. Booleans, strings, NaN and out-of-range values are rejected.
    static func percentage(from value: Any?) -> Int? {
        guard let value, !isBool(value), let n = value as? NSNumber else { return nil }
        let d = n.doubleValue
        guard d.isFinite, d >= 0, d <= 100 else { return nil }
        return Int(d.rounded())
    }

    /// Parses an IORegistry or IOPowerSources dictionary. Returns nil for internal batteries,
    /// missing/invalid percentages and unnamed devices. `fallbackID` is used when no stable id is present.
    public static func parse(_ dict: [String: Any], fallbackID: String? = nil) -> AccessoryBatteryDevice? {
        if let transport = dict["Transport Type"] as? String, transport == "Internal" { return nil }
        if let type = dict["Type"] as? String, type == "InternalBattery" { return nil }
        if let builtIn = dict["Built-In"], isBool(builtIn), (builtIn as? NSNumber)?.boolValue == true { return nil }

        var percent: Int?
        if let raw = percentKeys.lazy.compactMap({ dict[$0] }).first {
            percent = percentage(from: raw)
        } else if let current = dict["Current Capacity"], !isBool(current), let c = (current as? NSNumber)?.doubleValue {
            // IOPowerSources: capacity relative to max (percent when max is 100).
            if let max = (dict["Max Capacity"] as? NSNumber)?.doubleValue, max > 0, c >= 0, c <= max {
                percent = percentage(from: NSNumber(value: c / max * 100))
            } else if dict["Max Capacity"] == nil {
                percent = percentage(from: current)
            }
        }
        guard let percent else { return nil }

        guard let name = nameKeys.lazy.compactMap({ dict[$0] as? String }).map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }).first(where: { !$0.isEmpty }),
              name != "InternalBattery" else { return nil }

        var id: String?
        for key in idKeys {
            if let s = dict[key] as? String, !s.isEmpty { id = s; break }
            if let n = dict[key] as? NSNumber, !isBool(n) { id = n.stringValue; break }
        }
        guard let stableID = id ?? fallbackID else { return nil }

        var charging = false
        for key in chargingKeys {
            if let v = dict[key], isBool(v) { charging = (v as? NSNumber)?.boolValue ?? false; break }
        }
        return AccessoryBatteryDevice(id: stableID, name: name, percentage: percent, isCharging: charging)
    }
}

public enum AccessoryBatteryScanner {
    private static let serviceClasses = ["AppleDeviceManagementHIDEventService", "IOHIDDevice", "AppleBluetoothDevice"]

    /// Reads values exposed through public IORegistry / IOPowerSources APIs. Never invents readings.
    public static func scan() -> [AccessoryBatteryDevice] {
        var found: [String: AccessoryBatteryDevice] = [:]

        for className in serviceClasses {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }
            while case let entry = IOIteratorNext(iterator), entry != 0 {
                defer { IOObjectRelease(entry) }
                var props: Unmanaged<CFMutableDictionary>?
                guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                      let dict = props?.takeRetainedValue() as? [String: Any] else { continue }
                var entryID: UInt64 = 0
                IORegistryEntryGetRegistryEntryID(entry, &entryID)
                if let device = AccessoryBatteryParser.parse(dict, fallbackID: entryID == 0 ? nil : "registry-\(entryID)") {
                    found[device.id] = device
                }
            }
        }

        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for source in list {
                guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                      let device = AccessoryBatteryParser.parse(desc) else { continue }
                found[device.id] = device
            }
        }

        return found.values.sorted {
            $0.name == $1.name ? $0.id < $1.id : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

@MainActor
public final class AccessoryBatteryMonitor: ObservableObject {
    public static let shared = AccessoryBatteryMonitor()
    public static let minimumPollInterval: TimeInterval = 30

    @Published public private(set) var devices: [AccessoryBatteryDevice] = []
    @Published public private(set) var statusMessage = "Accessory batteries haven't been checked yet."
    @Published public private(set) var isRefreshing = false

    private let provider: @Sendable () -> [AccessoryBatteryDevice]
    private var timer: Timer?
    private var refreshGeneration = 0

    public init(provider: @escaping @Sendable () -> [AccessoryBatteryDevice] = { AccessoryBatteryScanner.scan() }) {
        self.provider = provider
    }

    public var isPolling: Bool { timer != nil }

    public func refresh() {
        refreshGeneration += 1
        let token = refreshGeneration
        let provider = self.provider
        isRefreshing = true
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) { provider() }.value
            guard let self, token == self.refreshGeneration else { return }
            self.apply(result)
        }
    }

    func apply(_ result: [AccessoryBatteryDevice]) {
        isRefreshing = false
        devices = result
        statusMessage = result.isEmpty
            ? "No accessory is reporting a battery level to macOS."
            : "\(result.count) accessor\(result.count == 1 ? "y" : "ies") reporting battery."
    }

    public func startPolling(interval: TimeInterval = 60) {
        stopPolling()
        let seconds = max(Self.minimumPollInterval, interval)
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    public func stopPolling() {
        timer?.invalidate()
        timer = nil
        refreshGeneration += 1
        isRefreshing = false
    }
}

// MARK: - Call companion

public enum CallProvider: String, CaseIterable, Identifiable {
    case faceTime, teams, zoom
    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .faceTime: return "FaceTime"
        case .teams: return "Microsoft Teams"
        case .zoom: return "Zoom"
        }
    }

    public var bundleIdentifiers: [String] {
        switch self {
        case .faceTime: return ["com.apple.FaceTime"]
        case .teams: return ["com.microsoft.teams2", "com.microsoft.teams"]
        case .zoom: return ["us.zoom.xos"]
        }
    }
}

public struct CallProviderOption: Identifiable, Equatable {
    public let provider: CallProvider
    public let bundleIdentifier: String
    public let appURL: URL
    /// True when the app process is running. This is NOT an active call.
    public let isRunning: Bool
    public var id: String { provider.rawValue }
    public var name: String { provider.displayName }
}

public protocol CallAppBackend {
    func applicationURL(bundleIdentifier: String) -> URL?
    func isRunning(bundleIdentifier: String) -> Bool
    func openApplication(at url: URL, completion: @escaping (Error?) -> Void)
}

public struct SystemCallAppBackend: CallAppBackend {
    public init() {}
    public func applicationURL(bundleIdentifier: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }
    public func isRunning(bundleIdentifier: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }
    public func openApplication(at url: URL, completion: @escaping (Error?) -> Void) {
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            completion(error)
        }
    }
}

public protocol MicrophoneBackend {
    func defaultInputDevice() -> UInt32?
    func deviceName(_ device: UInt32) -> String?
    /// nil when the device exposes no mute control on the input scope.
    func muteState(_ device: UInt32) -> Bool?
    func isMuteSettable(_ device: UInt32) -> Bool
    func setMute(_ device: UInt32, _ muted: Bool) -> Int32
}

public struct CoreAudioMicrophoneBackend: MicrophoneBackend {
    public init() {}

    private func muteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                   mScope: kAudioObjectPropertyScopeInput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    public func defaultInputDevice() -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    public func deviceName(_ device: UInt32) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name)
        guard status == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }

    public func muteState(_ device: UInt32) -> Bool? {
        var address = muteAddress()
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    public func isMuteSettable(_ device: UInt32) -> Bool {
        var address = muteAddress()
        var settable = DarwinBoolean(false)
        guard AudioObjectHasProperty(device, &address),
              AudioObjectIsPropertySettable(device, &address, &settable) == noErr else { return false }
        return settable.boolValue
    }

    public func setMute(_ device: UInt32, _ muted: Bool) -> Int32 {
        var address = muteAddress()
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }
}

@MainActor
public final class CallCompanionStore: ObservableObject {
    public static let shared = CallCompanionStore()
    public static let selectedProviderKey = "callCompanion.selectedProvider"
    public static let callStateHint = "Notch can open your call app but can't tell whether a call is active. A running app is not a call."

    @Published public private(set) var options: [CallProviderOption] = []
    @Published public private(set) var selectedProvider: CallProvider?
    @Published public private(set) var lastError: String?

    @Published public private(set) var isMicrophoneMuteAvailable = false
    @Published public private(set) var isMicrophoneMuted = false
    @Published public private(set) var microphoneHint = "Microphone mute hasn't been checked yet."

    private let defaults: UserDefaults
    private let apps: CallAppBackend
    private let mic: MicrophoneBackend

    public init(defaults: UserDefaults = .standard,
                apps: CallAppBackend = SystemCallAppBackend(),
                microphone: MicrophoneBackend = CoreAudioMicrophoneBackend()) {
        self.defaults = defaults
        self.apps = apps
        self.mic = microphone
        selectedProvider = defaults.string(forKey: Self.selectedProviderKey).flatMap(CallProvider.init(rawValue:))
        refresh()
    }

    public var selectedOption: CallProviderOption? {
        options.first { $0.provider == selectedProvider }
    }

    public func selectProvider(_ provider: CallProvider?) {
        selectedProvider = provider
        if let provider {
            defaults.set(provider.rawValue, forKey: Self.selectedProviderKey)
        } else {
            defaults.removeObject(forKey: Self.selectedProviderKey)
        }
        lastError = nil
    }

    /// Re-reads installed/running state. Selection is kept even if the app is currently missing.
    public func refresh() {
        options = CallProvider.allCases.compactMap { provider in
            var firstInstalledOption: CallProviderOption?
            for bundleID in provider.bundleIdentifiers {
                if let url = apps.applicationURL(bundleIdentifier: bundleID) {
                    let isRunning = apps.isRunning(bundleIdentifier: bundleID)
                    let option = CallProviderOption(provider: provider, bundleIdentifier: bundleID, appURL: url,
                                                    isRunning: isRunning)
                    if isRunning {
                        return option
                    }
                    if firstInstalledOption == nil {
                        firstInstalledOption = option
                    }
                }
            }
            return firstInstalledOption
        }
    }

    /// Native hand-off: launches/activates the app. Ending a call is done in that app.
    public func openSelectedApp() {
        refresh()
        guard let provider = selectedProvider else {
            lastError = "Choose a call app first."
            return
        }
        guard let option = selectedOption else {
            lastError = "\(provider.displayName) isn't installed."
            return
        }
        lastError = nil
        apps.openApplication(at: option.appURL) { [weak self] error in
            guard let error else { return }
            let message = "Couldn't open \(option.name): \(error.localizedDescription)"
            Task { @MainActor in self?.lastError = message }
        }
    }

    // MARK: Microphone (default input device, system-level mute only)

    public func refreshMicrophone() {
        guard let device = mic.defaultInputDevice() else {
            isMicrophoneMuteAvailable = false
            isMicrophoneMuted = false
            microphoneHint = "No input device is available."
            return
        }
        let name = mic.deviceName(device) ?? "the default input"
        guard let muted = mic.muteState(device), mic.isMuteSettable(device) else {
            isMicrophoneMuteAvailable = false
            isMicrophoneMuted = mic.muteState(device) ?? false
            microphoneHint = "\(name) doesn't offer a system mute switch, so Notch can't mute it. Use the mute control in your call app."
            return
        }
        isMicrophoneMuteAvailable = true
        isMicrophoneMuted = muted
        microphoneHint = "Mutes \(name) for the whole Mac. This is separate from the mute button inside FaceTime, Teams or Zoom."
    }

    public func setMicrophoneMuted(_ muted: Bool) {
        guard let device = mic.defaultInputDevice(), mic.isMuteSettable(device) else {
            refreshMicrophone()
            lastError = "The current microphone doesn't support system mute."
            return
        }
        let status = mic.setMute(device, muted)
        let readback = mic.muteState(device)
        refreshMicrophone()
        if status != 0 {
            lastError = "Couldn't change microphone mute (error \(status))."
        } else if readback != muted {
            lastError = "The microphone didn't confirm the mute change."
        } else {
            lastError = nil
        }
    }
}
