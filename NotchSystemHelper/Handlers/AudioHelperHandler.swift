import AppKit
import AudioToolbox
import CoreAudio
import Foundation

/// Owns process taps and the process-object listeners used by the app mixer.
enum AudioHelperHandler: HelperHandler {
    private static let coordinator = AudioTapCoordinator()

    static func handle(action: String, args: HelperArgs, reply: @escaping (HelperArgs?) -> Void) {
        coordinator.handle(action: action, args: args, reply: reply)
    }
}

private struct HelperMixerConfig: Equatable {
    let gain: Double
    let deviceUID: String?

    init(gain: Double, deviceUID: String?) {
        self.gain = gain.isFinite ? min(max(gain, 0), 2) : 1
        self.deviceUID = deviceUID?.isEmpty == false ? deviceUID : nil
    }
}

private final class AudioTapCoordinator {
    private let queue = DispatchQueue(label: "sidco.notch.helper.audio-mixer", qos: .userInitiated)
    private var enabled = false
    private var mixerEnabled = false
    private var routingEnabled = false
    private var configs: [String: HelperMixerConfig] = [:]
    private var sessions: [String: AudioTapSession] = [:]
    private var processListener: AudioObjectPropertyListenerBlock?
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?
    private var deviceListListener: AudioObjectPropertyListenerBlock?
    private var processListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]

    func handle(action: String, args: HelperArgs, reply: @escaping (HelperArgs?) -> Void) {
        queue.async {
            switch action {
            case "enable":
                self.enable(args)
                reply(["ok": true])
            case "disable":
                self.disable()
                reply(["ok": true])
            case "list":
                reply(["ok": true, "apps": self.runningApps()])
            case "setGain":
                guard let bundleID = self.bundleID(args), let value = args["gain"] as? NSNumber else {
                    reply(["error": "bundleID and gain are required"])
                    return
                }
                let old = self.configs[bundleID] ?? HelperMixerConfig(gain: 1, deviceUID: nil)
                self.store(HelperMixerConfig(gain: value.doubleValue, deviceUID: old.deviceUID), for: bundleID)
                self.reconcile(bundleIDs: [bundleID])
                reply(["ok": true])
            case "setDevice":
                guard let bundleID = self.bundleID(args) else {
                    reply(["error": "bundleID is required"])
                    return
                }
                let old = self.configs[bundleID] ?? HelperMixerConfig(gain: 1, deviceUID: nil)
                self.store(HelperMixerConfig(gain: old.gain, deviceUID: args["deviceUID"] as? String), for: bundleID)
                self.reconcile(bundleIDs: [bundleID])
                reply(["ok": true])
            case "reset":
                if let bundleID = self.bundleID(args) {
                    self.configs.removeValue(forKey: bundleID)
                    self.sessions.removeValue(forKey: bundleID)?.stop()
                }
                reply(["ok": true])
            case "ping":
                reply(["ok": true])
            default:
                reply(HelperRouter.unknown(action))
            }
        }
    }

    private func bundleID(_ args: HelperArgs) -> String? {
        guard let value = args["bundleID"] as? String else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !result.isEmpty && result.count <= 255 ? result : nil
    }

    private func enable(_ args: HelperArgs) {
        let wantsMixer = args["mixerEnabled"] as? Bool ?? true
        let wantsRouting = args["routingEnabled"] as? Bool ?? true
        guard wantsMixer || wantsRouting else {
            disable()
            return
        }
        enabled = true
        mixerEnabled = wantsMixer
        routingEnabled = wantsRouting
        var restored: [String: HelperMixerConfig] = [:]
        for row in (args["configs"] as? [[String: Any]] ?? []).prefix(64) {
            guard let bundleID = bundleID(row), let gain = row["gain"] as? NSNumber else { continue }
            restored[bundleID] = HelperMixerConfig(gain: gain.doubleValue, deviceUID: row["deviceUID"] as? String)
        }
        for (bundleID, session) in sessions where restored[bundleID] == nil {
            session.stop()
        }
        sessions = sessions.filter { restored[$0.key] != nil }
        configs = restored
        installListenersIfNeeded()
        rebuildProcessListeners()
        reconcile()
    }

    private func disable() {
        enabled = false
        mixerEnabled = false
        routingEnabled = false
        removeListeners()
        for session in sessions.values { session.stop() }
        sessions.removeAll(keepingCapacity: false)
        configs.removeAll(keepingCapacity: false)
    }

    private func store(_ config: HelperMixerConfig, for bundleID: String) {
        if config.gain == 1 && config.deviceUID == nil {
            configs.removeValue(forKey: bundleID)
        } else {
            configs[bundleID] = config
        }
        guard configs.count > 64 else { return }
        for key in configs.keys.sorted().dropLast(64) {
            configs.removeValue(forKey: key)
        }
    }

    private func installListenersIfNeeded() {
        guard processListener == nil else { return }
        var processAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let processBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.queue.async { self.rebuildProcessListeners(); self.reconcile() }
        }
        if AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &processAddress, queue, processBlock
        ) == noErr {
            processListener = processBlock
        }

        var outputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let outputBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.queue.async { self.reconcile() }
        }
        if AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &outputAddress, queue, outputBlock
        ) == noErr {
            defaultDeviceListener = outputBlock
        }

        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let devicesBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.queue.async { self.reconcile() }
        }
        if AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &devicesAddress, queue, devicesBlock
        ) == noErr {
            deviceListListener = devicesBlock
        }
    }

    private func removeListeners() {
        if let listener = processListener {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyProcessObjectList,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
            processListener = nil
        }
        if let listener = defaultDeviceListener {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
            defaultDeviceListener = nil
        }
        if let listener = deviceListListener {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
            deviceListListener = nil
        }
        for (processID, listener) in processListeners {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningOutput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(processID, &address, queue, listener)
        }
        processListeners.removeAll(keepingCapacity: false)
    }

    private func rebuildProcessListeners() {
        guard enabled else { return }
        let processIDs = Set(allProcessIDs())
        for (processID, listener) in processListeners where !processIDs.contains(processID) {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningOutput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(processID, &address, queue, listener)
            processListeners.removeValue(forKey: processID)
        }
        for processID in processIDs where processListeners[processID] == nil {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningOutput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self else { return }
                self.queue.async { self.reconcile() }
            }
            if AudioObjectAddPropertyListenerBlock(processID, &address, queue, listener) == noErr {
                processListeners[processID] = listener
            }
        }
    }

    private func allProcessIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteCount: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &byteCount) == noErr,
              byteCount > 0 else { return [] }
        let count = Int(byteCount) / MemoryLayout<AudioObjectID>.size
        guard count <= 2_048 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &byteCount, &ids) == noErr else { return [] }
        return ids
    }

    private func runningApps() -> [[String: Any]] {
        var grouped: [String: (name: String, ids: [UInt32])] = [:]
        for objectID in allProcessIDs() where isProducingOutput(objectID) {
            guard let bundleID = processBundleID(objectID), let pid = processPID(objectID), pid > 0 else { continue }
            let app = NSRunningApplication(processIdentifier: pid)
            let name = app?.localizedName ?? bundleID
            var row = grouped[bundleID] ?? (name, [])
            row.ids.append(UInt32(objectID))
            grouped[bundleID] = row
        }
        return grouped.keys.sorted { left, right in
            grouped[left]!.name.localizedCaseInsensitiveCompare(grouped[right]!.name) == .orderedAscending
        }.prefix(100).compactMap { bundleID in
            guard let row = grouped[bundleID] else { return nil }
            return ["bundleID": bundleID, "name": row.name, "processIDs": Array(Set(row.ids)).sorted()] as [String: Any]
        }
    }

    private func processBundleID(_ processID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(processID, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private func processPID(_ processID: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(processID, &address, 0, nil, &size, &pid) == noErr else { return nil }
        return pid
    }

    private func isProducingOutput(_ processID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(processID, &address, 0, nil, &size, &value) == noErr && value != 0
    }

    private func outputProcessesByBundle() -> [String: [AudioObjectID]] {
        var grouped: [String: [AudioObjectID]] = [:]
        for processID in allProcessIDs() where isProducingOutput(processID) {
            guard let bundleID = processBundleID(processID) else { continue }
            grouped[bundleID, default: []].append(processID)
        }
        return grouped
    }

    private func reconcile(bundleIDs: Set<String>? = nil) {
        guard enabled else { return }
        let running = outputProcessesByBundle()
        let candidates = bundleIDs ?? Set(configs.keys).union(sessions.keys)
        for bundleID in candidates {
            guard let config = configs[bundleID],
                  let processIDs = running[bundleID], !processIDs.isEmpty,
                  mixerEnabled || routingEnabled else {
                sessions.removeValue(forKey: bundleID)?.stop()
                continue
            }
            let defaultUID = defaultOutputUID()
            let targetUID = config.deviceUID ?? defaultUID
            guard config.gain != 1 || targetUID != defaultUID else {
                sessions.removeValue(forKey: bundleID)?.stop()
                continue
            }
            if let existing = sessions[bundleID],
               existing.processIDs == processIDs.sorted(),
               existing.gain == config.gain,
               existing.outputUID == targetUID {
                continue
            }
            sessions.removeValue(forKey: bundleID)?.stop()
            guard let targetUID,
                  let session = AudioTapSession.create(
                    bundleID: bundleID,
                    processIDs: processIDs.sorted(),
                    outputUID: targetUID,
                    gain: config.gain,
                    queue: queue
                  ) else { continue }
            sessions[bundleID] = session
        }
    }

    private func defaultOutputUID() -> String? {
        guard let id = defaultOutputDeviceID() else { return nil }
        return deviceUID(id)
    }

    private func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    private func deviceUID(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

private final class AudioTapSession {
    let processIDs: [AudioObjectID]
    let gain: Double
    let outputUID: String
    private let tapID: AudioObjectID
    private let aggregateID: AudioDeviceID
    private let ioProcID: AudioDeviceIOProcID

    private init(processIDs: [AudioObjectID], gain: Double, outputUID: String, tapID: AudioObjectID, aggregateID: AudioDeviceID, ioProcID: AudioDeviceIOProcID) {
        self.processIDs = processIDs
        self.gain = gain
        self.outputUID = outputUID
        self.tapID = tapID
        self.aggregateID = aggregateID
        self.ioProcID = ioProcID
    }

    static func create(bundleID: String, processIDs: [AudioObjectID], outputUID: String, gain: Double, queue: DispatchQueue) -> AudioTapSession? {
        guard #available(macOS 14.4, *) else { return nil }
        let tapUUID = UUID()
        let description = CATapDescription(stereoMixdownOfProcesses: processIDs)
        description.name = "Notch app mixer \(bundleID)"
        description.uuid = tapUUID
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped

        var tapID = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr else { return nil }
        var aggregateID = AudioDeviceID(kAudioObjectUnknown)
        let aggregateUID = "sidco.notch.appmixer.\(UUID().uuidString)"
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Notch App Mixer",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUUID.uuidString, kAudioSubTapDriftCompensationKey: true]],
            kAudioAggregateDeviceTapAutoStartKey: true
        ]
        guard AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID) == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }

        var inputFormat = AudioStreamBasicDescription()
        var tapAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var inputSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tapID, &tapAddress, 0, nil, &inputSize, &inputFormat) == noErr else {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }
        var outputFormat = AudioStreamBasicDescription()
        var outputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var outputSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(aggregateID, &outputAddress, 0, nil, &outputSize, &outputFormat) == noErr,
              MixerPCM.isSupported(inputFormat), MixerPCM.isSupported(outputFormat) else {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }

        var ioProcID: AudioDeviceIOProcID?
        let ioQueue = DispatchQueue(label: "sidco.notch.helper.audio-io.\(UUID().uuidString)", qos: .userInteractive)
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, ioQueue) { _, inputData, _, outputData, _ in
            MixerPCM.process(inputData, outputData, inputFormat: inputFormat, outputFormat: outputFormat, gain: gain)
        }
        guard createStatus == noErr, let ioProcID,
              AudioDeviceStart(aggregateID, ioProcID) == noErr else {
            if let ioProcID { AudioDeviceDestroyIOProcID(aggregateID, ioProcID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }
        return AudioTapSession(processIDs: processIDs, gain: gain, outputUID: outputUID, tapID: tapID, aggregateID: aggregateID, ioProcID: ioProcID)
    }

    func stop() {
        AudioDeviceStop(aggregateID, ioProcID)
        AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        AudioHardwareDestroyAggregateDevice(aggregateID)
        AudioHardwareDestroyProcessTap(tapID)
    }
}

private enum MixerPCM {
    static func isSupported(_ format: AudioStreamBasicDescription) -> Bool {
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mChannelsPerFrame > 0,
              format.mBitsPerChannel == 16 || format.mBitsPerChannel == 24 || format.mBitsPerChannel == 32 || format.mBitsPerChannel == 64 else { return false }
        let isFloat = (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        if isFloat { return format.mBitsPerChannel == 32 || format.mBitsPerChannel == 64 }
        if format.mBitsPerChannel == 24 { return format.mFormatFlags & kAudioFormatFlagIsPacked != 0 }
        return format.mBitsPerChannel == 16 || format.mBitsPerChannel == 32
    }

    static func process(_ inputList: UnsafePointer<AudioBufferList>, _ outputList: UnsafeMutablePointer<AudioBufferList>, inputFormat: AudioStreamBasicDescription, outputFormat: AudioStreamBasicDescription, gain: Double) {
        let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputList))
        let output = UnsafeMutableAudioBufferListPointer(outputList)
        guard !output.isEmpty else { return }
        let inputInterleaved = inputFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let outputInterleaved = outputFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let inputBytes = Int(inputFormat.mBitsPerChannel / 8)
        let outputBytes = Int(outputFormat.mBitsPerChannel / 8)
        let inputFrameBytes = inputInterleaved ? Int(inputFormat.mBytesPerFrame) : inputBytes
        let outputFrameBytes = outputInterleaved ? Int(outputFormat.mBytesPerFrame) : outputBytes
        guard inputFrameBytes > 0, outputFrameBytes > 0 else { return }
        for outputBufferIndex in 0..<output.count {
            let destination = output[outputBufferIndex]
            guard let destinationData = destination.mData else { continue }
            let outputChannels = max(1, Int(destination.mNumberChannels))
            let frameCount = Int(destination.mDataByteSize) / outputFrameBytes
            let destinationBytes = destinationData.assumingMemoryBound(to: UInt8.self)
            for frame in 0..<frameCount {
                for channel in 0..<outputChannels {
                    let globalChannel = outputInterleaved ? channel : outputBufferIndex
                    let sourceBufferIndex = inputInterleaved ? 0 : min(globalChannel, max(0, input.count - 1))
                    let sourceChannel = inputInterleaved ? globalChannel % Int(inputFormat.mChannelsPerFrame) : 0
                    var sample = 0.0
                    if sourceBufferIndex < input.count {
                        let source = input[sourceBufferIndex]
                        if let sourceData = source.mData,
                           frame * inputFrameBytes + (inputInterleaved ? (sourceChannel * inputBytes) : 0) + inputBytes <= Int(source.mDataByteSize) {
                            sample = read(sourceData.assumingMemoryBound(to: UInt8.self), offset: frame * inputFrameBytes + (inputInterleaved ? sourceChannel * inputBytes : 0), format: inputFormat)
                        }
                    }
                    let value = softClip(sample * gain)
                    let offset = frame * outputFrameBytes + (outputInterleaved ? channel * outputBytes : 0)
                    write(value, to: destinationBytes, offset: offset, format: outputFormat)
                }
            }
        }
    }

    private static func softClip(_ sample: Double) -> Double {
        guard sample.isFinite else { return 0 }
        let magnitude = abs(sample)
        let sign = sample < 0 ? -1.0 : 1.0
        let knee = 0.98
        return magnitude <= knee ? sample : sign * (knee + 0.02 * (magnitude - knee) / (0.02 + magnitude - knee))
    }

    private static func read(_ bytes: UnsafePointer<UInt8>, offset: Int, format: AudioStreamBasicDescription) -> Double {
        let bigEndian = format.mFormatFlags & kAudioFormatFlagIsBigEndian != 0
        if format.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            if format.mBitsPerChannel == 32 {
                var value: UInt32 = 0
                withUnsafeMutableBytes(of: &value) { $0.copyBytes(from: UnsafeBufferPointer(start: bytes.advanced(by: offset), count: 4)) }
                if bigEndian { value = value.byteSwapped }
                return Double(Float(bitPattern: value))
            }
            var value: UInt64 = 0
            withUnsafeMutableBytes(of: &value) { $0.copyBytes(from: UnsafeBufferPointer(start: bytes.advanced(by: offset), count: 8)) }
            if bigEndian { value = value.byteSwapped }
            return Double(Double(bitPattern: value))
        }
        switch format.mBitsPerChannel {
        case 16:
            var raw = UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
            if bigEndian { raw = raw.byteSwapped }
            return Double(Int16(bitPattern: raw)) / 32768
        case 24:
            let raw: UInt32 = bigEndian
                ? UInt32(bytes[offset]) << 16 | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2])
                : UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16
            let signed = (raw & 0x00800000) == 0 ? Int32(raw) : Int32(raw | 0xFF000000)
            return Double(signed) / 8_388_608
        default:
            var raw = UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
            if bigEndian { raw = raw.byteSwapped }
            return Double(Int32(bitPattern: raw)) / 2_147_483_648
        }
    }

    private static func write(_ sample: Double, to bytes: UnsafeMutablePointer<UInt8>, offset: Int, format: AudioStreamBasicDescription) {
        let bigEndian = format.mFormatFlags & kAudioFormatFlagIsBigEndian != 0
        if format.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            if format.mBitsPerChannel == 32 {
                var raw = Float(sample).bitPattern
                if bigEndian { raw = raw.byteSwapped }
                withUnsafeBytes(of: &raw) { bytes.advanced(by: offset).update(from: $0.baseAddress!.assumingMemoryBound(to: UInt8.self), count: 4) }
            } else {
                var raw = sample.bitPattern
                if bigEndian { raw = raw.byteSwapped }
                withUnsafeBytes(of: &raw) { bytes.advanced(by: offset).update(from: $0.baseAddress!.assumingMemoryBound(to: UInt8.self), count: 8) }
            }
            return
        }
        let value = min(max(sample, -1), 1)
        switch format.mBitsPerChannel {
        case 16:
            var raw = UInt16(bitPattern: Int16((value * 32767).rounded()))
            if bigEndian { raw = raw.byteSwapped }
            bytes[offset] = UInt8(raw & 0xFF)
            bytes[offset + 1] = UInt8(raw >> 8)
        case 24:
            let signed = Int32((value * 8_388_607).rounded())
            let raw = UInt32(bitPattern: signed)
            if bigEndian {
                bytes[offset] = UInt8(raw >> 16); bytes[offset + 1] = UInt8(raw >> 8); bytes[offset + 2] = UInt8(raw)
            } else {
                bytes[offset] = UInt8(raw); bytes[offset + 1] = UInt8(raw >> 8); bytes[offset + 2] = UInt8(raw >> 16)
            }
        default:
            var raw = UInt32(bitPattern: Int32((value * 2_147_483_647).rounded()))
            if bigEndian { raw = raw.byteSwapped }
            bytes[offset] = UInt8(raw & 0xFF); bytes[offset + 1] = UInt8((raw >> 8) & 0xFF)
            bytes[offset + 2] = UInt8((raw >> 16) & 0xFF); bytes[offset + 3] = UInt8(raw >> 24)
        }
    }
}
