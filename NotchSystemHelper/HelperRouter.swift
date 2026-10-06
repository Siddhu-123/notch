import Foundation

typealias HelperArgs = [String: Any]

/// One handler per wave 7 feature group. Each lives in its own file under Handlers/
/// so parallel jobs never edit the same helper file.
protocol HelperHandler {
    static func handle(action: String, args: HelperArgs, reply: @escaping (HelperArgs?) -> Void)
}

/// Wire format: request `{"group": String, "action": String, "args": {...}}`,
/// reply is a JSON object or nil. Unknown groups or actions reply `{"error": "..."}`.
enum HelperRouter {
    static let handlers: [String: HelperHandler.Type] = [
        "media": MediaHelperHandler.self,
        "audio": AudioHelperHandler.self,
        "windows": WindowsHelperHandler.self,
        "pointer": PointerHelperHandler.self,
        "keys": KeysHelperHandler.self,
        "clipboard": ClipboardHelperHandler.self,
        "capture": CaptureHelperHandler.self,
        "productivity": ProductivityHelperHandler.self,
        "maintenance": MaintenanceHelperHandler.self,
    ]

    static func handle(_ request: Data, reply: @escaping (Data?) -> Void) {
        guard let object = try? JSONSerialization.jsonObject(with: request) as? HelperArgs,
              let group = object["group"] as? String,
              let action = object["action"] as? String else {
            reply(encode(["error": "bad request"]))
            return
        }
        guard let handler = handlers[group] else {
            reply(encode(["error": "unknown group \(group)"]))
            return
        }
        handler.handle(action: action, args: object["args"] as? HelperArgs ?? [:]) { reply(encode($0)) }
    }

    static func encode(_ object: HelperArgs?) -> Data? {
        guard let object, JSONSerialization.isValidJSONObject(object) else { return nil }
        return try? JSONSerialization.data(withJSONObject: object)
    }

    static func unknown(_ action: String) -> HelperArgs { ["error": "unknown action \(action)"] }
}

/// A shared background run loop for event taps and other CFRunLoop sources.
/// Started on first use, so a helper with no taps runs no extra thread.
final class HelperRunLoop {
    static let shared = HelperRunLoop()
    private(set) var runLoop: CFRunLoop!
    private let ready = DispatchSemaphore(value: 0)

    private init() {
        let thread = Thread { [unowned self] in
            runLoop = CFRunLoopGetCurrent()
            // A port keeps the loop alive while no tap is installed.
            CFRunLoopAddSource(runLoop, CFMachPortCreateRunLoopSource(nil, CFMachPortCreate(nil, nil, nil, nil), 0), .commonModes)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "notch.helper.runloop"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
    }

    func add(_ source: CFRunLoopSource) { CFRunLoopAddSource(runLoop, source, .commonModes); CFRunLoopWakeUp(runLoop) }
    func remove(_ source: CFRunLoopSource) { CFRunLoopRemoveSource(runLoop, source, .commonModes) }
}
