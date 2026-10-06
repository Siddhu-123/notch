//
//  notchTests.swift
//  notchTests
//
//  Created by Balanagu Satya Siddhartha on 12/8/2025.
//

import AppKit
import CoreAudio
import Foundation
import SwiftUI
import Testing
@testable import notch

struct notchTests {

    @Test func modulesExposeTheCoreNotchSurfaces() {
        #expect(NotchModule.allCases.map(\.rawValue) == ["nowPlaying", "shelf", "apps", "calendar", "controls", "mirror", "workspace", "toolkit"])
        #expect(NotchModule.shelf.symbol == "tray.full")
        #expect(NotchModule.apps.title == "Apps")
        #expect(NotchModule.apps.symbol == "square.grid.2x2.fill")
        #expect(NotchModule.controls.title == "Controls")
        #expect(NotchModule.mirror.symbol == "camera.viewfinder")
        #expect(NotchModule.calendar.tagline == "Your next moments")
        #expect(NotchModule.allCases.map(\.index) == [0, 1, 2, 3, 4, 5, 6, 7])
    }

    @Test func interactionAndSizingPresetsRemainPredictable() {
        #expect(NotchInteraction.hover.expandsOnHover)
        #expect(NotchInteraction.hover.expandsOnClick == false)
        #expect(NotchInteraction.click.expandsOnHover == false)
        #expect(NotchInteraction.click.expandsOnClick)
        #expect(NotchSizePreset.standard.expandedSize == CGSize(width: 720, height: 270))
        #expect(NotchSizePreset.compact.fallbackCollapsedSize.width < NotchSizePreset.roomy.fallbackCollapsedSize.width)
        #expect(DisplayNotchGeometry.fallback.coreWidth == 154)
    }

    @Test func expandedLayoutReservesOnlyMeasuredHardwareNotchHeight() {
        let external = DisplayNotchGeometry(coreWidth: 154, height: 30, hasHardwareNotch: false, screenNumber: 2)
        let builtIn = DisplayNotchGeometry(coreWidth: 154, height: 32, hasHardwareNotch: true, screenNumber: 1)

        #expect(ExpandedPanelLayout.cameraSafeHeight(for: external) == 0)
        #expect(ExpandedPanelLayout.cameraSafeHeight(for: builtIn) == 32)
        #expect(ExpandedPanelLayout.contentHeight(expandedHeight: 270, railThickness: 54, geometry: external) == 156)
        #expect(ExpandedPanelLayout.contentHeight(expandedHeight: 270, railThickness: 54, geometry: builtIn) == 156)
    }

    @Test func directPagesFitSectionsAndRemainInsideScreen() {
        let geometry = DisplayNotchGeometry(coreWidth: 154, height: 30, hasHardwareNotch: false, screenNumber: 2)
        for preset in NotchSizePreset.allCases {
            let base = preset.expandedSize
            for (module, minimum) in [(NotchModule.calendar, CGFloat(240)), (.controls, 340), (.shelf, preset == .roomy ? 220 : 400)] {
                let height = ExpandedPanelLayout.fittedHeight(base: base, module: module, geometry: geometry, railThickness: preset.railThickness, agentsBelow: false, availableHeight: 800)
                #expect(ExpandedPanelLayout.contentHeight(expandedHeight: height, railThickness: preset.railThickness, geometry: geometry) >= minimum - 0.001)
            }
            let belowHeight = ExpandedPanelLayout.fittedHeight(base: base, module: .nowPlaying, geometry: geometry, railThickness: preset.railThickness, agentsBelow: true, availableHeight: 800)
            #expect(ExpandedPanelLayout.contentHeight(expandedHeight: belowHeight, railThickness: preset.railThickness, geometry: geometry) >= 160 + AgentColumnLayout.belowHeight + AgentColumnLayout.gap - 0.001)
            #expect(ExpandedPanelLayout.fittedHeight(base: base, module: .calendar, geometry: geometry, railThickness: preset.railThickness, agentsBelow: true, availableHeight: 250) == 250)
        }
    }

    @Test func railThicknessFollowsPresetNotPanelWidth() {
        #expect(NotchSizePreset.compact.railThickness == 48.75)
        #expect(NotchSizePreset.standard.railThickness == 54)
        #expect(NotchSizePreset.roomy.railThickness == 60)
    }

    @Test func agentColumnNeedsDestinationPlusColumnAndScreenClearance() {
        #expect(AgentColumnLayout.fitsBeside(destinationWidth: 650, visibleWidth: 1512))
        #expect(AgentColumnLayout.fitsBeside(destinationWidth: 650, visibleWidth: 1014))
        #expect(!AgentColumnLayout.fitsBeside(destinationWidth: 800, visibleWidth: 1024))
    }

    @Test func expandedHeaderWingsUseRailInteriorAndNeverGoNegative() {
        #expect(ExpandedPanelLayout.headerWingWidth(expandedWidth: 720, cameraWidth: 154, railThickness: 54) == 217)
        #expect(ExpandedPanelLayout.headerWingWidth(expandedWidth: 100, cameraWidth: 260, railThickness: 7.5) == 0)
    }

    @Test func screenTargetPrefersStartupPointerAndRetainsFollowedDisplay() {
        let screens = [
            DisplayScreenCandidate(number: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900), hasHardwareNotch: true),
            DisplayScreenCandidate(number: 2, frame: CGRect(x: 1440, y: 0, width: 1280, height: 800), hasHardwareNotch: false)
        ]
        let pointerOnExternal = CGPoint(x: 1800, y: 400)

        #expect(DisplayScreenTargetPolicy.screenNumber(
            at: pointerOnExternal, screens: screens, currentScreenNumber: nil, followPointerDisplay: true
        ) == 2)
        #expect(DisplayScreenTargetPolicy.screenNumber(
            at: pointerOnExternal, screens: screens, currentScreenNumber: 1, followPointerDisplay: true
        ) == 1)
        #expect(DisplayScreenTargetPolicy.screenNumber(
            at: pointerOnExternal, screens: screens, currentScreenNumber: 2, followPointerDisplay: false
        ) == 1)
    }

    @Test func fullscreenRequiresAbsentMenubarAndCoveringForegroundWindow() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let fullscreenWindow = FullScreenDetector.WindowEvidence(
            layer: 0, alpha: 1, bounds: screen, hasOwnerProcess: true
        )
        let partialWindow = FullScreenDetector.WindowEvidence(
            layer: 0, alpha: 1, bounds: CGRect(x: 0, y: 0, width: 1000, height: 900), hasOwnerProcess: true
        )
        let floatingWindow = FullScreenDetector.WindowEvidence(
            layer: 2, alpha: 1, bounds: screen, hasOwnerProcess: true
        )
        let ownerUnavailable = FullScreenDetector.WindowEvidence(
            layer: 0, alpha: 1, bounds: screen, hasOwnerProcess: false
        )

        #expect(FullScreenDetector.isFullScreen(screenRect: screen, hasMenubar: false, foregroundWindow: fullscreenWindow))
        #expect(!FullScreenDetector.isFullScreen(screenRect: screen, hasMenubar: true, foregroundWindow: fullscreenWindow))
        #expect(!FullScreenDetector.isFullScreen(screenRect: screen, hasMenubar: false, foregroundWindow: partialWindow))
        #expect(!FullScreenDetector.isFullScreen(screenRect: screen, hasMenubar: false, foregroundWindow: floatingWindow))
        #expect(!FullScreenDetector.isFullScreen(screenRect: screen, hasMenubar: false, foregroundWindow: ownerUnavailable))
        #expect(!FullScreenDetector.isFullScreen(screenRect: screen, hasMenubar: false, foregroundWindow: nil))
    }

    @Test func displayTransferRequiresAnotherDisplaysTopCenterTrigger() {
        let screens: [(number: UInt32, frame: CGRect)] = [
            (1, CGRect(x: 0, y: 0, width: 1440, height: 900)),
            (2, CGRect(x: 1440, y: 0, width: 1280, height: 800))
        ]

        #expect(DisplayTransferPolicy.triggerScreenNumber(
            at: CGPoint(x: 2080, y: 795), screens: screens, currentScreenNumber: 1
        ) == 2)
        #expect(DisplayTransferPolicy.triggerScreenNumber(
            at: CGPoint(x: 1500, y: 795), screens: screens, currentScreenNumber: 1
        ) == nil)
        #expect(DisplayTransferPolicy.triggerScreenNumber(
            at: CGPoint(x: 720, y: 895), screens: screens, currentScreenNumber: 1
        ) == nil)
    }

    @Test func batterySnapshotReportsUsableValues() {
        let battery = BatterySnapshot(level: 0.42, isCharging: false, isPluggedIn: true)
        #expect(battery.percentage == 42)
        #expect(battery.symbol == "battery.50percent")
        #expect(BatterySnapshot(level: 1.4).percentage == 100)
        #expect(BatterySnapshot(level: -0.2).percentage == 0)
    }

    @Test func shelfItemsAreCodable() throws {
        let item = ShelfItem(id: UUID(), name: "Brief.pdf", path: "/tmp/Brief.pdf", bookmarkData: Data([1, 2, 3]))
        let data = try JSONEncoder().encode([item])
        let decoded = try JSONDecoder().decode([ShelfItem].self, from: data)
        #expect(decoded == [item])
        #expect(decoded[0].url.path == "/tmp/Brief.pdf")

        let link = ShelfItem(id: UUID(), name: "Apple", path: "https://apple.com", bookmarkData: nil, kind: .link)
        #expect(link.isFile == false)
        #expect(link.url.host == "apple.com")
    }

    @Test func emptyNowPlayingStateIsSafe() {
        #expect(NowPlayingSong.placeholder.hasTrack == false)
        #expect(NowPlayingSong.placeholder.progress == 0)
        #expect(NowPlayingSong.placeholder.formattedRemainingTime == "-0:00")
    }

    @Test func remainingTimeCalculationsAreAccurate() {
        var song = NowPlayingSong.placeholder
        song.duration = 203 // 3 mins 23 secs
        song.elapsed = 130 // 2 mins 10 secs
        // remaining = 73 secs = 1 min 13 secs
        #expect(song.formattedRemainingTime == "-1:13")
    }

    @Test func audioSpectrumAlwaysProducesEightDbBands() {
        #expect(AudioSpectrumAnalyzer.bandCount == 8)
        #expect(AudioSpectrumAnalyzer.bandEdgesHz.count == 9)
        #expect(AudioSpectrumAnalyzer.bandEdgesHz.first == 60)
        #expect(AudioSpectrumAnalyzer.bandEdgesHz.last == 16_000)

        let silence = AudioSpectrumAnalyzer.analyze(
            samples: Array(repeating: 0, count: 2_048),
            sampleRate: 48_000
        )
        #expect(silence.count == 8)
        #expect(silence.allSatisfy { $0 == AudioSpectrumAnalyzer.floorDecibels })
    }

    @Test func audioSpectrumPlacesToneInTheCorrectFrequencyBand() {
        let sampleRate: Float = 48_000
        let frequency: Float = 1_000
        let samples = (0..<2_048).map { index in
            sin(2 * Float.pi * frequency * Float(index) / sampleRate) * 0.8
        }
        let bands = AudioSpectrumAnalyzer.analyze(samples: samples, sampleRate: sampleRate)
        let strongestBand = bands.indices.max { bands[$0] < bands[$1] }

        #expect(strongestBand == 4)
        #expect(bands[4] > bands[0] + 12)
        #expect(bands[4] > bands[7] + 12)
    }

    @Test func audioSpectrumNormalizesDbForBarHeights() {
        #expect(AudioSpectrumAnalyzer.normalizedLevel(decibels: -80) == 0)
        #expect(AudioSpectrumAnalyzer.normalizedLevel(decibels: 4) == 1)
        #expect(abs(AudioSpectrumAnalyzer.normalizedLevel(decibels: -30) - 0.5) < 0.001)
    }

    @MainActor
    @Test func rapidModuleSelectionsAlwaysEndOnTheLastRequestedTab() {
        let model = NotchModel.shared
        model.updatePinned(false)
        model.updateScreenFullScreen(false)
        model.updateShelf(true)
        model.setExpansionState(.collapsed)

        for module in [NotchModule.nowPlaying, .shelf, .apps, .nowPlaying, .apps] {
            model.select(module)
        }

        #expect(model.activeModule == .apps)
        #expect(model.expansionState == .expanded)
        #expect(model.isLockedOpen)
    }

    @MainActor
    @Test func threeTierExpansionStateTransitionsCorrectly() {
        let model = NotchModel.shared
        model.updatePinned(false)
        model.updateScreenFullScreen(false)
        model.setExpansionState(.collapsed)
        #expect(model.expansionState == .collapsed)
        #expect(model.isExpanded == false)
        #expect(model.visibleSize == model.collapsedSize)

        model.expandMinimal()
        #expect(model.expansionState == .minimal)
        #expect(model.isExpanded == true)
        #expect(model.visibleSize == model.minimalSize)
        #expect(model.minimalSize.width >= 250 && model.minimalSize.width <= 280)
        #expect(model.minimalSize.height > model.collapsedSize.height)

        model.expandFull()
        #expect(model.expansionState == .expanded)
        #expect(model.isExpanded == true)
        #expect(model.isLockedOpen == true)
        #expect(model.visibleSize == model.expandedSize)

        model.unlockAndCollapse()
        #expect(model.expansionState == .collapsed)
        #expect(model.isExpanded == false)
        #expect(model.isLockedOpen == false)
    }

    @MainActor
    @Test func fullScreenAutoHideTransitionsCorrectly() {
        let model = NotchModel.shared
        model.updateVisible(true)
        model.updatePinned(false)
        model.setExpansionState(.collapsed)
        model.updateAutoHideInFullScreen(true)

        // Normal space: not tucked
        model.updateScreenFullScreen(false)
        #expect(model.isTucked == false)

        // Full screen space: tucked
        model.updateScreenFullScreen(true)
        #expect(model.isTucked == true)

        // Hover reveals notch
        model.revealInFullScreen()
        #expect(model.isRevealedInFullScreen == true)
        #expect(model.isTucked == false)

        // Expanding keeps it untucked
        model.expandFull()
        #expect(model.isTucked == false)

        // Collapsing while revealed
        model.unlockAndCollapse()
        #expect(model.isRevealedInFullScreen == true)
        #expect(model.isTucked == false)

        // Disabling auto-hide keeps it untucked
        model.updateAutoHideInFullScreen(false)
        #expect(model.isTucked == false)

        // Re-enabling auto-hide tucks again in full screen
        model.isRevealedInFullScreen = false
        model.updateAutoHideInFullScreen(true)
        #expect(model.isTucked == true)

        // Pinning overrides tucking
        model.updatePinned(true)
        #expect(model.isTucked == false)

        // Reset back to clean state
        model.updatePinned(false)
        model.updateScreenFullScreen(false)
        #expect(model.isTucked == false)
    }

    final class MockAudioBackend: AudioSystemBackend {
        var devices: [AudioOutputDevice] = []
        var defaultID: AudioDeviceID? = nil
        var capabilities: [AudioDeviceID: AudioCapabilities] = [:]
        var writtenVolumes: [(device: AudioDeviceID, volume: Double)] = []
        var writtenMutes: [(device: AudioDeviceID, muted: Bool)] = []
        var defaultDeviceListener: (() -> Void)?
        var deviceListListener: (() -> Void)?

        var switchResult: Result<Void, AudioOutputController.AudioOutputError> = .success(())
        var volumeWriteResult: Bool = true
        var muteWriteResult: Bool = true

        var onSetDefaultOutputDevice: (() -> Void)?
        var onWriteVolume: (() -> Void)?
        var onWriteMuted: (() -> Void)?

        func defaultOutputDeviceID() -> AudioDeviceID? {
            defaultID
        }

        func listOutputDevices() -> (devices: [AudioOutputDevice], defaultID: AudioDeviceID?) {
            let updatedDevices = devices.map { dev in
                AudioOutputDevice(id: dev.id, uid: dev.uid, name: dev.name, symbol: dev.symbol, isDefault: dev.id == defaultID)
            }
            return (updatedDevices, defaultID)
        }

        func setDefaultOutputDevice(id: AudioDeviceID) -> Result<Void, AudioOutputController.AudioOutputError> {
            onSetDefaultOutputDevice?()
            switch switchResult {
            case .success:
                defaultID = id
                return .success(())
            case .failure(let error):
                return .failure(error)
            }
        }

        func readCapabilities(device: AudioDeviceID?) -> AudioCapabilities {
            guard let id = device ?? defaultID else {
                return AudioCapabilities(volume: 0, isMuted: false, isVolumeAvailable: false, isMuteAvailable: false, hint: "No audio output device found")
            }
            return capabilities[id] ?? AudioCapabilities(volume: 0.5, isMuted: false, isVolumeAvailable: true, isMuteAvailable: true, hint: "")
        }

        func writeVolume(_ value: Double, forDevice deviceID: AudioDeviceID) -> Bool {
            onWriteVolume?()
            writtenVolumes.append((deviceID, value))
            if volumeWriteResult {
                if var cap = capabilities[deviceID] {
                    cap.volume = value
                    capabilities[deviceID] = cap
                }
                return true
            }
            return false
        }

        func writeMuted(_ value: Bool, forDevice deviceID: AudioDeviceID) -> Bool {
            onWriteMuted?()
            writtenMutes.append((deviceID, value))
            if muteWriteResult {
                if var cap = capabilities[deviceID] {
                    cap.isMuted = value
                    capabilities[deviceID] = cap
                }
                return true
            }
            return false
        }

        func addDefaultDeviceListener(_ block: @escaping () -> Void) -> Any? {
            defaultDeviceListener = block
            return "default-listener-token"
        }

        func addDeviceListListener(_ block: @escaping () -> Void) -> Any? {
            deviceListListener = block
            return "list-listener-token"
        }

        func removeListener(_ token: Any) {
            if (token as? String) == "default-listener-token" {
                defaultDeviceListener = nil
            }
            if (token as? String) == "list-listener-token" {
                deviceListListener = nil
            }
        }
    }

    @MainActor
    private static func waitForCondition(timeoutNanoseconds: UInt64 = 2_000_000_000, condition: @escaping () -> Bool) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while !condition() {
            if DispatchTime.now().uptimeNanoseconds > deadline {
                Issue.record("Timed out waiting for expected condition")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @MainActor
    @Test func debouncedVolumeThenSelectFixedVolumeRouteCancelsWriteAndUpdatesCaps() async throws {
        let backend = MockAudioBackend()
        let speaker = AudioOutputDevice(id: 10, uid: "uid-speaker", name: "Internal Speakers", symbol: "laptopcomputer", isDefault: true)
        let hdmi = AudioOutputDevice(id: 20, uid: "uid-hdmi", name: "HDMI Output", symbol: "display", isDefault: false)
        backend.devices = [speaker, hdmi]
        backend.defaultID = 10
        backend.capabilities[10] = AudioCapabilities(volume: 0.5, isMuted: false, isVolumeAvailable: true, isMuteAvailable: true, hint: "")
        backend.capabilities[20] = AudioCapabilities(volume: 1.0, isMuted: false, isVolumeAvailable: false, isMuteAvailable: false, hint: "Volume fixed • use device controls")

        let center = SystemControlCenter(backend: backend, startListeners: false)
        center.refreshAudioState()
        try await Self.waitForCondition { center.currentOutputDeviceID == 10 && center.isVolumeAvailable }

        // Start debounced volume adjustment
        center.setVolume(0.8)
        #expect(center.volume == 0.8)

        // Immediately select fixed-volume HDMI route before debounce fires
        center.selectOutputDevice(hdmi)
        #expect(center.isSwitchingOutput == true)

        try await Self.waitForCondition { !center.isSwitchingOutput }

        #expect(center.currentOutputDeviceID == 20)
        #expect(center.isVolumeAvailable == false)
        #expect(center.isMuteAvailable == false)
        #expect(center.audioControlsHint.contains("use device controls"))
        // Debounced volume write to speaker should have been cancelled
        #expect(backend.writtenVolumes.isEmpty)
    }

    @MainActor
    @Test func refreshDuringActiveSwitchStillCompletes() async throws {
        let backend = MockAudioBackend()
        let devA = AudioOutputDevice(id: 1, uid: "uid-1", name: "Headphones", symbol: "headphones", isDefault: true)
        let devB = AudioOutputDevice(id: 2, uid: "uid-2", name: "Speakers", symbol: "laptopcomputer", isDefault: false)
        backend.devices = [devA, devB]
        backend.defaultID = 1
        backend.capabilities[1] = AudioCapabilities(volume: 0.4, isMuted: false, isVolumeAvailable: true, isMuteAvailable: true, hint: "")
        backend.capabilities[2] = AudioCapabilities(volume: 0.7, isMuted: false, isVolumeAvailable: true, isMuteAvailable: true, hint: "")

        final class SwitchCoordinator: @unchecked Sendable {
            private let lock = NSLock()
            private var _hasStarted = false
            private var _allowFinish = false

            var hasStarted: Bool {
                lock.lock()
                defer { lock.unlock() }
                return _hasStarted
            }

            var allowFinish: Bool {
                lock.lock()
                defer { lock.unlock() }
                return _allowFinish
            }

            func markStarted() {
                lock.lock()
                _hasStarted = true
                lock.unlock()
            }

            func permitFinish() {
                lock.lock()
                _allowFinish = true
                lock.unlock()
            }
        }

        let coordinator = SwitchCoordinator()
        backend.onSetDefaultOutputDevice = {
            coordinator.markStarted()
            while !coordinator.allowFinish {
                usleep(1_000)
            }
        }

        let center = SystemControlCenter(backend: backend, startListeners: false)
        center.refreshAudioState()
        try await Self.waitForCondition { center.currentOutputDeviceID == 1 }

        center.selectOutputDevice(devB)
        #expect(center.isSwitchingOutput == true)

        // Wait until switch execution has begun in backend
        try await Self.waitForCondition { coordinator.hasStarted }

        // Trigger periodic or event refresh while switch is in progress
        center.refreshAudioState()

        // Unblock backend setDefaultOutputDevice
        coordinator.permitFinish()

        // Switch completion must not return early or be stranded
        try await Self.waitForCondition { !center.isSwitchingOutput }
        #expect(center.currentOutputDeviceID == 2)
        #expect(center.volume == 0.7)
        #expect(center.outputSwitchError == nil)
    }

    @MainActor
    @Test func refreshDuringWriteDoesNotStrandState() async throws {
        let backend = MockAudioBackend()
        let dev = AudioOutputDevice(id: 1, uid: "uid-1", name: "Speakers", symbol: "laptopcomputer", isDefault: true)
        backend.devices = [dev]
        backend.defaultID = 1
        backend.capabilities[1] = AudioCapabilities(volume: 0.3, isMuted: false, isVolumeAvailable: true, isMuteAvailable: true, hint: "")

        let center = SystemControlCenter(backend: backend, startListeners: false)
        center.refreshAudioState()
        try await Self.waitForCondition { center.currentOutputDeviceID == 1 }

        // Trigger mute write
        center.toggleMute()
        #expect(center.isMuted == true)

        // Refresh triggered while isApplyingAudio is active
        center.refreshAudioState()

        // Mute write completes and clears isApplyingAudio; refresh must not strand busy state or overwrite
        try await Self.waitForCondition { backend.writtenMutes.count == 1 }
        #expect(center.isMuted == true)
        #expect(center.outputSwitchError == nil)
    }

    @MainActor
    @Test func failedVolumeAndFailedMuteReconcileActualValuesWithVisibleError() async throws {
        let backend = MockAudioBackend()
        let dev = AudioOutputDevice(id: 1, uid: "uid-1", name: "Speakers", symbol: "laptopcomputer", isDefault: true)
        backend.devices = [dev]
        backend.defaultID = 1
        backend.capabilities[1] = AudioCapabilities(volume: 0.25, isMuted: false, isVolumeAvailable: true, isMuteAvailable: true, hint: "")
        backend.volumeWriteResult = false
        backend.muteWriteResult = false

        let center = SystemControlCenter(backend: backend, startListeners: false)
        center.refreshAudioState()
        try await Self.waitForCondition { center.currentOutputDeviceID == 1 && center.volume == 0.25 }

        // Attempt volume write
        center.setVolume(0.9)
        #expect(center.volume == 0.9)

        try await Self.waitForCondition {
            center.outputSwitchError != nil && center.volume == 0.25
        }
        #expect(center.outputSwitchError?.contains("volume") == true)
        // Reconciles actual value from backend
        #expect(center.volume == 0.25)

        center.dismissOutputSwitchError()
        #expect(center.outputSwitchError == nil)

        // Attempt mute write
        center.toggleMute()
        #expect(center.isMuted == true)

        try await Self.waitForCondition {
            backend.writtenMutes.count == 1 && center.outputSwitchError != nil && center.isMuted == false
        }
        #expect(center.outputSwitchError?.contains("mute") == true)
        #expect(center.isMuted == false)
    }

    @MainActor
    @Test func externalDefaultRouteChangesBeforeDebouncePreventStaleWrite() async throws {
        let backend = MockAudioBackend()
        let oldDev = AudioOutputDevice(id: 1, uid: "uid-old", name: "Old Output", symbol: "speaker.wave.2.fill", isDefault: true)
        let newDev = AudioOutputDevice(id: 2, uid: "uid-new", name: "New Output", symbol: "headphones", isDefault: false)
        backend.devices = [oldDev, newDev]
        backend.defaultID = 1
        backend.capabilities[1] = AudioCapabilities(volume: 0.4, isMuted: false, isVolumeAvailable: true, isMuteAvailable: true, hint: "")
        backend.capabilities[2] = AudioCapabilities(volume: 0.8, isMuted: false, isVolumeAvailable: true, isMuteAvailable: true, hint: "")

        let center = SystemControlCenter(backend: backend, startListeners: true)
        center.refreshAudioState()
        try await Self.waitForCondition { center.currentOutputDeviceID == 1 }

        // User starts slider drag on old device
        center.setVolume(0.95)

        // External route change happens on host before debounce elapses
        backend.defaultID = 2
        backend.defaultDeviceListener?()

        // Wait for external route change to reconcile
        try await Self.waitForCondition { center.currentOutputDeviceID == 2 }

        // Old device volume write must not occur on the backend
        #expect(backend.writtenVolumes.isEmpty)
        #expect(center.volume == 0.8)
    }

    @MainActor
    @Test func pauseFreezesProgressAndResumeAdvancesFromThatPosition() {
        var now = Date(timeIntervalSince1970: 1000)
        let player = NowPlayingMonitor(startMonitoring: false, dateProvider: { now })
        player.song = NowPlayingSong(id: "test", title: "Test", artist: "", album: "", artwork: nil,
                                    artworkURL: nil, sourceApp: "Music", isPlaying: true, duration: 120, elapsed: 10)
        now.addTimeInterval(5)
        player.playPause()
        #expect(!player.song.isPlaying)
        #expect(player.song.elapsed == 15)
        now.addTimeInterval(15)
        #expect(player.estimatedElapsed(at: now) == 15)
        player.playPause()
        #expect(player.song.isPlaying)
        #expect(player.estimatedElapsed(at: now) == 15)
        now.addTimeInterval(3)
        #expect(player.estimatedElapsed(at: now) == 18)
    }

}
