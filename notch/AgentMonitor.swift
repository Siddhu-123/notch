import AppKit
import Combine
import Darwin
import Foundation
import SwiftUI

enum AgentPlatform: String, CaseIterable, Identifiable {
    case claude, codex, antigravity, opencode, hub

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .antigravity: return "Antigravity"
        case .opencode: return "OpenCode"
        case .hub: return "Agent Hub"
        }
    }

    var symbol: String {
        switch self {
        case .claude: return "sparkle"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .antigravity: return "atom"
        case .opencode: return "terminal"
        case .hub: return "point.3.connected.trianglepath.dotted"
        }
    }

    var tint: Color {
        switch self {
        case .claude: return Color(red: 0.87, green: 0.56, blue: 0.44)
        case .codex: return Color(red: 0.5, green: 0.68, blue: 0.96)
        case .antigravity: return Color(red: 0.66, green: 0.6, blue: 0.96)
        case .opencode: return Color(red: 0.45, green: 0.79, blue: 0.66)
        case .hub: return Color(red: 0.93, green: 0.78, blue: 0.47)
        }
    }

    var defaultBundleID: String? {
        switch self {
        case .claude: return "com.anthropic.claudefordesktop"
        case .codex: return "com.openai.codex"
        case .antigravity: return "com.google.antigravity"
        case .opencode: return "com.apple.Terminal"
        case .hub: return nil
        }
    }
}

enum AgentStatus: String {
    case working, waiting, idle, done, error

    var label: String {
        switch self {
        case .working: return "Working"
        case .waiting: return "Needs you"
        case .idle: return "Idle"
        case .done: return "Done"
        case .error: return "Error"
        }
    }
}

enum AgentRequestKind: String { case permission, question, attention }
enum AgentDecision: String { case allow, always, deny, app }

struct AgentSession: Identifiable, Equatable {
    let id: String
    var platform: AgentPlatform
    var platformName: String
    var sessionId: String
    var title: String
    var status: AgentStatus
    var activity: String
    var app: String?
    var pid: Int32?
    var steps: Int
    var startedAt: Date
    var turnStartedAt: Date?
    var updatedAt: Date
    var finishedAt: Date?
    var project: String
    var cwd: String
    var model: String
    var lastPrompt: String
}

struct AgentRequest: Identifiable, Equatable {
    let id: String
    var platform: AgentPlatform
    var platformName: String
    var sessionId: String
    var kind: AgentRequestKind
    var title: String
    var detail: String
    var tool: String
    var canAnswer: Bool
    var options: [String]
    var holdUntil: Date?
    var createdAt: Date
    var app: String?
    var project: String
    var choices: [String] = []
    var header: String = ""

    var supportsAlways: Bool { options.contains("always") }
}

struct HubJob: Identifiable, Equatable {
    let id: String
    var worker: String
    var model: String
    var role: String
    var objective: String
    var project: String
    var started: Date
    /// Raw hub state when the heartbeat provides one; nil means unknown.
    var state: String? = nil

    var statusLabel: String {
        switch state?.lowercased() {
        case "running": return "Running"
        case "queued": return "Queued"
        case let value?: return value.capitalized
        case nil: return "Hub job"
        }
    }
}

final class AgentMonitor: ObservableObject {
    static let shared = AgentMonitor()

    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var requests: [AgentRequest] = []
    @Published private(set) var hubJobs: [HubJob] = []
    @Published private(set) var platformLastSeen: [AgentPlatform: Date] = [:]
    @Published private(set) var hubAlive = false
    @Published private(set) var hooksInstalled = false
    @Published var bubblesEnabled: Bool {
        didSet { UserDefaults.standard.set(bubblesEnabled, forKey: "notch.agents.bubbles") }
    }
    @Published var edgePeekEnabled: Bool {
        didSet { UserDefaults.standard.set(edgePeekEnabled, forKey: "notch.agents.edgePeek") }
    }
    @Published var edgeDwell: Double {
        didSet {
            edgeDwell = min(max(edgeDwell, 0.15), 1.5)
            UserDefaults.standard.set(edgeDwell, forKey: "notch.agents.edgeDwell")
        }
    }
    @Published var answerFromNotch: Bool {
        didSet {
            UserDefaults.standard.set(answerFromNotch, forKey: "notch.agents.answer")
            writeHeartbeat()
        }
    }
    @Published var holdSeconds: Double {
        didSet {
            holdSeconds = min(max(holdSeconds, 5), 540)
            UserDefaults.standard.set(holdSeconds, forKey: "notch.agents.holdSeconds")
            writeHeartbeat()
        }
    }

    var activeCount: Int {
        sessions.filter { $0.status == .working || $0.status == .waiting }.count + hubJobs.count
    }

    private let ioQueue = DispatchQueue(label: "com.notch.agents.io")
    private var reloadTimer: Timer?
    private var heartbeatTimer: Timer?
    private var isStarted = false
    /// Requests answered or dismissed here: hidden until the bridge removes their file, so a reload
    /// can't flash them back (a dismissed held request is rewritten as passive by the bridge).
    private var hiddenRequestIDs = Set<String>()  // main thread only
    private let rootURL: URL
    private let sessionsURL: URL
    private let requestsURL: URL
    private let responsesURL: URL
    private let platformsURL: URL
    private let hubHeartbeatURL: URL

    private init() {
        let home: String
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            home = String(cString: directory)
        } else {
            home = NSHomeDirectory()
        }
        let homeURL = URL(fileURLWithPath: home, isDirectory: true)
        rootURL = homeURL.appendingPathComponent("Library/Application Support/AgentHub/live", isDirectory: true)
        sessionsURL = rootURL.appendingPathComponent("sessions", isDirectory: true)
        requestsURL = rootURL.appendingPathComponent("requests", isDirectory: true)
        responsesURL = rootURL.appendingPathComponent("responses", isDirectory: true)
        platformsURL = rootURL.appendingPathComponent("platforms", isDirectory: true)
        hubHeartbeatURL = rootURL.appendingPathComponent("hub.json")

        let defaults = UserDefaults.standard
        bubblesEnabled = defaults.object(forKey: "notch.agents.bubbles") as? Bool ?? true
        edgePeekEnabled = defaults.object(forKey: "notch.agents.edgePeek") as? Bool ?? true
        edgeDwell = min(max(defaults.object(forKey: "notch.agents.edgeDwell") as? Double ?? 0.4, 0.15), 1.5)
        answerFromNotch = defaults.object(forKey: "notch.agents.answer") as? Bool ?? true
        holdSeconds = min(max(defaults.object(forKey: "notch.agents.holdSeconds") as? Double ?? 45, 5), 540)
        NotificationCenter.default.addObserver(self, selector: #selector(applicationWillTerminate), name: NSApplication.willTerminateNotification, object: nil)
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.createDirectories()
            self.reloadOnQueue()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isStarted else { return }
                self.writeHeartbeat()
                self.reloadTimer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.reload() }
                self.heartbeatTimer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.writeHeartbeat() }
                if let timer = self.reloadTimer { RunLoop.main.add(timer, forMode: .common) }
                if let timer = self.heartbeatTimer { RunLoop.main.add(timer, forMode: .common) }
            }
        }
    }

    func stop() {
        isStarted = false
        reloadTimer?.invalidate()
        heartbeatTimer?.invalidate()
        reloadTimer = nil
        heartbeatTimer = nil
        // Synchronous: this runs from willTerminate, and blocked hooks should release right away.
        let hold = (answerFromNotch, holdSeconds)
        ioQueue.sync { writeHeartbeatOnQueue(hold: hold, aliveAt: 0) }
    }

    func reload() {
        ioQueue.async { [weak self] in self?.reloadOnQueue() }
    }

    func respond(to request: AgentRequest, decision: AgentDecision) {
        // Nobody is waiting on a passive request: the only useful answer is to go to the app.
        guard request.canAnswer else {
            openApp(for: request)
            return
        }
        if decision == .app {
            // Releases the hold so the app shows its own prompt; the bubble stays (now passive).
            ioQueue.async { [weak self] in
                guard let self else { return }
                self.writeJSON(["decision": decision.rawValue], to: self.responsesURL.appendingPathComponent(request.id + ".json"))
            }
            openApp(for: request)
            return
        }
        hide(request.id)
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.writeJSON(["decision": decision.rawValue], to: self.responsesURL.appendingPathComponent(request.id + ".json"))
        }
    }

    func dismiss(_ request: AgentRequest) {
        hide(request.id)
        ioQueue.async { [weak self] in
            guard let self else { return }
            if request.canAnswer {
                self.writeJSON(["decision": AgentDecision.app.rawValue], to: self.responsesURL.appendingPathComponent(request.id + ".json"))
            } else {
                try? FileManager.default.removeItem(at: self.requestsURL.appendingPathComponent(request.id + ".json"))
            }
        }
    }

    func openApp(for request: AgentRequest) {
        openApp(bundleID: request.app, platform: request.platform)
    }

    func openApp(for session: AgentSession) {
        openApp(bundleID: session.app, platform: session.platform)
    }

    func openHubDashboard() {
        let bundleID = "dev.agenthub.AgentHub"
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            app.activate(options: [.activateAllWindows])
        } else {
            NSWorkspace.shared.launchApplication(
                withBundleIdentifier: bundleID,
                options: [.default],
                additionalEventParamDescriptor: nil,
                launchIdentifier: nil
            )
        }
    }

    func clearFinished() {
        let finished = sessions.filter { $0.status == .done || $0.status == .error }.map(\.id)
        ioQueue.async { [weak self] in
            guard let self else { return }
            for id in finished {
                try? FileManager.default.removeItem(at: self.sessionsURL.appendingPathComponent(id + ".json"))
            }
            self.reloadOnQueue()
        }
    }

    func session(for request: AgentRequest) -> AgentSession? {
        sessions.first { $0.platform == request.platform && $0.sessionId == request.sessionId }
    }

    @objc private func applicationWillTerminate() { stop() }

    private func createDirectories() {
        let manager = FileManager.default
        for directory in [rootURL, sessionsURL, requestsURL, responsesURL, platformsURL] {
            try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
            chmod(directory.path, 0o700)
        }
    }

    private func reloadOnQueue() {
        let now = Date()
        var loadedRequests = readRequests(now: now)
        var loadedSessions = readSessions(now: now, requests: loadedRequests)
        loadedRequests.removeAll { request in
            !FileManager.default.fileExists(atPath: requestsURL.appendingPathComponent(request.id + ".json").path)
        }
        loadedSessions.removeAll { session in
            !FileManager.default.fileExists(atPath: sessionsURL.appendingPathComponent(session.id + ".json").path)
        }
        let hub = readObject(hubHeartbeatURL)
        let aliveAt = (hub?["alive_at"] as? NSNumber)?.doubleValue
        let heartbeatAge = aliveAt.map { now.timeIntervalSince1970 - $0 }
        let hubAlive = heartbeatAge.map { $0 >= 0 && $0 <= 6 } ?? false
        let jobs = hubAlive ? readHubJobs(hub?["jobs"]) : []
        let lastSeen = readPlatformLastSeen()
        let hooks = (hub?["hooks"] as? [String: Any])?.values.contains { ($0 as? Bool) == true } ?? false
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let sessions = hubAlive ? loadedSessions : []
            let requests = hubAlive ? loadedRequests : []
            if self.hubAlive != hubAlive { self.hubAlive = hubAlive }
            if self.sessions != sessions { self.sessions = sessions }
            self.hiddenRequestIDs.formIntersection(loadedRequests.map(\.id))
            let visible = requests.filter { !self.hiddenRequestIDs.contains($0.id) }
            if self.requests != visible { self.requests = visible }
            if self.hubJobs != jobs { self.hubJobs = jobs }
            if self.platformLastSeen != lastSeen { self.platformLastSeen = lastSeen }
            if self.hooksInstalled != hooks { self.hooksInstalled = hooks }
        }
    }

    private func readSessions(now: Date, requests: [AgentRequest]) -> [AgentSession] {
        let files = jsonFiles(in: sessionsURL)
        var result: [AgentSession] = []
        for file in files {
            guard let object = readObject(file),
                  let rawPlatform = object["platform"] as? String,
                  let platform = AgentPlatform(rawValue: rawPlatform) else { continue }
            let stem = file.deletingPathExtension().lastPathComponent
            let sessionId = object["sessionId"] as? String ?? ""
            let updatedAt = date(object["updatedAt"]) ?? now
            let rawStatus = object["status"] as? String ?? "idle"
            let pid = (object["pid"] as? NSNumber)?.int32Value
            if let pid, pid > 0, kill(pid, 0) == -1, errno == ESRCH {
                try? FileManager.default.removeItem(at: file)
                for requestFile in jsonFiles(in: requestsURL) {
                    guard let request = readObject(requestFile), request["platform"] as? String == platform.rawValue,
                          request["sessionId"] as? String == sessionId else { continue }
                    try? FileManager.default.removeItem(at: requestFile)
                }
                continue
            }
            let finishedAt = date(object["finishedAt"])
            // Sandboxed kill() may answer EPERM even for dead pids, so idle sessions also age out.
            if ((rawStatus == "done" || rawStatus == "error") && now.timeIntervalSince(finishedAt ?? updatedAt) > 15 * 60)
                || now.timeIntervalSince(updatedAt) > 3 * 60 * 60 {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            guard let status = AgentStatus(rawValue: rawStatus == "working" && now.timeIntervalSince(updatedAt) > 20 * 60 ? "idle" : rawStatus) else { continue }
            let waiting = requests.contains { $0.platform == platform && $0.sessionId == sessionId }
            let cwd = object["cwd"] as? String ?? ""
            result.append(AgentSession(
                id: stem, platform: platform, platformName: object["platformName"] as? String ?? platform.displayName,
                sessionId: sessionId, title: object["title"] as? String ?? "", status: waiting ? .waiting : status,
                activity: object["activity"] as? String ?? "", app: nonEmpty(object["app"] as? String), pid: pid,
                steps: (object["steps"] as? NSNumber)?.intValue ?? 0,
                startedAt: date(object["startedAt"]) ?? updatedAt, turnStartedAt: date(object["turnStartedAt"]),
                updatedAt: updatedAt, finishedAt: finishedAt,
                project: object["project"] as? String ?? URL(fileURLWithPath: cwd).lastPathComponent,
                cwd: cwd, model: object["model"] as? String ?? "", lastPrompt: object["lastPrompt"] as? String ?? ""
            ))
        }
        let priority: [AgentStatus: Int] = [.waiting: 0, .working: 1, .idle: 2, .done: 3, .error: 4]
        return result.sorted {
            if priority[$0.status, default: 5] != priority[$1.status, default: 5] { return priority[$0.status, default: 5] < priority[$1.status, default: 5] }
            return $0.updatedAt > $1.updatedAt
        }
    }

    private func readRequests(now: Date) -> [AgentRequest] {
        var result: [AgentRequest] = []
        for file in jsonFiles(in: requestsURL) {
            guard let object = readObject(file),
                  let id = object["id"] as? String,
                  let rawPlatform = object["platform"] as? String,
                  let platform = AgentPlatform(rawValue: rawPlatform),
                  let rawKind = object["kind"] as? String,
                  let kind = AgentRequestKind(rawValue: rawKind) else { continue }
            let createdAt = date(object["createdAt"]) ?? now
            let canAnswer = object["canAnswer"] as? Bool ?? false
            if now.timeIntervalSince(createdAt) > 30 * 60 || (!canAnswer && kind == .attention && now.timeIntervalSince(createdAt) > 10 * 60) {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            let holdUntil = date(object["holdUntil"])
            result.append(AgentRequest(
                id: id, platform: platform, platformName: object["platformName"] as? String ?? platform.displayName,
                sessionId: object["sessionId"] as? String ?? "", kind: kind,
                title: object["title"] as? String ?? "", detail: object["detail"] as? String ?? "",
                tool: object["tool"] as? String ?? "",
                canAnswer: canAnswer && !(holdUntil.map { $0 < now } ?? false),
                options: object["options"] as? [String] ?? [], holdUntil: holdUntil, createdAt: createdAt,
                app: nonEmpty(object["app"] as? String),
                project: URL(fileURLWithPath: object["cwd"] as? String ?? "").lastPathComponent,
                choices: (object["choices"] as? [Any] ?? []).compactMap { $0 as? String },
                header: object["header"] as? String ?? ""
            ))
        }
        return result.sorted { $0.createdAt < $1.createdAt }
    }

    private func readHubJobs(_ value: Any?) -> [HubJob] {
        guard let values = value as? [[String: Any]] else { return [] }
        return values.compactMap { object in
            guard let id = object["id"] as? String, let started = date(object["started"]) else { return nil }
            let project = object["project"] as? String ?? ""
            return HubJob(id: id, worker: object["harness"] as? String ?? "", model: object["model"] as? String ?? "",
                          role: object["harness"] as? String ?? "", objective: object["objective"] as? String ?? "",
                          project: project, started: started,
                          state: (object["state"] as? String ?? object["status"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        }.sorted { $0.started > $1.started }
    }

    private func readPlatformLastSeen() -> [AgentPlatform: Date] {
        var result: [AgentPlatform: Date] = [:]
        for file in jsonFiles(in: platformsURL) {
            guard let object = readObject(file), let raw = object["platform"] as? String,
                  let platform = AgentPlatform(rawValue: raw), let lastEventAt = date(object["lastEventAt"]) else { continue }
            result[platform] = lastEventAt
        }
        return result
    }

    private func writeHeartbeat() {
        let hold = (answerFromNotch, holdSeconds)
        ioQueue.async { [weak self] in self?.writeHeartbeatOnQueue(hold: hold) }
    }

    private func writeHeartbeatOnQueue(hold: (Bool, Double), aliveAt: Double? = nil) {
        let data: [String: Any] = ["alive_at": aliveAt ?? Date().timeIntervalSince1970,
                                   "hold_permissions": hold.0, "hold_seconds": Int(hold.1)]
        writeJSON(data, to: rootURL.appendingPathComponent("notch.json"))
    }

    private func writeJSON(_ object: [String: Any], to destination: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        let temp = rootURL.appendingPathComponent(".tmp-\(UUID().uuidString)")
        do {
            try data.write(to: temp)
            chmod(temp.path, 0o600)
            if rename(temp.path, destination.path) != 0 { try? FileManager.default.removeItem(at: temp) }
        } catch {
            try? FileManager.default.removeItem(at: temp)
        }
    }

    private func hide(_ id: String) {
        hiddenRequestIDs.insert(id)
        requests.removeAll { $0.id == id }
    }

    private func openApp(bundleID: String?, platform: AgentPlatform) {
        let identifier = nonEmpty(bundleID) ?? platform.defaultBundleID
        guard let identifier else { NSSound.beep(); return }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first {
            app.activate(options: [.activateAllWindows])
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSSound.beep()
        }
    }

    private func jsonFiles(in directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]))?.filter { $0.pathExtension == "json" } ?? []
    }

    private func readObject(_ file: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: file), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }

    private func date(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: number.doubleValue)
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
