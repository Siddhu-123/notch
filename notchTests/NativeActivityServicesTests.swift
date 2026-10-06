import Foundation
import Testing
@testable import notch

@MainActor
private final class FakeVoiceBackend: VoiceBackend {
    var pendingPermission: (@MainActor (VoicePermissionResult) -> Void)?
    var handlers: VoiceCaptureHandlers?
    var startCount = 0
    var stopCount = 0
    var endCount = 0
    var startError: Error?
    var onStartCapture: ((VoiceCaptureHandlers) -> Void)?

    func requestPermissions(_ completion: @escaping @MainActor (VoicePermissionResult) -> Void) {
        pendingPermission = completion
    }
    func startCapture(handlers: VoiceCaptureHandlers) throws {
        if let startError { throw startError }
        startCount += 1
        self.handlers = handlers
        onStartCapture?(handlers)
    }
    func stopCapture() { stopCount += 1 }
    func endCapture() { endCount += 1 }
}

private struct FakeApps: CallAppBackend {
    var installed: [String: URL]
    var running: Set<String> = []
    func applicationURL(bundleIdentifier: String) -> URL? { installed[bundleIdentifier] }
    func isRunning(bundleIdentifier: String) -> Bool { running.contains(bundleIdentifier) }
    func openApplication(at url: URL, completion: @escaping (Error?) -> Void) { completion(nil) }
}

private final class FakeMic: MicrophoneBackend, @unchecked Sendable {
    var device: UInt32? = 7
    var muted: Bool? = false
    var settable = true
    var ignoreWrites = false
    var writeStatus: Int32 = 0
    var writes: [Bool] = []
    func defaultInputDevice() -> UInt32? { device }
    func deviceName(_ device: UInt32) -> String? { "Test Mic" }
    func muteState(_ device: UInt32) -> Bool? { muted }
    func isMuteSettable(_ device: UInt32) -> Bool { settable && muted != nil }
    func setMute(_ device: UInt32, _ m: Bool) -> Int32 {
        writes.append(m)
        if writeStatus == 0 && !ignoreWrites { muted = m }
        return writeStatus
    }
}

private final class BatteryScanSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var next = 0
    let started = [DispatchSemaphore(value: 0), DispatchSemaphore(value: 0)]
    let release = [DispatchSemaphore(value: 0), DispatchSemaphore(value: 0)]
    let finished = [DispatchSemaphore(value: 0), DispatchSemaphore(value: 0)]

    func scan() -> [AccessoryBatteryDevice] {
        let index = lock.withLock { let index = next; next += 1; return index }
        guard index < 2 else { return [] }
        started[index].signal()
        defer { finished[index].signal() }
        guard release[index].wait(timeout: .now() + 2) == .success else { return [] }
        return [AccessoryBatteryDevice(id: index == 0 ? "slow" : "fast", name: "Test accessory", percentage: index == 0 ? 20 : 80, isCharging: false)]
    }

    func wait(_ signal: DispatchSemaphore) async -> Bool {
        await Task.detached { signal.wait(timeout: .now() + 2) == .success }.value
    }
}

struct NativeActivityServicesTests {

    @MainActor
    @Test func finishingWaitsForFinalAndCancellationDiscardsIt() {
        let backend = FakeVoiceBackend()
        let store = VoiceControlStore(backend: backend)
        store.isCommandModeEnabled = true
        var commands: [VoiceCommand] = []
        store.onCommand = { commands.append($0) }
        store.start()
        backend.pendingPermission?(.ready)
        backend.handlers?.onResult("open shelf", false)
        store.finishListening()
        #expect(store.isFinishing && backend.endCount == 1 && commands.isEmpty)
        backend.handlers?.onResult("open shelf", true)
        #expect(commands == [.openShelf] && !store.isFinishing && !store.isListening)
        store.start()
        backend.pendingPermission?(.ready)
        store.finishListening()
        let late = backend.handlers
        store.stop()
        late?.onResult("next", true)
        #expect(commands == [.openShelf] && !store.isFinishing)
    }

    // MARK: Command parser

    @Test func parserAcceptsKnownPhrasesOnly() {
        #expect(VoiceCommand.parse("Play") == .play)
        #expect(VoiceCommand.parse("  pause music. ") == .pause)
        #expect(VoiceCommand.parse("Next track!") == .next)
        #expect(VoiceCommand.parse("previous") == .previous)
        #expect(VoiceCommand.parse("Open shelf") == .openShelf)
        #expect(VoiceCommand.parse("open calendar") == .openCalendar)
        #expect(VoiceCommand.parse("open controls") == .openControls)
        #expect(VoiceCommand.parse("open mirror") == .openMirror)
        #expect(VoiceCommand.parse("pause focus") == .pauseFocus)
        #expect(VoiceCommand.parse("resume focus") == .resumeFocus)
        #expect(VoiceCommand.parse("reset focus") == .resetFocus)

        // Not whole-utterance matches: never guess.
        #expect(VoiceCommand.parse("please play the next song and delete everything") == nil)
        #expect(VoiceCommand.parse("play ") == .play)
        #expect(VoiceCommand.parse("delete shelf") == nil)
        #expect(VoiceCommand.parse("open shelf and quit") == nil)
        #expect(VoiceCommand.parse("") == nil)
        #expect(VoiceCommand.parse("pla") == nil)
    }

    @Test func parserBoundsFocusMinutes() {
        #expect(VoiceCommand.parse("start focus for 25 minutes") == .startFocus(minutes: 25))
        #expect(VoiceCommand.parse("focus 10 minutes") == .startFocus(minutes: 10))
        #expect(VoiceCommand.parse("start focus timer 0 minutes") == .startFocus(minutes: 1))
        #expect(VoiceCommand.parse("start focus 9999 minutes") == .startFocus(minutes: 180))
        #expect(VoiceCommand.parse("start focus 99999 minutes") == nil)
        #expect(VoiceCommand.parse("start focus") == .startFocus(minutes: VoiceCommand.defaultFocusMinutes))
        #expect(VoiceCommand.parse("start focus for lots minutes") == nil)
        #expect(VoiceCommand.parse("start focus 5 hours") == nil)
    }

    // MARK: Voice store lifecycle

    @MainActor
    @Test func initializationNeverRequestsPermissionsOrCapture() {
        let backend = FakeVoiceBackend()
        let store = VoiceControlStore(backend: backend)
        #expect(backend.pendingPermission == nil)
        #expect(backend.startCount == 0)
        #expect(!store.isListening && !store.isStarting)
    }

    @MainActor
    @Test func stopDuringPermissionRequestCannotRestartCapture() {
        let backend = FakeVoiceBackend()
        let store = VoiceControlStore(backend: backend)
        store.start()
        #expect(store.isStarting)
        let late = backend.pendingPermission
        store.stop()
        #expect(!store.isStarting)
        late?(.ready)
        #expect(backend.startCount == 0)
        #expect(!store.isListening)
    }

    @MainActor
    @Test func deniedPermissionSurfacesMessage() {
        let backend = FakeVoiceBackend()
        let store = VoiceControlStore(backend: backend)
        store.start()
        backend.pendingPermission?(.denied("Mic off"))
        #expect(store.lastError == "Mic off")
        #expect(store.availability == .denied("Mic off"))
        #expect(!store.isListening && !store.isStarting)
        #expect(backend.startCount == 0)
    }

    @MainActor
    @Test func partialResultsNeverExecuteAndFinalDoes() {
        let backend = FakeVoiceBackend()
        let store = VoiceControlStore(backend: backend)
        store.isCommandModeEnabled = true
        var commands: [VoiceCommand] = []
        store.onCommand = { commands.append($0) }
        store.start()
        backend.pendingPermission?(.ready)
        #expect(store.isListening)
        #expect(backend.startCount == 1)

        backend.handlers?.onLevel(0.5)
        #expect(store.inputLevel == 0.5)
        backend.handlers?.onResult("play", false)
        #expect(commands.isEmpty)
        #expect(store.transcript == "play")

        backend.handlers?.onResult("play", true)
        #expect(commands == [.play])
        #expect(!store.isListening)
        #expect(backend.stopCount >= 1)
        #expect(store.transcript == "play") // kept in memory until cleared
        store.clear()
        #expect(store.transcript.isEmpty)
    }

    @MainActor
    @Test func callbacksAfterStopAreIgnored() {
        let backend = FakeVoiceBackend()
        let store = VoiceControlStore(backend: backend)
        var commands: [VoiceCommand] = []
        store.onCommand = { commands.append($0) }
        store.start()
        backend.pendingPermission?(.ready)
        let handlers = backend.handlers
        store.stop()
        handlers?.onResult("next", true)
        handlers?.onError("late")
        #expect(commands.isEmpty)
        #expect(store.lastError == nil)
        #expect(store.transcript.isEmpty)
    }

    @MainActor
    @Test func captureStartFailureCleansUp() {
        let backend = FakeVoiceBackend()
        backend.startError = VoiceError.message("No mic")
        let store = VoiceControlStore(backend: backend)
        store.start()
        backend.pendingPermission?(.ready)
        #expect(store.lastError == "No mic")
        #expect(!store.isListening && !store.isStarting)
    }

    @MainActor
    @Test func timeoutStopsCapture() async throws {
        let backend = FakeVoiceBackend()
        let store = VoiceControlStore(backend: backend, timeout: 0.05)
        store.start()
        backend.pendingPermission?(.ready)
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(!store.isListening)
        #expect(store.lastError != nil)
    }

    @MainActor
    @Test func permissionTimeoutFailsStartupAndSurfacesSettingsMessage() async throws {
        let backend = FakeVoiceBackend()
        let store = VoiceControlStore(backend: backend, startupTimeout: 0.05)
        store.start()
        #expect(store.isStarting)
        let deadline = ContinuousClock.now + .seconds(2)
        while store.isStarting && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!store.isStarting)
        #expect(!store.isListening)
        #expect(store.lastError?.contains("Voice control startup timed out") == true)
        #expect(store.lastError?.contains("System Settings") == true)
    }

    @MainActor
    @Test func latePermissionCallbackAfterStartupTimeoutIsIgnored() async throws {
        let backend = FakeVoiceBackend()
        let store = VoiceControlStore(backend: backend, startupTimeout: 0.05)
        store.start()
        let latePermission = backend.pendingPermission
        let deadline = ContinuousClock.now + .seconds(2)
        while store.isStarting && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!store.isStarting)
        #expect(!store.isListening)
        let timedOutError = store.lastError

        // Late callback arrives after timeout
        latePermission?(.ready)
        #expect(!store.isStarting)
        #expect(!store.isListening)
        #expect(backend.startCount == 0)
        #expect(store.lastError == timedOutError)
    }

    @MainActor
    @Test func successfulStartupCancelsStartupTimeout() async throws {
        let backend = FakeVoiceBackend()
        let store = VoiceControlStore(backend: backend, timeout: 30, startupTimeout: 0.05)
        store.start()
        #expect(store.isStarting)
        backend.pendingPermission?(.ready)
        #expect(!store.isStarting)
        #expect(store.isListening)
        #expect(backend.startCount == 1)

        // Sleep longer than startupTimeout; capture should NOT time out
        try await Task.sleep(for: .milliseconds(150))
        #expect(store.isListening)
        #expect(store.lastError == nil)
    }

    // MARK: Battery parser

    @Test func batteryParserValidatesValues() {
        let ok = AccessoryBatteryParser.parse(["Product": "Magic Mouse", "BatteryPercent": 80, "DeviceAddress": "aa-bb", "IsCharging": true])
        #expect(ok == AccessoryBatteryDevice(id: "aa-bb", name: "Magic Mouse", percentage: 80, isCharging: true))

        // NSNumber booleans are not percentages and plain numbers are not booleans.
        #expect(AccessoryBatteryParser.parse(["Product": "X", "BatteryPercent": NSNumber(value: true), "DeviceAddress": "1"]) == nil)
        let numCharging = AccessoryBatteryParser.parse(["Product": "X", "BatteryPercent": 50, "DeviceAddress": "1", "IsCharging": NSNumber(value: 1)])
        #expect(numCharging?.isCharging == false)
        let boolCharging = AccessoryBatteryParser.parse(["Product": "X", "BatteryPercent": 50, "DeviceAddress": "1", "IsCharging": NSNumber(value: true)])
        #expect(boolCharging?.isCharging == true)

        for bad: Any in [-1, 101, Double.nan, "80", 1000] {
            #expect(AccessoryBatteryParser.parse(["Product": "X", "BatteryPercent": bad, "DeviceAddress": "1"]) == nil)
        }
        #expect(AccessoryBatteryParser.parse(["BatteryPercent": 50, "DeviceAddress": "1"]) == nil) // unnamed
        #expect(AccessoryBatteryParser.parse(["Product": "X", "BatteryPercent": 50]) == nil)      // no stable id
        #expect(AccessoryBatteryParser.parse(["Product": "X", "BatteryPercent": 50], fallbackID: "registry-9")?.id == "registry-9")
        #expect(AccessoryBatteryParser.parse(["Product": "X", "BatteryPercent": 0, "DeviceAddress": "z"])?.percentage == 0)
    }

    @Test func batteryParserFiltersInternalBattery() {
        #expect(AccessoryBatteryParser.parse(["Name": "InternalBattery-0", "Type": "InternalBattery", "Current Capacity": 90, "Max Capacity": 100, "Power Source ID": "1"]) == nil)
        #expect(AccessoryBatteryParser.parse(["Name": "Thing", "Transport Type": "Internal", "Current Capacity": 90, "Max Capacity": 100, "Power Source ID": "1"]) == nil)
        let ups = AccessoryBatteryParser.parse(["Name": "UPS", "Type": "UPS", "Transport Type": "USB", "Current Capacity": 50, "Max Capacity": 200, "Power Source ID": "2"])
        #expect(ups?.percentage == 25)
    }

    @MainActor
    @Test func synchronousFinalDuringStartCaptureExecutesAndTearsDown() {
        let backend = FakeVoiceBackend()
        var executed: [VoiceCommand] = []
        backend.onStartCapture = { handlers in
            handlers.onResult("play", true)
        }
        let store = VoiceControlStore(backend: backend)
        store.isCommandModeEnabled = true
        store.onCommand = { executed.append($0) }
        store.start()
        backend.pendingPermission?(.ready)

        #expect(executed == [.play])
        #expect(!store.isListening)
        #expect(!store.isStarting)
        #expect(store.lastCommand == .play)
        #expect(backend.stopCount >= 1)
    }

    @MainActor
    @Test func synchronousFailureDuringStartCaptureCleansUpWithoutLeavingListening() {
        let backend = FakeVoiceBackend()
        backend.onStartCapture = { handlers in
            handlers.onError("Speech recognizer faulted immediately")
        }
        let store = VoiceControlStore(backend: backend)
        store.start()
        backend.pendingPermission?(.ready)

        #expect(!store.isListening)
        #expect(!store.isStarting)
        #expect(store.lastError == "Speech recognizer faulted immediately")
        #expect(backend.stopCount >= 1)
    }

    @MainActor
    @Test func unsupportedFinalFeedbackDistinguishesUnsupportedAndSilence() {
        let backend = FakeVoiceBackend()
        let store = VoiceControlStore(backend: backend)
        store.isCommandModeEnabled = true
        var executed: [VoiceCommand] = []
        store.onCommand = { executed.append($0) }

        // Unsupported command
        store.start()
        backend.pendingPermission?(.ready)
        backend.handlers?.onResult("make me a coffee", true)
        #expect(executed.isEmpty)
        #expect(!store.isListening)
        #expect(store.lastError == "No supported command recognized.")
        #expect(store.lastCommand == nil)

        // Silence / whitespace-only
        store.start()
        backend.pendingPermission?(.ready)
        backend.handlers?.onResult("   ", true)
        #expect(executed.isEmpty)
        #expect(!store.isListening)
        #expect(store.lastError == "No command recognized: silence")
        #expect(store.lastCommand == nil)
    }

    @MainActor
    @Test func captureClearsPreviousTranscriptOnlyWhenCaptureBegins() {
        let backend = FakeVoiceBackend()
        let store = VoiceControlStore(backend: backend)
        store.isCommandModeEnabled = true
        var commands: [VoiceCommand] = []
        store.onCommand = { commands.append($0) }

        // First session: produces a transcript
        store.start()
        backend.pendingPermission?(.ready)
        backend.handlers?.onResult("open shelf", true)
        #expect(store.transcript == "open shelf")
        #expect(commands == [.openShelf])

        // Starting a new session: transcript is retained while starting / requesting permission
        store.start()
        #expect(store.isStarting)
        #expect(store.transcript == "open shelf")

        // Once permission is granted and beginCapture runs, transcript clears
        backend.pendingPermission?(.ready)
        #expect(store.isListening)
        #expect(store.transcript.isEmpty)
    }

    @MainActor
    @Test func deniedPermissionRetainsPriorTranscript() {
        let backend = FakeVoiceBackend()
        let store = VoiceControlStore(backend: backend)

        // First session: completed with transcript
        store.start()
        backend.pendingPermission?(.ready)
        backend.handlers?.onResult("pause focus", true)
        #expect(store.transcript == "pause focus")

        // Second session: denied permission
        store.start()
        #expect(store.transcript == "pause focus")
        backend.pendingPermission?(.denied("Microphone access denied"))
        #expect(!store.isStarting)
        #expect(!store.isListening)
        #expect(store.lastError == "Microphone access denied")
        // Prior transcript remains intact
        #expect(store.transcript == "pause focus")
    }

    @MainActor
    @Test func preflightValidationBlocksUnavailableCommandExecution() {
        let backend = FakeVoiceBackend()
        let store = VoiceControlStore(backend: backend)
        store.isCommandModeEnabled = true
        var commands: [VoiceCommand] = []
        store.onCommand = { commands.append($0) }

        var hasActiveTrack = false
        store.preflightCommand = { command in
            switch command {
            case .play, .pause, .next, .previous:
                return hasActiveTrack ? nil : "No active music track."
            default:
                return nil
            }
        }

        // 1. Try media command with no active track
        store.start()
        backend.pendingPermission?(.ready)
        backend.handlers?.onResult("play", true)
        #expect(commands.isEmpty)
        #expect(store.lastError == "No active music track.")
        #expect(store.lastCommand == .play) // command was recognized but prevented from executing

        // 2. Navigation / focus command works even when media is unavailable
        store.start()
        backend.pendingPermission?(.ready)
        backend.handlers?.onResult("open calendar", true)
        #expect(commands == [.openCalendar])
        #expect(store.lastError == nil)
        #expect(store.lastCommand == .openCalendar)

        // 3. Media command with active track succeeds
        hasActiveTrack = true
        store.start()
        backend.pendingPermission?(.ready)
        backend.handlers?.onResult("next track", true)
        #expect(commands == [.openCalendar, .next])
        #expect(store.lastError == nil)
        #expect(store.lastCommand == .next)
    }

    @MainActor
    @Test func dictationIsDefaultAndOnlyExplicitCommandModeExecutes() {
        let backend = FakeVoiceBackend()
        let store = VoiceControlStore(backend: backend)
        var commands: [VoiceCommand] = []
        store.onCommand = { commands.append($0) }
        #expect(!store.isCommandModeEnabled)

        store.start()
        backend.pendingPermission?(.ready)
        backend.handlers?.onResult("play", true)
        #expect(store.transcript == "play")
        #expect(commands.isEmpty)
        #expect(store.lastCommand == nil)
        #expect(store.lastError == nil)

        store.start()
        backend.pendingPermission?(.ready)
        backend.handlers?.onResult("remember to buy milk", true)
        #expect(store.transcript == "remember to buy milk")
        #expect(commands.isEmpty)
        #expect(store.lastCommand == nil)
        #expect(store.lastError == nil)

        store.isCommandModeEnabled = true
        store.start()
        backend.pendingPermission?(.ready)
        backend.handlers?.onResult("play", false)
        #expect(commands.isEmpty)
        backend.handlers?.onResult("play", true)
        #expect(commands == [.play])
        #expect(store.lastCommand == .play)
        #expect(store.lastError == nil)
    }

    @MainActor
    @Test func batteryMonitorReportsEmptyWithoutInventing() async throws {
        let monitor = AccessoryBatteryMonitor(provider: { [] })
        monitor.apply([])
        #expect(monitor.devices.isEmpty)
        #expect(monitor.statusMessage.contains("No accessory"))
        monitor.apply([AccessoryBatteryDevice(id: "a", name: "Keyboard", percentage: 40, isCharging: false)])
        #expect(monitor.devices.count == 1)
        monitor.startPolling(interval: 1)
        #expect(monitor.isPolling)
        monitor.stopPolling()
        #expect(!monitor.isPolling)
        #expect(AccessoryBatteryMonitor.minimumPollInterval >= 30)
    }

    @MainActor
    @Test func batteryMonitorTracksRefreshingAndDiscardsStaleRefreshAfterStopOrNewer() async throws {
        let sequence = BatteryScanSequence()
        defer { sequence.release.forEach { $0.signal() } }
        let monitor = AccessoryBatteryMonitor(provider: { sequence.scan() })
        monitor.refresh()
        #expect(monitor.isRefreshing)
        #expect(await sequence.wait(sequence.started[0]))
        monitor.stopPolling()
        #expect(!monitor.isRefreshing)
        sequence.release[0].signal()
        #expect(await sequence.wait(sequence.finished[0]))
        try await Task.sleep(for: .milliseconds(20))
        #expect(monitor.devices.isEmpty)

        let ordering = BatteryScanSequence()
        defer { ordering.release.forEach { $0.signal() } }
        let orderingMonitor = AccessoryBatteryMonitor(provider: { ordering.scan() })
        orderingMonitor.refresh()
        #expect(await ordering.wait(ordering.started[0]))
        orderingMonitor.refresh()
        #expect(await ordering.wait(ordering.started[1]))
        ordering.release[1].signal()
        let deadline = ContinuousClock.now + .seconds(2)
        while orderingMonitor.isRefreshing && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!orderingMonitor.isRefreshing)
        #expect(orderingMonitor.devices.map(\.id) == ["fast"])
        ordering.release[0].signal()
        #expect(await ordering.wait(ordering.finished[0]))
        try await Task.sleep(for: .milliseconds(20))
        #expect(orderingMonitor.devices.map(\.id) == ["fast"])
    }

    // MARK: Call companion + microphone

    private func freshDefaults() -> (UserDefaults, String) {
        let name = UUID().uuidString
        return (UserDefaults(suiteName: name)!, name)
    }

    @MainActor
    @Test func callOptionsReflectInstalledAndRunning() {
        let (defaults, name) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let apps = FakeApps(installed: ["com.apple.FaceTime": URL(fileURLWithPath: "/Applications/FaceTime.app"),
                                        "com.microsoft.teams2": URL(fileURLWithPath: "/Applications/Teams.app")],
                            running: ["com.microsoft.teams2"])
        let store = CallCompanionStore(defaults: defaults, apps: apps, microphone: FakeMic())
        #expect(store.options.map(\.provider) == [.faceTime, .teams])
        #expect(store.options.first { $0.provider == .teams }?.isRunning == true)
        #expect(store.options.first { $0.provider == .faceTime }?.isRunning == false)

        store.selectProvider(.zoom)
        store.openSelectedApp()
        #expect(store.lastError == "Zoom isn't installed.")

        store.selectProvider(.teams)
        let restored = CallCompanionStore(defaults: defaults, apps: apps, microphone: FakeMic())
        #expect(restored.selectedProvider == .teams)
        restored.openSelectedApp()
        #expect(restored.lastError == nil)
    }

    @MainActor
    @Test func microphoneMuteRoundTripAndReadback() {
        let (defaults, name) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let mic = FakeMic()
        let store = CallCompanionStore(defaults: defaults, apps: FakeApps(installed: [:]), microphone: mic)
        store.refreshMicrophone()
        #expect(store.isMicrophoneMuteAvailable)
        #expect(!store.isMicrophoneMuted)

        store.setMicrophoneMuted(true)
        #expect(store.isMicrophoneMuted)
        #expect(store.lastError == nil)
        #expect(mic.writes == [true])

        mic.ignoreWrites = true
        store.setMicrophoneMuted(false)
        #expect(store.isMicrophoneMuted) // readback wins
        #expect(store.lastError != nil)

        mic.ignoreWrites = false
        mic.writeStatus = -1
        store.setMicrophoneMuted(false)
        #expect(store.lastError?.contains("error") == true)
    }

    @MainActor
    @Test func microphoneUnavailableWhenNotWritable() {
        let (defaults, name) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let mic = FakeMic()
        mic.muted = nil
        let store = CallCompanionStore(defaults: defaults, apps: FakeApps(installed: [:]), microphone: mic)
        store.refreshMicrophone()
        #expect(!store.isMicrophoneMuteAvailable)
        store.setMicrophoneMuted(true)
        #expect(mic.writes.isEmpty) // never writes when not settable
        #expect(store.lastError != nil)

        mic.device = nil
        store.refreshMicrophone()
        #expect(store.microphoneHint == "No input device is available.")
    }
    @MainActor
    @Test func runningTeamsAliasWinsOverFirstInstalledAlias() {
        let (defaults, name) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let installed = ["com.microsoft.teams2": URL(fileURLWithPath: "/Applications/NewTeams.app"),
                         "com.microsoft.teams": URL(fileURLWithPath: "/Applications/Teams.app")]
        let running = CallCompanionStore(defaults: defaults, apps: FakeApps(installed: installed, running: ["com.microsoft.teams"]), microphone: FakeMic())
        running.selectProvider(.teams)
        #expect(running.selectedOption?.bundleIdentifier == "com.microsoft.teams")
        #expect(running.selectedOption?.isRunning == true)
        let idle = CallCompanionStore(defaults: defaults, apps: FakeApps(installed: installed), microphone: FakeMic())
        #expect(idle.selectedOption?.bundleIdentifier == "com.microsoft.teams2")
        #expect(idle.selectedOption?.isRunning == false)
    }

}
