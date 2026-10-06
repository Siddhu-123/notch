import AppKit
import Combine
import CoreAudio
import CoreServices
import Foundation

/// One discovered media source: the system now-playing app, a native player read
/// through its own notifications/AppleScript, or an app that is outputting audio
/// without any track information (never presented as a browser tab or a track).
struct Phase6MediaSource: Identifiable {
    enum Origin { case currentPlayer, nativePlayer, audioProcess }
    /// What a transport button may do for this source.
    enum Capability {
        case targeted   // AppleScript addressed to this exact player
        case system     // global MediaRemote command; valid only for the system current player
        case none       // no safe command: open the app instead
    }
    let id: String
    var name: String
    var bundleID: String
    var pid: pid_t?
    var origin: Origin
    var title: String
    var artist: String
    var isPlaying: Bool
    var duration: Double
    var elapsed: Double
    var updatedAt: Date
    var artwork: NSImage?
    var isCurrent: Bool = false
    var supportsTargetedTransport: Bool = false

    var hasTrack: Bool { origin != .audioProcess && !title.isEmpty }
    var capability: Capability {
        guard hasTrack else { return .none }
        return supportsTargetedTransport ? .targeted : (isCurrent ? .system : .none)
    }

    func elapsed(at date: Date) -> Double {
        guard isPlaying else { return elapsed }
        let value = elapsed + max(0, date.timeIntervalSince(updatedAt))
        return duration > 0 ? min(value, duration) : value
    }

    func progress(at date: Date) -> Double { duration > 0 ? min(max(elapsed(at: date) / duration, 0), 1) : 0 }

    /// Display equality used to avoid republishing on every poll.
    func isEquivalent(to other: Phase6MediaSource, at date: Date) -> Bool {
        id == other.id && name == other.name && title == other.title && artist == other.artist
            && isPlaying == other.isPlaying && isCurrent == other.isCurrent && pid == other.pid
            && supportsTargetedTransport == other.supportsTargetedTransport
            && abs(elapsed(at: date) - other.elapsed(at: date)) < 2
            && (artwork == nil) == (other.artwork == nil)
    }
}

/// How the Now Playing page lays itself out. `system` keeps the original look.
enum Phase6MediaLayout {
    case system
    case cards([Phase6MediaSource])
}

/// Pure source selection/merging; no system access so it is deterministic to test.
enum Phase6MediaMerge {
    /// A "playing" notification nothing corroborates (no audio output, no current-player
    /// report) is dropped after this long: players only notify on change.
    static let uncorroboratedPlayingTTL: TimeInterval = 15
    static let pausedTTL: TimeInterval = 600

    static func merge(current: Phase6MediaSource?, native: [Phase6MediaSource], processes: [Phase6MediaSource],
                      permitted: Set<String>, now: Date) -> [Phase6MediaSource] {
        let outputting = Set(processes.map(\.bundleID).filter { !$0.isEmpty })
        var result = native.filter { source in
            let age = now.timeIntervalSince(source.updatedAt)
            return source.isPlaying ? (age < uncorroboratedPlayingTTL || outputting.contains(source.bundleID)) : age < pausedTTL
        }
        if let current {
            result.removeAll { !current.bundleID.isEmpty && $0.bundleID == current.bundleID }
            result.append(current)
        }
        for index in result.indices { result[index].supportsTargetedTransport = permitted.contains(result[index].bundleID) }
        for process in processes where !result.contains(where: {
            ($0.pid != nil && $0.pid == process.pid) || (!$0.bundleID.isEmpty && $0.bundleID == process.bundleID)
        }) { result.append(process) }
        return result.sorted {
            if $0.isCurrent != $1.isCurrent { return $0.isCurrent }
            if $0.isPlaying != $1.isPlaying { return $0.isPlaying }
            return $0.name < $1.name
        }
    }

    /// The source the page shows by default: the current player if it is playing, else
    /// whatever is actually playing, else the current (paused) player.
    static func primary(_ sources: [Phase6MediaSource]) -> Phase6MediaSource? {
        if let current = sources.first(where: \.isCurrent), current.isPlaying { return current }
        return sources.first(where: \.isPlaying) ?? sources.first(where: \.isCurrent) ?? sources.first(where: \.hasTrack)
    }

    /// Two or more playing sources are shown together (two cards at most, equal width).
    static func displayed(_ sources: [Phase6MediaSource], selectedID: String? = nil) -> [Phase6MediaSource] {
        let playing = sources.filter(\.isPlaying)
        if let selected = selectedID.flatMap({ id in sources.first { $0.id == id } }) {
            guard selected.isPlaying else { return [selected] }
            let companion = playing.first { $0.isCurrent && $0.id != selected.id }
                ?? playing.first { $0.id != selected.id }
            return companion.map { [selected, $0] } ?? [selected]
        }
        if playing.count >= 2 { return Array(playing.prefix(2)) }
        return primary(sources).map { [$0] } ?? []
    }

    static func layout(_ sources: [Phase6MediaSource], selectedID: String? = nil) -> Phase6MediaLayout {
        let shown = displayed(sources, selectedID: selectedID)
        return shown.count == 1 && shown[0].isCurrent || shown.isEmpty ? .system : .cards(shown)
    }

    /// Other discoverable sources available for direct selection in Notch.
    static func others(_ sources: [Phase6MediaSource], excluding shown: [Phase6MediaSource]) -> [Phase6MediaSource] {
        sources.filter { source in !shown.contains { $0.id == source.id } && (source.hasTrack || source.isPlaying) }
    }

    /// Helpers (e.g. "com.google.Chrome.helper") belong to the longest running app bundle that prefixes them.
    static func owner(of bundleID: String, among apps: [String]) -> String? {
        apps.filter { bundleID == $0 || bundleID.hasPrefix($0 + ".") }.max { $0.count < $1.count }
    }

    /// Resolve a current-player helper onto a running regular app. If its bundle is
    /// unavailable, use only an unambiguous exact app-name match; never guess a tab.
    static func currentOwner(bundleID: String, sourceApp: String, among apps: [(id: String, name: String)]) -> String? {
        if let id = owner(of: bundleID, among: apps.map(\.id)) { return id }
        guard !sourceApp.isEmpty else { return nil }
        let matching = apps.filter { $0.name.localizedCaseInsensitiveCompare(sourceApp) == .orderedSame }
        return matching.count == 1 ? matching[0].id : nil
    }

    /// A global command may follow a system card only while its app identity
    /// still matches. Unknown bundle IDs require an exact nonzero PID match.
    static func canSendSystemCommand(to source: Phase6MediaSource, currentBundleID: String, currentPID: pid_t?) -> Bool {
        guard source.capability == .system else { return false }
        if !source.bundleID.isEmpty && !currentBundleID.isEmpty { return source.bundleID == currentBundleID }
        guard let pid = source.pid, pid > 0, let currentPID else { return false }
        return pid == currentPID
    }
}

/// Owned by the Now Playing page while it is visible. Starting it never asks for an
/// Automation grant. Only Music and Spotify get per-player transport; MediaRemote is global.
/// It observes the monitor's `song` only, never the audio spectrum.
final class Phase6MediaSourceStore: ObservableObject {
    @Published private(set) var sources: [Phase6MediaSource] = []
    @Published private(set) var actionError: String?
    @Published private(set) var selectedSourceID: String?
    private let monitor: NowPlayingMonitor
    private let queue = DispatchQueue(label: "com.notch.media.sources", qos: .utility)
    private var subscription: AnyCancellable?
    private var tokens: [NSObjectProtocol] = []
    private var timer: Timer?
    private var native: [String: Phase6MediaSource] = [:]
    private var processes: [Phase6MediaSource] = []
    private var permitted = Set<String>()
    private var running = false
    private var polling = false
    private var generation = 0
    private static let pollInterval: TimeInterval = 2
    private static let players = [("com.apple.Music", "Music"), ("com.spotify.client", "Spotify")]

    init(monitor: NowPlayingMonitor = .shared) { self.monitor = monitor }

    var layout: Phase6MediaLayout { Phase6MediaMerge.layout(sources, selectedID: selectedSourceID) }
    var others: [Phase6MediaSource] {
        Phase6MediaMerge.others(sources, excluding: Phase6MediaMerge.displayed(sources, selectedID: selectedSourceID))
    }

    func select(_ source: Phase6MediaSource) {
        guard sources.contains(where: { $0.id == source.id }) else { return }
        selectedSourceID = source.id
        actionError = nil
    }

    func start() {
        guard !running else { return }
        running = true
        subscription = monitor.$song.combineLatest(monitor.$activePID)
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuild() }
        let center = DistributedNotificationCenter.default()
        for (name, bundleID) in [("com.apple.Music.playerInfo", "com.apple.Music"),
                                 ("com.spotify.client.PlaybackStateChanged", "com.spotify.client"),
                                 ("com.spotify.client.PlaybackStateChangedV2", "com.spotify.client")] {
            tokens.append(center.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] note in
                self?.receive(note.userInfo, bundleID: bundleID)
            })
        }
        timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in self?.refresh() }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        refresh()
    }

    func stop() {
        running = false
        generation += 1
        polling = false
        timer?.invalidate()
        timer = nil
        subscription = nil
        tokens.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        tokens.removeAll()
        native.removeAll()
        processes.removeAll()
        permitted.removeAll()
        sources.removeAll()
        selectedSourceID = nil
    }

    deinit {
        timer?.invalidate()
        tokens.forEach { DistributedNotificationCenter.default().removeObserver($0) }
    }

    func refresh() {
        guard running, !polling else { return }
        polling = true
        let expected = generation
        queue.async { [weak self] in
            let processes = Self.outputProcesses()
            var players: [String: Phase6MediaSource] = [:]
            var allowed = Set<String>()
            for (id, name) in Self.players where Self.hasAutomationAccess(id) {
                allowed.insert(id)
                if let source = Self.readPlayer(id: id, name: name) { players[id] = source }
            }
            DispatchQueue.main.async {
                guard let self, self.running, self.generation == expected else { return }
                self.polling = false
                self.processes = processes
                self.permitted = allowed
                // A granted player is authoritative: a failed read means "not playing".
                for (id, _) in Self.players where allowed.contains(id) { self.native[id] = players[id] }
                self.rebuild()
            }
        }
    }

    /// Targeted AppleScript where the source supports it; the global command only for
    /// the system current player. Anything else is ignored, never rerouted.
    func transport(_ command: MediaRemoteAdapter.Command, for source: Phase6MediaSource) {
        guard let live = sources.first(where: { $0.id == source.id }) else { return }
        actionError = nil
        switch live.capability {
        case .targeted:
            let verbs: [MediaRemoteAdapter.Command: String] = [
                .play: "play", .pause: "pause", .togglePlayPause: "playpause", .next: "next track", .previous: "previous track",
            ]
            if let verb = verbs[command] { perform(verb, bundleID: live.bundleID) }
        case .system:
            let identity = currentPlayerIdentity()
            guard monitor.song.hasTrack,
                  Phase6MediaMerge.canSendSystemCommand(to: live, currentBundleID: identity.bundleID, currentPID: identity.pid) else {
                actionError = "The current player changed. Use its updated controls."
                rebuild()
                return
            }
            switch command {
            case .togglePlayPause: monitor.playPause()
            case .next: monitor.nextTrack()
            case .previous: monitor.previousTrack()
            case .play, .pause: break
            }
        case .none: break
        }
    }

    func open(_ source: Phase6MediaSource) {
        let app = source.pid.flatMap { NSRunningApplication(processIdentifier: $0) }
            ?? NSRunningApplication.runningApplications(withBundleIdentifier: source.bundleID).first
        app?.activate()
    }

    private func perform(_ verb: String, bundleID: String) {
        guard Self.players.contains(where: { $0.0 == bundleID }) else { return }
        queue.async { [weak self] in
            guard Self.hasAutomationAccess(bundleID) else {
                DispatchQueue.main.async { self?.actionError = "Player control needs existing Automation access." }
                return
            }
            let result = Self.script("tell application id \"\(bundleID)\"\nif it is running then\n\(verb)\nreturn \"ok\"\nend if\nend tell")
            DispatchQueue.main.async {
                guard let self else { return }
                if result != "ok" { self.actionError = "The player did not accept this command." }
                self.refresh()
            }
        }
    }

    private func receive(_ info: [AnyHashable: Any]?, bundleID: String) {
        guard running, let info else { return }
        let state = (info["Player State"] as? String ?? "").lowercased()
        guard state == "playing" || state == "paused", let title = info["Name"] as? String, !title.isEmpty else {
            native.removeValue(forKey: bundleID); rebuild(); return
        }
        let isMusic = bundleID == "com.apple.Music"
        let milliseconds = (info[isMusic ? "Total Time" : "Duration"] as? NSNumber)?.doubleValue ?? 0
        native[bundleID] = Phase6MediaSource(id: bundleID, name: isMusic ? "Music" : "Spotify", bundleID: bundleID,
            pid: NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier,
            origin: .nativePlayer, title: title, artist: info["Artist"] as? String ?? "", isPlaying: state == "playing",
            duration: max(0, milliseconds / 1000), elapsed: (info["Playback Position"] as? NSNumber)?.doubleValue ?? 0,
            updatedAt: Date(), artwork: nil)
        rebuild()
    }

    private func rebuild() {
        guard running else { return }
        let now = Date()
        native = native.filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0.value.bundleID).isEmpty }
        var current: Phase6MediaSource?
        let song = monitor.song
        if song.hasTrack {
            let identity = currentPlayerIdentity()
            let bundle = identity.bundleID
            current = Phase6MediaSource(id: bundle.isEmpty ? "current-player" : bundle,
                name: song.sourceApp.isEmpty ? "Now Playing" : song.sourceApp,
                bundleID: bundle, pid: identity.pid, origin: .currentPlayer, title: song.title, artist: song.artist,
                isPlaying: song.isPlaying, duration: song.duration, elapsed: song.elapsed,
                updatedAt: monitor.lastPlaybackUpdate, artwork: song.artwork, isCurrent: true)
        }
        let merged = Phase6MediaMerge.merge(current: current, native: Array(native.values), processes: processes,
                                            permitted: permitted, now: now)
        let unchanged = merged.count == sources.count && zip(merged, sources).allSatisfy { $0.isEquivalent(to: $1, at: now) }
        if !unchanged { sources = merged }
        if let selectedSourceID, !merged.contains(where: { $0.id == selectedSourceID }) { self.selectedSourceID = nil }
    }

    private func currentPlayerIdentity() -> (bundleID: String, pid: pid_t?) {
        let regular = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
        let reportedBundle = monitor.activePID.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier } ?? ""
        let owner = Phase6MediaMerge.currentOwner(bundleID: reportedBundle, sourceApp: monitor.song.sourceApp,
            among: regular.map { (id: $0.bundleIdentifier!, name: $0.localizedName ?? "") })
        let pid = owner.flatMap { id in regular.first { $0.bundleIdentifier == id }?.processIdentifier } ?? monitor.activePID
        return (owner ?? reportedBundle, pid)
    }

    private static func hasAutomationAccess(_ bundleID: String) -> Bool {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else { return false }
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        return AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, false) == noErr
    }

    private static func script(_ text: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: "with timeout of 2 seconds\n\(text)\nend timeout")?.executeAndReturnError(&error)
        return error == nil ? result?.stringValue : nil
    }

    private static func readPlayer(id: String, name: String) -> Phase6MediaSource? {
        let duration = id == "com.spotify.client" ? "(duration of current track) / 1000" : "duration of current track"
        let text = """
        with timeout of 2 seconds
            tell application id "\(id)"
                if not it is running then return ""
                set s to player state as text
                if s is not "playing" and s is not "paused" then return ""
                return {name of current track, artist of current track, s, \(duration), player position}
            end tell
        end timeout
        """
        var error: NSDictionary?
        guard let value = NSAppleScript(source: text)?.executeAndReturnError(&error), error == nil,
              value.numberOfItems == 5, let title = value.atIndex(1)?.stringValue, !title.isEmpty else { return nil }
        return Phase6MediaSource(id: id, name: name, bundleID: id,
            pid: NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.processIdentifier,
            origin: .nativePlayer, title: title, artist: value.atIndex(2)?.stringValue ?? "",
            isPlaying: value.atIndex(3)?.stringValue == "playing",
            duration: max(0, value.atIndex(4)?.doubleValue ?? 0), elapsed: max(0, value.atIndex(5)?.doubleValue ?? 0),
            updatedAt: Date(), artwork: nil)
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        .init(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func scalar<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T) -> T? {
        var property = address(selector)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value) == noErr ? value : nil
    }

    /// Apps currently outputting audio (Core Audio process objects), folded onto the owning
    /// regular app so browser helpers are neither duplicated nor listed as unopenable noise.
    /// System daemons and apps that cannot be opened are skipped.
    private static func outputProcesses() -> [Phase6MediaSource] {
        var property = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = ids.withUnsafeMutableBytes { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, $0.baseAddress!) }
        guard status == noErr else { return [] }
        let regular = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
        var found: [String: Phase6MediaSource] = [:]
        for id in ids {
            guard scalar(id, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0)) == 1,
                  let pid = scalar(id, kAudioProcessPropertyPID, initial: pid_t(0)), pid > 0, pid != getpid() else { continue }
            var bundleProperty = address(kAudioProcessPropertyBundleID)
            var bundle: Unmanaged<CFString>?
            var bundleSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let bundleID = AudioObjectGetPropertyData(id, &bundleProperty, 0, nil, &bundleSize, &bundle) == noErr
                ? (bundle?.takeRetainedValue() as String? ?? "") : ""
            let ownerID = regular.first(where: { $0.processIdentifier == pid })?.bundleIdentifier
                ?? Phase6MediaMerge.owner(of: bundleID, among: regular.compactMap(\.bundleIdentifier))
            guard let ownerID, let app = regular.first(where: { $0.bundleIdentifier == ownerID }) else { continue }
            found[ownerID] = Phase6MediaSource(id: "audio-\(ownerID)", name: app.localizedName ?? ownerID,
                bundleID: ownerID, pid: app.processIdentifier, origin: .audioProcess,
                title: "", artist: "", isPlaying: true, duration: 0, elapsed: 0, updatedAt: Date(), artwork: nil)
        }
        return found.values.sorted { $0.name < $1.name }
    }
}

enum Phase6AgentNavigation {
    static func openTask(_ session: AgentSession, monitor: AgentMonitor) {
        if session.platform == .codex, UUID(uuidString: session.sessionId) != nil,
           let url = URL(string: "codex://threads/\(session.sessionId)") {
            if NSWorkspace.shared.open(url) { return }
        }
        monitor.openApp(for: session)
    }

    @discardableResult
    static func revealProject(_ session: AgentSession) -> Bool {
        guard !session.cwd.isEmpty, session.cwd.hasPrefix("/"), !session.cwd.contains("\0") else { return false }
        let directory = URL(fileURLWithPath: session.cwd, isDirectory: true).standardizedFileURL
        NSWorkspace.shared.activateFileViewerSelecting([directory])
        // The brokered reveal request was dispatched; Finder confirms its result.
        return true
    }

    static func canRespond(_ request: AgentRequest, decision: AgentDecision, at date: Date = Date()) -> Bool {
        guard request.kind == .permission, request.canAnswer,
              request.holdUntil.map({ $0 > date }) ?? true else { return false }
        // Legacy permission bridges omit options; their only default decisions
        // are allow-once and deny. Questions/attention never inherit these.
        let options = request.options.isEmpty ? ["allow", "deny"] : request.options
        return options.contains(decision.rawValue)
    }
}
