import Foundation
import CoreAudio
import Testing
@testable import notch

struct SoundMixerTests {
    @Test func gainMappingClampsBothEndsAndHandlesNonFiniteValues() {
        #expect(MixerGain.fromPercent(0) == 0)
        #expect(MixerGain.fromPercent(100) == 1)
        #expect(MixerGain.fromPercent(200) == 2)
        #expect(MixerGain.fromPercent(-1) == 0)
        #expect(MixerGain.fromPercent(201) == 2)
        #expect(MixerGain.fromPercent(.nan) == 1)
        #expect(MixerGain.percent(fromGain: -1) == 0)
        #expect(MixerGain.percent(fromGain: 0.995) == 100)
        #expect(MixerGain.percent(fromGain: 2) == 200)
        #expect(MixerGain.percent(fromGain: .infinity) == 100)
    }

    @Test func softClipPreservesQuietSamplesAndCompressesBoostedPeaksSymmetrically() {
        #expect(MixerGain.softClip(0) == 0)
        #expect(MixerGain.softClip(0.5) == 0.5)
        #expect(MixerGain.softClip(-0.5) == -0.5)
        #expect(MixerGain.softClip(0.98) == 0.98)
        #expect(MixerGain.softClip(1) > 0.98)
        #expect(MixerGain.softClip(1) < 1)
        #expect(MixerGain.softClip(4) < 1)
        #expect(MixerGain.softClip(-4) == -MixerGain.softClip(4))
        #expect(MixerGain.softClip(.nan) == 0)
        #expect(MixerGain.process(0.75, gain: 2) < 1)
        #expect(MixerGain.process(0.75, gain: 2) > MixerGain.process(0.75, gain: 1))
    }

    @Test func headphoneGuardOnlyLowersAfterHeadphonesSwitchToBuiltInSpeakers() {
        #expect(HeadphoneGuard.targetVolume(previousTransport: .bluetooth, newTransport: .builtInSpeakers, current: 0.8, limit: 0.25) == 0.25)
        #expect(HeadphoneGuard.targetVolume(previousTransport: .bluetoothLE, newTransport: .builtInSpeakers, current: 0.8, limit: 0.25) == 0.25)
        #expect(HeadphoneGuard.targetVolume(previousTransport: .headphones, newTransport: .builtInSpeakers, current: 0.8, limit: 0.25) == 0.25)
        #expect(HeadphoneGuard.targetVolume(previousTransport: .other, newTransport: .builtInSpeakers, current: 0.8, limit: 0.25) == nil)
        #expect(HeadphoneGuard.targetVolume(previousTransport: .bluetooth, newTransport: .other, current: 0.8, limit: 0.25) == nil)
        #expect(HeadphoneGuard.targetVolume(previousTransport: .builtInSpeakers, newTransport: .builtInSpeakers, current: 0.8, limit: 0.25) == nil)
    }

    @Test func headphoneGuardDoesNotRaiseVolumeAndHonorsTheExactLimitBoundary() {
        #expect(HeadphoneGuard.targetVolume(previousTransport: .headphones, newTransport: .builtInSpeakers, current: 0.249, limit: 0.25) == nil)
        #expect(HeadphoneGuard.targetVolume(previousTransport: .headphones, newTransport: .builtInSpeakers, current: 0.25, limit: 0.25) == nil)
        #expect(HeadphoneGuard.targetVolume(previousTransport: .headphones, newTransport: .builtInSpeakers, current: 0.251, limit: 0.25) == 0.25)
        #expect(HeadphoneGuard.targetVolume(previousTransport: .headphones, newTransport: .builtInSpeakers, current: .nan, limit: 0.25) == nil)
        #expect(HeadphoneGuard.targetVolume(previousTransport: .headphones, newTransport: .builtInSpeakers, current: 0.8, limit: .infinity) == nil)
        #expect(HeadphoneGuard.targetVolume(previousTransport: .headphones, newTransport: .builtInSpeakers, current: 0.8, limit: 1.5) == nil)
        #expect(HeadphoneGuard.targetVolume(previousTransport: .headphones, newTransport: .builtInSpeakers, current: 0.8, limit: -1) == 0)
    }

    @Test func headphoneClassificationRecognizesBluetoothAndHeadphoneDataSources() {
        #expect(HeadphoneGuard.outputKind(transport: kAudioDeviceTransportTypeBluetooth, dataSourceName: nil) == .bluetooth)
        #expect(HeadphoneGuard.outputKind(transport: kAudioDeviceTransportTypeBluetoothLE, dataSourceName: nil) == .bluetoothLE)
        #expect(HeadphoneGuard.outputKind(transport: kAudioDeviceTransportTypeBuiltIn, dataSourceName: "Headphones") == .headphones)
        #expect(HeadphoneGuard.outputKind(transport: kAudioDeviceTransportTypeBuiltIn, dataSourceName: "Internal Speakers") == .builtInSpeakers)
        #expect(HeadphoneGuard.outputKind(transport: kAudioDeviceTransportTypeVirtual, dataSourceName: "Headphones") == .headphones)
        #expect(HeadphoneGuard.outputKind(transport: kAudioDeviceTransportTypeUnknown, dataSourceName: nil) == .other)
    }

    @Test func savedPreferencesRejectCorruptRowsAndStayWithinTheCacheLimit() throws {
        var rows: [String: SoundMixerPreference] = [:]
        for index in 0..<(SoundMixerPreferences.maximumSavedApps + 4) {
            rows["com.example.app\(index)"] = SoundMixerPreference(gain: Double(index % 200) / 100, updatedAt: Date(timeIntervalSince1970: TimeInterval(index)))
        }
        let encoded = try JSONEncoder().encode(rows)
        let decoded = SoundMixerPreferences.decode(encoded)
        #expect(decoded.count == SoundMixerPreferences.maximumSavedApps)
        #expect(decoded["com.example.app67"] != nil)
        #expect(decoded["com.example.app0"] == nil)
        #expect(SoundMixerPreferences.decode(Data("broken".utf8)).isEmpty)
        #expect(SoundMixerPreferences.decode(nil).isEmpty)
    }

    @Test func appListParserDropsMalformedAndDuplicateRowsAndBoundsResults() {
        let reply: [String: Any] = ["apps": [
            ["bundleID": "com.example.music", "name": "Music", "processIDs": [42, 42, -1]],
            ["bundleID": "com.example.music", "name": "Duplicate", "processIDs": [43]],
            ["bundleID": "  ", "name": "Empty", "processIDs": [44]],
            ["bundleID": "com.example.browser", "name": "Browser", "processIDs": ["bad"]],
            ["bundleID": "com.example.player", "name": "Player", "processIDs": [NSNumber(value: UInt32.max)]],
            ["name": "Missing ID", "processIDs": [45]]
        ]]
        let parsed = RunningAudioApp.parse(reply)
        #expect(parsed.map(\.bundleID) == ["com.example.music", "com.example.player"])
        #expect(parsed[0].processIDs == [42])
        #expect(parsed[1].processIDs == [UInt32.max])
        #expect(RunningAudioApp.parse(nil).isEmpty)
        #expect(RunningAudioApp.parse(["apps": "not an array"]).isEmpty)
        #expect(RunningAudioApp.parse(reply, maximum: 0).isEmpty)
    }
}
