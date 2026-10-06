import CoreGraphics
import Foundation
import IOKit
import IOKit.graphics

final class NotchSystemHelper: NSObject, NotchSystemHelperProtocol {
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32

    @objc func currentDisplayBrightness(
        _ displayID: UInt32,
        with reply: @escaping (NSNumber?) -> Void
    ) {
        var level: Float = 0
        if let getBrightness = Self.getBrightness, getBrightness(displayID, &level) == 0 {
            reply(NSNumber(value: min(max(level, 0), 1)))
            return
        }

        guard let service = service(for: displayID) else {
            reply(nil)
            return
        }
        defer { IOObjectRelease(service) }
        guard IODisplayGetFloatParameter(
            service,
            0,
            kIODisplayBrightnessKey as CFString,
            &level
        ) == kIOReturnSuccess else {
            reply(nil)
            return
        }
        reply(NSNumber(value: min(max(level, 0), 1)))
    }

    @objc func setDisplayBrightness(
        _ value: Float,
        displayID: UInt32,
        with reply: @escaping (Bool) -> Void
    ) {
        let clamped = min(max(value, 0), 1)
        if let setBrightness = Self.setBrightness, setBrightness(displayID, clamped) == 0 {
            reply(true)
            return
        }

        guard let service = service(for: displayID) else {
            reply(false)
            return
        }
        defer { IOObjectRelease(service) }
        reply(IODisplaySetFloatParameter(
            service,
            0,
            kIODisplayBrightnessKey as CFString,
            clamped
        ) == kIOReturnSuccess)
    }

    @objc func currentNowPlaying(with reply: @escaping (Data?) -> Void) {
        MediaRemoteBridge.shared.currentPayload(with: reply)
    }

    @objc func sendMediaCommand(_ command: Int, with reply: @escaping (Bool) -> Void) {
        MediaRemoteBridge.shared.run(arguments: ["send", String(command)], reply: reply)
    }

    @objc func seekMedia(_ seconds: Double, with reply: @escaping (Bool) -> Void) {
        let microseconds = Int64(max(0, seconds) * 1_000_000)
        MediaRemoteBridge.shared.run(arguments: ["seek", String(microseconds)], reply: reply)
    }

    private func service(for displayID: CGDirectDisplayID) -> io_service_t? {
        let expectedVendor = CGDisplayVendorNumber(displayID)
        let expectedModel = CGDisplayModelNumber(displayID)
        var iterator: io_iterator_t = 0
        guard let matching = IOServiceMatching("IODisplayConnect"),
              IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == kIOReturnSuccess else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        while true {
            let candidate = IOIteratorNext(iterator)
            guard candidate != 0 else { break }
            let info = IODisplayCreateInfoDictionary(candidate, 0).takeRetainedValue() as NSDictionary
            let vendor = (info[kDisplayVendorID] as? NSNumber)?.uint32Value
            let model = (info[kDisplayProductID] as? NSNumber)?.uint32Value
            if vendor == expectedVendor, model == expectedModel { return candidate }
            IOObjectRelease(candidate)
        }
        return nil
    }

    private static let displayServicesHandle: UnsafeMutableRawPointer? = {
        let paths = [
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
            "/System/Library/PrivateFrameworks/DisplayServices.framework/Versions/Current/DisplayServices"
        ]
        for path in paths {
            if let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL) { return handle }
        }
        return nil
    }()

    private static let getBrightness: GetBrightness? = {
        guard let handle = displayServicesHandle,
              let symbol = dlsym(handle, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(symbol, to: GetBrightness.self)
    }()

    private static let setBrightness: SetBrightness? = {
        guard let handle = displayServicesHandle,
              let symbol = dlsym(handle, "DisplayServicesSetBrightness") else { return nil }
        return unsafeBitCast(symbol, to: SetBrightness.self)
    }()
}

private final class MediaRemoteBridge {
    static let shared = MediaRemoteBridge()

    private struct Paths {
        let script: URL
        let framework: URL
    }

    private let queue = DispatchQueue(label: "sidco.notch.system-helper.mediaremote", qos: .utility)
    private var process: Process?
    private var outputPipe: Pipe?
    private var buffer = Data()
    private var payload: [String: Any] = [:]
    private var didReceiveFirstStreamEnvelope = false

    private init() {}

    func currentPayload(with reply: @escaping (Data?) -> Void) {
        queue.async { [weak self] in
            guard let self, let paths = self.paths else {
                reply(nil)
                return
            }
            self.ensureStream(paths: paths)
            if self.payload.isEmpty { self.loadCurrentSnapshot(paths: paths) }
            reply(try? JSONSerialization.data(withJSONObject: self.payload, options: [.sortedKeys]))
        }
    }

    func run(arguments: [String], reply: @escaping (Bool) -> Void) {
        queue.async { [weak self] in
            guard let self, let paths = self.paths else {
                reply(false)
                return
            }
            let command = Process()
            command.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            command.arguments = [paths.script.path, paths.framework.path] + arguments
            command.standardOutput = FileHandle.nullDevice
            command.standardError = FileHandle.nullDevice
            do {
                try command.run()
                command.waitUntilExit()
                reply(command.terminationStatus == 0)
            } catch {
                reply(false)
            }
        }
    }

    private var paths: Paths? {
        let contents = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = contents.appendingPathComponent("Resources/mediaremote-adapter.pl")
        let framework = contents.appendingPathComponent("Frameworks/MediaRemoteAdapter.framework", isDirectory: true)
        guard FileManager.default.fileExists(atPath: script.path),
              FileManager.default.fileExists(atPath: framework.path) else { return nil }
        return Paths(script: script, framework: framework)
    }

    private func ensureStream(paths: Paths) {
        guard process == nil else { return }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [paths.script.path, paths.framework.path, "stream", "--debounce=120"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            self?.queue.async {
                self?.process = nil
                self?.outputPipe = nil
                self?.buffer.removeAll(keepingCapacity: false)
                self?.didReceiveFirstStreamEnvelope = false
            }
        }
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { self?.consume(data) }
        }
        do {
            try process.run()
            self.process = process
            outputPipe = pipe
            loadCurrentSnapshot(paths: paths)
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
    }

    private func loadCurrentSnapshot(paths: Paths) {
        let command = Process()
        let pipe = Pipe()
        command.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        command.arguments = [paths.script.path, paths.framework.path, "get", "--now"]
        command.standardOutput = pipe
        command.standardError = FileHandle.nullDevice
        do {
            try command.run()
            let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
            command.waitUntilExit()
            guard command.terminationStatus == 0,
                  let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            payload = decoded
        } catch {}
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let envelope = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  envelope["type"] as? String == "data",
                  let update = envelope["payload"] as? [String: Any] else { continue }

            let isBootstrap = !didReceiveFirstStreamEnvelope
            didReceiveFirstStreamEnvelope = true
            if isBootstrap, update.isEmpty { continue }

            if envelope["diff"] as? Bool == true {
                for (key, value) in update {
                    if value is NSNull { payload.removeValue(forKey: key) }
                    else { payload[key] = value }
                }
            } else {
                payload = update
            }
        }
    }
}
