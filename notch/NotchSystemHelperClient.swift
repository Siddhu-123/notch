import CoreGraphics
import Foundation

private final class OnceCompletion<Value> {
    private let lock = NSLock()
    private var completion: ((Value) -> Void)?
    private var timeout: DispatchWorkItem?

    init(_ completion: @escaping (Value) -> Void) {
        self.completion = completion
    }

    func call(_ value: Value) {
        lock.lock()
        let callback = completion
        completion = nil
        timeout?.cancel()
        timeout = nil
        lock.unlock()
        callback?(value)
    }

    func scheduleTimeout(after delay: TimeInterval, _ action: @escaping () -> Void) {
        let work = DispatchWorkItem(block: action)
        lock.lock()
        timeout = work
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: work)
    }
}

@objc protocol NotchSystemHelperProtocol {
    func currentDisplayBrightness(_ displayID: UInt32, with reply: @escaping (NSNumber?) -> Void)
    func setDisplayBrightness(_ value: Float, displayID: UInt32, with reply: @escaping (Bool) -> Void)
    func currentNowPlaying(with reply: @escaping (Data?) -> Void)
    func sendMediaCommand(_ command: Int, with reply: @escaping (Bool) -> Void)
    func seekMedia(_ seconds: Double, with reply: @escaping (Bool) -> Void)
}

/// Keeps private display access outside the sandboxed UI process.
final class NotchSystemHelperClient {
    static let shared = NotchSystemHelperClient()

    private let serviceName = "sidco.notch.SystemHelper"
    private let lock = NSLock()
    private var connection: NSXPCConnection?

    private init() {}

    func currentBrightness(
        displayID: CGDirectDisplayID,
        completion: @escaping (Double?) -> Void
    ) {
        let finish = boundedCompletion(timeoutValue: Optional<Double>.none, completion: completion)
        guard let proxy = proxy(onError: { [weak self] _ in
            guard let self else { finish(nil); return }
            self.readDirectly(displayID: displayID, completion: finish)
        }) else {
            readDirectly(displayID: displayID, completion: finish)
            return
        }
        proxy.currentDisplayBrightness(displayID) { value in
            finish(value?.doubleValue)
        }
    }

    func setBrightness(
        _ value: Double,
        displayID: CGDirectDisplayID,
        completion: @escaping (Bool) -> Void
    ) {
        let clamped = Float(min(max(value, 0), 1))
        let finish = boundedCompletion(timeoutValue: false, completion: completion)
        guard let proxy = proxy(onError: { [weak self] _ in
            guard let self else { finish(false); return }
            self.writeDirectly(clamped, displayID: displayID, completion: finish)
        }) else {
            writeDirectly(clamped, displayID: displayID, completion: finish)
            return
        }
        proxy.setDisplayBrightness(clamped, displayID: displayID, with: finish)
    }

    func currentNowPlaying(completion: @escaping (Data?) -> Void) {
        let finish = boundedCompletion(timeoutValue: Optional<Data>.none, completion: completion)
        guard let proxy = proxy(onError: { _ in finish(nil) }) else {
            finish(nil)
            return
        }
        proxy.currentNowPlaying(with: finish)
    }

    func sendMediaCommand(_ command: Int) {
        guard let proxy = proxy(onError: { _ in }) else { return }
        proxy.sendMediaCommand(command) { _ in }
    }

    func seekMedia(to seconds: Double) {
        guard let proxy = proxy(onError: { _ in }) else { return }
        proxy.seekMedia(seconds) { _ in }
    }

    private func proxy(
        onError: @escaping (Error) -> Void
    ) -> NotchSystemHelperProtocol? {
        let connection = activeConnection()
        return connection.remoteObjectProxyWithErrorHandler { [weak self] error in
            self?.invalidateConnection(connection)
            onError(error)
        } as? NotchSystemHelperProtocol
    }

    private func activeConnection() -> NSXPCConnection {
        lock.lock()
        defer { lock.unlock() }
        if let connection { return connection }

        let newConnection = NSXPCConnection(serviceName: serviceName)
        newConnection.remoteObjectInterface = NSXPCInterface(with: NotchSystemHelperProtocol.self)
        newConnection.interruptionHandler = { [weak self, weak newConnection] in
            guard let newConnection else { return }
            self?.invalidateConnection(newConnection)
        }
        newConnection.invalidationHandler = { [weak self, weak newConnection] in
            guard let newConnection else { return }
            self?.invalidateConnection(newConnection)
        }
        newConnection.resume()
        connection = newConnection
        return newConnection
    }

    private func invalidateConnection(_ candidate: NSXPCConnection) {
        lock.lock()
        if connection === candidate { connection = nil }
        lock.unlock()
    }

    private func readDirectly(
        displayID: CGDirectDisplayID,
        completion: @escaping (Double?) -> Void
    ) {
        DispatchQueue.global(qos: .utility).async {
            completion(DisplayBrightnessController.read(displayID: displayID))
        }
    }

    private func writeDirectly(
        _ value: Float,
        displayID: CGDirectDisplayID,
        completion: @escaping (Bool) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            completion(DisplayBrightnessController.write(Double(value), displayID: displayID))
        }
    }

    private func boundedCompletion<Value>(
        timeoutValue: Value,
        completion: @escaping (Value) -> Void
    ) -> (Value) -> Void {
        let once = OnceCompletion(completion)
        once.scheduleTimeout(after: 2) {
            once.call(timeoutValue)
        }
        return { once.call($0) }
    }
}
