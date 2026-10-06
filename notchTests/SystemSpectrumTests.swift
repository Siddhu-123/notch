import Combine
import CoreAudio
import Foundation
import Testing
@testable import notch

struct SystemSpectrumTests {
    @Test(arguments: [44_100.0, 48_000.0])
    func decodedFloatAndInt16TonesReachTheCorrectFrequencyBand(sampleRate: Double) throws {
        let tone = (0..<2_048).map { Float(0.6 * sin(2 * Double.pi * 750 * Double($0) / sampleRate)) }
        for encoding in [AudioSpectrumPCMEncoding.float32, .int16] {
            let format = try #require(AudioSpectrumPCMFormat(
                sampleRate: Float(sampleRate), channelCount: 1, encoding: encoding, interleaved: true
            ))
            let data = encoding == .float32 ? floats(tone) : int16s(tone.map { Int16($0 * 32_767) })
            let samples = try #require(AudioSpectrumPCMDecoder.decode([.init(data: data, channelCount: 1)], format: format))
            let levels = AudioSpectrumAnalyzer.analyze(samples: samples, sampleRate: format.sampleRate)
            let peak = try #require(levels.max())
            #expect(levels.firstIndex(of: peak) == 3)
            #expect(peak > -40)
        }
    }

    @Test func decoderRejectsIncompleteFramesAndSanitizesInvalidFloatingSamples() throws {
        let stereo = try #require(AudioSpectrumPCMFormat(sampleRate: 48_000, channelCount: 2, encoding: .float32, interleaved: true))
        let incomplete = floats(Array(repeating: 0.5, count: 81))
        #expect(AudioSpectrumPCMDecoder.decode([.init(data: incomplete, channelCount: 2)], format: stereo) == nil)

        let mono = try #require(AudioSpectrumPCMFormat(sampleRate: 48_000, channelCount: 1, encoding: .float32, interleaved: true))
        let invalid = floats(Array(repeating: [Float.nan, .infinity, -.infinity, .greatestFiniteMagnitude], count: 16).flatMap { $0 })
        let samples = try #require(AudioSpectrumPCMDecoder.decode([.init(data: invalid, channelCount: 1)], format: mono))
        #expect(samples.allSatisfy { $0.isFinite && (-1...1).contains($0) })

        var overflowRate = stream(sampleRate: 48_000, channels: 1, bits: 32, flags: kAudioFormatFlagIsFloat)
        overflowRate.mSampleRate = Double.greatestFiniteMagnitude
        #expect(AudioSpectrumPCMFormat(stream: overflowRate) == nil)
    }

    @Test(arguments: [44_100.0, 48_000.0])
    func readsFloatAndIntegerASBD(sampleRate: Double) {
        let float = stream(sampleRate: sampleRate, channels: 2, bits: 32, flags: kAudioFormatFlagIsFloat)
        let integer = stream(sampleRate: sampleRate, channels: 2, bits: 16, flags: kAudioFormatFlagIsSignedInteger)
        let planar = stream(sampleRate: sampleRate, channels: 2, bits: 32, flags: kAudioFormatFlagIsFloat, interleaved: false)

        #expect(AudioSpectrumPCMFormat(stream: float)?.sampleRate == Float(sampleRate))
        #expect(AudioSpectrumPCMFormat(stream: float)?.encoding == .float32)
        #expect(AudioSpectrumPCMFormat(stream: integer)?.sampleRate == Float(sampleRate))
        #expect(AudioSpectrumPCMFormat(stream: integer)?.encoding == .int16)
        #expect(AudioSpectrumPCMFormat(stream: planar)?.interleaved == false)
    }

    @Test func decodesInterleavedStereoAndDownmixesChannels() throws {
        let format = try #require(AudioSpectrumPCMFormat(sampleRate: 48_000, channelCount: 2, encoding: .float32, interleaved: true))
        let data = floats((0..<40).flatMap { _ in [0.75, -0.25] })
        let samples = try #require(AudioSpectrumPCMDecoder.decode([.init(data: data, channelCount: 2)], format: format))

        #expect(samples.count == 40)
        #expect(samples.allSatisfy { abs($0 - 0.25) < 0.0001 })
    }

    @Test func decodesPlanarInt16StereoAndDownmixesChannels() throws {
        let format = try #require(AudioSpectrumPCMFormat(sampleRate: 44_100, channelCount: 2, encoding: .int16, interleaved: false))
        let left = int16s(Array(repeating: Int16.max, count: 40))
        let right = int16s(Array(repeating: Int16.min, count: 40))
        let samples = try #require(AudioSpectrumPCMDecoder.decode([
            .init(data: left, channelCount: 1), .init(data: right, channelCount: 1)
        ], format: format))

        #expect(samples.count == 40)
        #expect(abs(samples[0]) < 0.0001)
    }

    @Test func decoderCapsFramesAndRejectsMalformedBuffersAndFormats() throws {
        let format = try #require(AudioSpectrumPCMFormat(sampleRate: 48_000, channelCount: 2, encoding: .float32, interleaved: true))
        let oversized = floats(Array(repeating: 0.5, count: 5_000))
        let samples = try #require(AudioSpectrumPCMDecoder.decode([.init(data: oversized, channelCount: 2)], format: format))

        #expect(samples.count == AudioSpectrumPCMDecoder.maximumFrames)
        #expect(AudioSpectrumPCMDecoder.decode([.init(data: Data(repeating: 0, count: 7), channelCount: 2)], format: format) == nil)
        #expect(AudioSpectrumPCMDecoder.decode([.init(data: oversized, channelCount: 1)], format: format) == nil)
        #expect(AudioSpectrumPCMFormat(sampleRate: .infinity, channelCount: 2, encoding: .float32, interleaved: true) == nil)

        let unsupported = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: 0,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0
        )
        #expect(AudioSpectrumPCMFormat(stream: unsupported) == nil)
    }

    @Test func mailboxKeepsOnlyOnePendingLatestValueDuringBursts() throws {
        let mailbox = AudioSpectrumMailbox()
        let generation = mailbox.beginGeneration()
        #expect(mailbox.publish(bands(-55), generation: generation))
        for value in -54...0 {
            #expect(!mailbox.publish(bands(Float(value)), generation: generation))
        }

        let delivery = mailbox.takeDelivery(for: generation)
        #expect(delivery.bands == bands(0))
        #expect(delivery.nextGeneration == nil)
        #expect(mailbox.publish(bands(-10), generation: generation))
    }

    @Test func analysisThrottleAllowsAtMostThirtyUpdatesPerSecond() {
        let mailbox = AudioSpectrumMailbox()
        let generation = mailbox.beginGeneration()
        #expect(mailbox.shouldAnalyze(generation: generation, now: 1_000_000_000))
        #expect(!mailbox.shouldAnalyze(generation: generation, now: 1_020_000_000))
        #expect(mailbox.shouldAnalyze(generation: generation, now: 1_034_000_000))
    }

    @Test func mailboxDiscardsStoppedGenerationAndDeliversRestartedGeneration() throws {
        let mailbox = AudioSpectrumMailbox()
        let oldGeneration = mailbox.beginGeneration()
        #expect(mailbox.publish(bands(-20), generation: oldGeneration))
        mailbox.stop()
        let newGeneration = mailbox.beginGeneration()
        #expect(!mailbox.publish(bands(-5), generation: oldGeneration))
        #expect(mailbox.publish(bands(-12), generation: newGeneration) == false)

        let staleDelivery = mailbox.takeDelivery(for: oldGeneration)
        #expect(staleDelivery.bands == nil)
        #expect(staleDelivery.nextGeneration == newGeneration)
        let currentDelivery = mailbox.takeDelivery(for: newGeneration)
        #expect(currentDelivery.bands == bands(-12))
        #expect(currentDelivery.nextGeneration == nil)
    }

    @MainActor
    @Test func identicalPreferenceWriteDoesNotPublishAnotherSettingsChange() {
        let model = NotchModel.shared
        var emissions = 0
        let observation = model.$showVisualizer.sink { _ in emissions += 1 }
        emissions = 0
        model.updateVisualizer(model.showVisualizer)
        model.updateVisualizer(model.showVisualizer)

        #expect(emissions == 0)
        withExtendedLifetime(observation) {}
    }

    private func stream(sampleRate: Double, channels: UInt32, bits: UInt32, flags: AudioFormatFlags, interleaved: Bool = true) -> AudioStreamBasicDescription {
        let bytesPerSample = bits / 8
        let bytesPerFrame = bytesPerSample * (interleaved ? channels : 1)
        return AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: flags | kAudioFormatFlagIsPacked | (interleaved ? 0 : kAudioFormatFlagIsNonInterleaved),
            mBytesPerPacket: bytesPerFrame, mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame, mChannelsPerFrame: channels,
            mBitsPerChannel: bits, mReserved: 0
        )
    }

    private func bands(_ value: Float) -> [Float] {
        Array(repeating: value, count: AudioSpectrumAnalyzer.bandCount)
    }

    private func floats(_ values: [Float]) -> Data {
        var data = Data()
        for value in values { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
        return data
    }

    private func int16s(_ values: [Int16]) -> Data {
        var data = Data()
        for value in values { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
        return data
    }
}
@Suite @MainActor
struct AudioSpectrumLifecycleTests {
    @Test func disabledVisualizerStaysIdleAcrossPlaybackUpdates() {
        let monitor = SystemAudioSpectrumMonitor()
        monitor.setEnabled(false)
        monitor.setPlaying(true)
        monitor.setPlaying(true)
        #expect(monitor.status == .idle)
        #expect(monitor.bandsDB.allSatisfy { $0 == AudioSpectrumAnalyzer.floorDecibels })
        monitor.setPlaying(false)
        monitor.setEnabled(true)
        #expect(monitor.status == .idle)
    }
}
