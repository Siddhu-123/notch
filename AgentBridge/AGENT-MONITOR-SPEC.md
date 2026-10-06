# AgentMonitor.swift spec (Notch side of the agent bubbles bus)

Create notch/notch/AgentMonitor.swift (new file; the Xcode project uses a synchronized folder, so it compiles automatically; edit no other file). It is the data layer for an "AI agents" feature in this sandboxed macOS SwiftUI menu-bar app. A Python hook bridge (outside the app) writes JSON files into ~/.notch-agents/; this class reads them, writes answers back, and writes a heartbeat. Swift 6 toolchain, macOS 15+ target, AppKit + SwiftUI + Foundation + Darwin only. Match the style of notch/notch/NotchServices.swift (final class, ObservableObject, static let shared, @Published, UserDefaults persisted with "notch." keys, load in init, persist in didSet).

PATHS. The app is sandboxed, so FileManager home is the container. Resolve the REAL home with getpwuid(getuid()).pw_dir (fallback NSHomeDirectory()). root = <realHome>/.notch-agents ; subdirs sessions/, requests/, responses/, platforms/ ; heartbeat file notch.json ; bridge file bin/notch-agent-bridge. Hub results dir = <realHome>/dev/agent-hub/data/results (read-only).

FILE FORMATS (all JSON objects; parse leniently with JSONSerialization, missing keys get defaults; ignore unparsable files; times are Unix epoch seconds as Double, may be null):
- sessions/<stem>.json: platform, platformName, sessionId, startedAt, title, status ("working"|"idle"|"done"|"error"), activity, app (bundle id string), pid (int), steps (int), turnStartedAt, updatedAt, cwd, project, model, lastPrompt, finishedAt.
- requests/<id>.json: id, platform, platformName, sessionId, kind ("permission"|"question"|"attention"), title, detail, tool, canAnswer (bool), options ([String]), holdUntil, createdAt, app, cwd.
- platforms/<platform>.json: platform, lastEventAt, lastEvent.
- hub results/*.json: id, worker, model, role, started, outcome, envelope{objective, project_root}. Only outcome == "running" counts; only look at files modified within the last 3 hours; ignore jobs whose started is older than 3 hours.

PUBLIC API (exact names; other code depends on them):

enum AgentPlatform: String, CaseIterable, Identifiable { case claude, codex, antigravity, opencode, hub
  var id: String { rawValue }
  var displayName: String   // "Claude Code", "Codex", "Antigravity", "OpenCode", "Agent Hub"
  var symbol: String        // SF Symbols: "sparkle", "chevron.left.forwardslash.chevron.right", "atom", "terminal", "point.3.connected.trianglepath.dotted"
  var tint: Color           // claude Color(red: 0.85, green: 0.47, blue: 0.34); codex Color(red: 0.36, green: 0.62, blue: 1.0); antigravity Color(red: 0.55, green: 0.48, blue: 1.0); opencode Color(red: 0.3, green: 0.8, blue: 0.62); hub Color(red: 0.95, green: 0.75, blue: 0.3)
  var defaultBundleID: String?  // claude "com.anthropic.claudefordesktop", codex "com.openai.codex", antigravity "com.google.antigravity", opencode "com.apple.Terminal", hub nil
}
enum AgentStatus: String { case working, waiting, idle, done, error
  var label: String  // "Working", "Needs you", "Idle", "Done", "Error"
}
enum AgentRequestKind: String { case permission, question, attention }
enum AgentDecision: String { case allow, always, deny, app }
struct AgentSession: Identifiable, Equatable { let id: String /* file stem */; var platform: AgentPlatform; var platformName: String; var sessionId: String; var title: String; var status: AgentStatus; var activity: String; var app: String?; var pid: Int32?; var steps: Int; var startedAt: Date; var turnStartedAt: Date?; var updatedAt: Date; var finishedAt: Date?; var project: String; var cwd: String; var model: String; var lastPrompt: String }
struct AgentRequest: Identifiable, Equatable { let id: String; var platform: AgentPlatform; var platformName: String; var sessionId: String; var kind: AgentRequestKind; var title: String; var detail: String; var tool: String; var canAnswer: Bool; var options: [String]; var holdUntil: Date?; var createdAt: Date; var app: String?; var project: String /* last path component of cwd */
  var supportsAlways: Bool { options.contains("always") } }
struct HubJob: Identifiable, Equatable { let id: String; var worker: String; var model: String; var role: String; var objective: String; var project: String /* last path component of envelope.project_root */; var started: Date }

final class AgentMonitor: ObservableObject {
  static let shared = AgentMonitor()
  @Published private(set) var sessions: [AgentSession] = []
  @Published private(set) var requests: [AgentRequest] = []
  @Published private(set) var hubJobs: [HubJob] = []
  @Published private(set) var platformLastSeen: [AgentPlatform: Date] = [:]
  @Published private(set) var bridgeInstalled = false
  @Published var bubblesEnabled: Bool      // key "notch.agents.bubbles", default true
  @Published var edgePeekEnabled: Bool     // "notch.agents.edgePeek", default true
  @Published var edgeDwell: Double         // "notch.agents.edgeDwell", default 0.4, clamp 0.15...1.5
  @Published var answerFromNotch: Bool     // "notch.agents.answer", default true; writes heartbeat immediately on change
  @Published var holdSeconds: Double       // "notch.agents.holdSeconds", default 45, clamp 5...540; writes heartbeat immediately on change
  static let installCommand = "python3 ~/dev/notch/notch/AgentBridge/install.py"
  var activeCount: Int        // sessions with status working or waiting, plus hubJobs.count
  func start()                // idempotent. Create root + subdirs (0700). Reload now, then a Timer every 0.5 s (RunLoop.main, .common mode) that reloads; write heartbeat now and every 2 s. Observe NSApplication.willTerminateNotification -> stop().
  func stop()                 // invalidate timers; write heartbeat with alive_at 0 so blocked hooks release at once.
  func reload()
  func respond(to request: AgentRequest, decision: AgentDecision)
  func dismiss(_ request: AgentRequest)
  func openApp(for request: AgentRequest)
  func openApp(for session: AgentSession)
  func openHubDashboard()     // NSWorkspace open http://127.0.0.1:8765
  func clearFinished()        // delete session files whose status is done or error; reload
  func session(for request: AgentRequest) -> AgentSession?  // same platform and sessionId
}

BEHAVIOUR
- File I/O runs on a private serial DispatchQueue; publish on main; only assign @Published arrays when the value actually changed (Equatable) so SwiftUI does not churn.
- Heartbeat notch.json = {"alive_at": now, "hold_permissions": answerFromNotch, "hold_seconds": Int(holdSeconds)}, written atomically (write temp file in root then rename), permissions 0600.
- Liveness/pruning on each reload: if a session has pid > 0 and kill(pid, 0) == -1 with errno == ESRCH, delete that session file and every request file with the same platform+sessionId. Delete session files with status done/error whose finishedAt (or updatedAt) is older than 15 minutes. Delete request files whose createdAt is older than 30 minutes, and passive (canAnswer false) attention requests older than 10 minutes. A session whose status is "working" but updatedAt is older than 20 minutes is shown as idle (do not rewrite the file).
- Derived status: if any request exists with the same platform+sessionId, that session's status is .waiting.
- A request with canAnswer true whose holdUntil is in the past is published with canAnswer false.
- Sort sessions: waiting, then working, then idle, then done, then error; within a group newest updatedAt first. Sort requests by createdAt ascending. Sort hubJobs by started descending.
- platform field: map raw string to AgentPlatform, unknown -> skip the file. platformName: use the file's value, fallback platform.displayName.
- respond(to:decision:): passive request (canAnswer false) -> openApp only, nothing written. Answerable + .app -> write {"decision":"app"} (releases the hold; the bridge rewrites the request as passive, so the bubble stays) and openApp. Answerable + allow/always/deny -> write the response and hide the request until its file disappears (no flicker on reload).
- dismiss: hide until the file disappears; if canAnswer write the "app" response (so the hook stops waiting), otherwise delete the request file.
- openApp: bundle id = request/session app if non-empty else platform.defaultBundleID. If NSRunningApplication.runningApplications(withBundleIdentifier:) has one, activate it (activate(options: [.activateAllWindows])). Else if NSWorkspace.shared.urlForApplication(withBundleIdentifier:) exists, NSWorkspace.shared.openApplication(at:configuration:). Else NSSound.beep().
- bridgeInstalled = FileManager.fileExists at bin/notch-agent-bridge.
- No third-party packages, no new targets, no print spam. Must build with the given xcodebuild check with zero errors.
