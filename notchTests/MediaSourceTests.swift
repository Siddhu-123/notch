import Foundation
import Testing
@testable import notch

struct MediaSourceTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func source(_ bundle: String, name: String? = nil, origin: Phase6MediaSource.Origin = .nativePlayer, playing: Bool = true,
                        title: String = "Song", current: Bool = false, age: TimeInterval = 0, pid: pid_t? = nil) -> Phase6MediaSource {
        Phase6MediaSource(id: current ? bundle : "\(origin)-\(bundle)", name: name ?? bundle, bundleID: bundle, pid: pid, origin: origin,
            title: origin == .audioProcess ? "" : title, artist: "A", isPlaying: playing, duration: 200, elapsed: 10,
            updatedAt: now.addingTimeInterval(-age), artwork: nil, isCurrent: current)
    }

    private func merged(current: Phase6MediaSource? = nil, native: [Phase6MediaSource] = [], processes: [Phase6MediaSource] = [],
                        permitted: Set<String> = []) -> [Phase6MediaSource] {
        Phase6MediaMerge.merge(current: current, native: native, processes: processes, permitted: permitted, now: now)
    }

    @Test func defaultIsTheCurrentPlayingSourceAndKeepsTheSystemLayout() {
        let list = merged(current: source("chrome", current: true), native: [source("spotify", playing: false)])
        #expect(Phase6MediaMerge.primary(list)?.bundleID == "chrome")
        if case .system = Phase6MediaMerge.layout(list) {} else { Issue.record("expected system layout") }
    }

    @Test func aPlayingNativeSourceBeatsAPausedCurrentOne() {
        let list = merged(current: source("chrome", playing: false, current: true), native: [source("spotify")])
        #expect(Phase6MediaMerge.primary(list)?.bundleID == "spotify")
        guard case .cards(let shown) = Phase6MediaMerge.layout(list) else { Issue.record("expected cards"); return }
        #expect(shown.map(\.bundleID) == ["spotify"])
    }

    @Test func twoPlayingSourcesAreShownTogetherCurrentFirst() {
        let list = merged(current: source("chrome", current: true), native: [source("spotify"), source("music", playing: false)])
        guard case .cards(let shown) = Phase6MediaMerge.layout(list) else { Issue.record("expected cards"); return }
        #expect(shown.map(\.bundleID) == ["chrome", "spotify"])
        #expect(Phase6MediaMerge.others(list, excluding: shown).map(\.bundleID) == ["music"])
    }

    @Test func deliberateSourceSelectionShowsThirdPlayingSourceBesideCurrentPlayer() {
        let list = merged(current: source("chrome", current: true), native: [source("music"), source("spotify")])
        #expect(Phase6MediaMerge.displayed(list).map(\.bundleID) == ["chrome", "music"])
        let selected = list.first { $0.bundleID == "spotify" }!
        let displayed = Phase6MediaMerge.displayed(list, selectedID: selected.id)
        #expect(displayed.map(\.bundleID) == ["spotify", "chrome"])
        #expect(Phase6MediaMerge.others(list, excluding: displayed).map(\.bundleID) == ["music"])
        #expect(Phase6MediaMerge.displayed(list, selectedID: "missing").map(\.bundleID) == ["chrome", "music"])
    }

    @Test func selectingAPausedPlayerShowsItsOwnCardAndSupportedControls() {
        let list = merged(current: source("chrome", current: true), native: [source("music", playing: false)], permitted: ["music"])
        let selected = list.first { $0.bundleID == "music" }!
        let displayed = Phase6MediaMerge.displayed(list, selectedID: selected.id)
        #expect(displayed.map(\.bundleID) == ["music"])
        #expect(displayed.first?.capability == .targeted)
        #expect(Phase6MediaMerge.others(list, excluding: displayed).map(\.bundleID) == ["chrome"])
        guard case .cards(let cards) = Phase6MediaMerge.layout(list, selectedID: selected.id) else {
            Issue.record("Selected paused player needs its own card"); return
        }
        #expect(cards.count == 1)
    }

    @Test func staleSourcesAreDropped() {
        let stalePlaying = source("spotify", age: Phase6MediaMerge.uncorroboratedPlayingTTL + 1)
        let stalePaused = source("music", playing: false, age: Phase6MediaMerge.pausedTTL + 1)
        #expect(merged(native: [stalePlaying, stalePaused]).isEmpty)
        // An app still outputting audio corroborates a long-running track.
        let output = source("spotify", origin: .audioProcess)
        #expect(merged(native: [stalePlaying], processes: [output]).map(\.origin) == [.nativePlayer])
    }

    @Test func outputProcessesAreNotDuplicatedAndNeverControllable() {
        let list = merged(current: source("chrome", current: true, pid: 5), processes: [
            source("chrome", origin: .audioProcess, pid: 5), source("other", origin: .audioProcess, pid: 9)])
        #expect(list.map(\.bundleID) == ["chrome", "other"])
        #expect(list[1].capability == Phase6MediaSource.Capability.none)
    }

    @Test func onlyTheCurrentOrPermittedPlayerReceivesCommands() {
        let list = merged(current: source("chrome", current: true), native: [source("spotify"), source("com.apple.Music")],
                          permitted: ["com.apple.Music"])
        let byID = Dictionary(uniqueKeysWithValues: list.map { ($0.bundleID, $0) })
        #expect(byID["chrome"]?.capability == .system)
        #expect(byID["com.apple.Music"]?.capability == .targeted)
        #expect(byID["spotify"]?.capability == Phase6MediaSource.Capability.none)
    }

    @Test func globalTransportRequiresTheLiveCurrentPlayerIdentity() {
        let current = source("chrome", current: true, pid: 5)
        #expect(Phase6MediaMerge.canSendSystemCommand(to: current, currentBundleID: "chrome", currentPID: 5))
        #expect(!Phase6MediaMerge.canSendSystemCommand(to: current, currentBundleID: "spotify", currentPID: 5))
        #expect(!Phase6MediaMerge.canSendSystemCommand(to: source("chrome", pid: 5), currentBundleID: "chrome", currentPID: 5))
        var targeted = current
        targeted.supportsTargetedTransport = true
        #expect(!Phase6MediaMerge.canSendSystemCommand(to: targeted, currentBundleID: "chrome", currentPID: 5))
        #expect(!Phase6MediaMerge.canSendSystemCommand(to: source("chrome", origin: .audioProcess, current: true, pid: 5),
                                                     currentBundleID: "chrome", currentPID: 5))
    }

    @Test func unknownPlayerBundlesRequireAnExactRealPID() {
        let unknown = source("", current: true, pid: 5)
        #expect(Phase6MediaMerge.canSendSystemCommand(to: unknown, currentBundleID: "", currentPID: 5))
        #expect(!Phase6MediaMerge.canSendSystemCommand(to: unknown, currentBundleID: "", currentPID: 6))
        #expect(!Phase6MediaMerge.canSendSystemCommand(to: unknown, currentBundleID: "", currentPID: nil))
        #expect(!Phase6MediaMerge.canSendSystemCommand(to: source("", current: true), currentBundleID: "", currentPID: nil))
        #expect(!Phase6MediaMerge.canSendSystemCommand(to: source("", current: true, pid: 0), currentBundleID: "", currentPID: 0))
    }

    @Test func helperProcessesFoldOntoTheOwningApp() {
        let apps = ["com.google.Chrome", "com.google.Chrome.canary"]
        #expect(Phase6MediaMerge.owner(of: "com.google.Chrome.helper", among: apps) == "com.google.Chrome")
        #expect(Phase6MediaMerge.owner(of: "com.google.Chrome.canary.helper", among: apps) == "com.google.Chrome.canary")
        #expect(Phase6MediaMerge.owner(of: "com.google.ChromeX", among: apps) == nil)
    }

    @Test func currentBrowserHelperAndItsOutputAppProduceOnlyOneCard() {
        let apps = [(id: "com.google.Chrome", name: "Chrome"), (id: "com.apple.Safari", name: "Safari")]
        let bundle = Phase6MediaMerge.currentOwner(bundleID: "com.google.Chrome.helper", sourceApp: "Chrome", among: apps)
        #expect(bundle == "com.google.Chrome")
        let list = merged(current: source(bundle ?? "", current: true, pid: 5),
                          processes: [source("com.google.Chrome", origin: .audioProcess, pid: 7)])
        #expect(list.count == 1)
        #expect(list.first?.capability == .system)
    }

    @Test func missingCurrentBundleUsesAnExactUnambiguousRunningAppName() {
        let apps = [(id: "com.google.Chrome", name: "Chrome"), (id: "com.apple.Safari", name: "Safari")]
        let bundle = Phase6MediaMerge.currentOwner(bundleID: "", sourceApp: "Chrome", among: apps)
        #expect(bundle == "com.google.Chrome")
        let list = merged(current: source(bundle ?? "", current: true),
                          processes: [source("com.google.Chrome", origin: .audioProcess)])
        #expect(list.count == 1)
        #expect(Phase6MediaMerge.currentOwner(bundleID: "", sourceApp: "Now Playing", among: apps) == nil)
        #expect(Phase6MediaMerge.currentOwner(bundleID: "", sourceApp: "Chrome tab", among: apps) == nil)
        #expect(Phase6MediaMerge.currentOwner(bundleID: "", sourceApp: "Chrome", among: apps + [(id: "another.browser", name: "Chrome")]) == nil)
    }

    private func request(kind: AgentRequestKind = .permission, canAnswer: Bool = true,
                         options: [String] = [], holdUntil: Date? = nil) -> AgentRequest {
        AgentRequest(id: "test", platform: .codex, platformName: "Codex", sessionId: "test", kind: kind,
                     title: "A decision", detail: "", tool: "", canAnswer: canAnswer, options: options,
                     holdUntil: holdUntil, createdAt: now, app: nil, project: "Example")
    }

    @Test func legacyHeldPermissionsDefaultOnlyToAllowOnceAndDeny() {
        let live = request(holdUntil: now.addingTimeInterval(30))
        #expect(Phase6AgentNavigation.canRespond(live, decision: .allow, at: now))
        #expect(Phase6AgentNavigation.canRespond(live, decision: .deny, at: now))
        #expect(!Phase6AgentNavigation.canRespond(live, decision: .always, at: now))
        #expect(!Phase6AgentNavigation.canRespond(live, decision: .app, at: now))
    }

    @Test func expiredPassiveQuestionsAndRestrictedOptionsCannotBeApproved() {
        for unavailable in [request(holdUntil: now), request(holdUntil: now.addingTimeInterval(-1)),
                            request(canAnswer: false), request(kind: .question), request(kind: .attention),
                            request(options: ["app"]), request(options: ["deny"])] {
            #expect(!Phase6AgentNavigation.canRespond(unavailable, decision: .allow, at: now))
        }
        #expect(Phase6AgentNavigation.canRespond(request(options: ["deny"]), decision: .deny, at: now))
    }

    @Test func transportMarkupIsReplacedOnlyInTheVisibleSessionTitle() {
        var session = AgentSession(id: "test", platform: .codex, platformName: "Codex", sessionId: "test",
            title: "<send_user_message_question_reply>", status: .working, activity: "Working", app: nil,
            pid: nil, steps: 1, startedAt: now, turnStartedAt: nil, updatedAt: now, finishedAt: nil,
            project: "Example", cwd: "/tmp/Example", model: "", lastPrompt: "")
        #expect(Phase6AgentPresentation.title(session) == "Example")
        #expect(session.title == "<send_user_message_question_reply>")
        session.title = "Fix playback"
        #expect(Phase6AgentPresentation.title(session) == "Fix playback")
        session.title = ""
        session.cwd = ""
        session.project = ""
        #expect(Phase6AgentPresentation.title(session) == "Codex activity")
    }

    @Test func elapsedExtrapolatesOnlyWhilePlayingAndClampsToDuration() {
        let playing = source("a")
        #expect(playing.elapsed(at: now.addingTimeInterval(5)) == 15)
        #expect(playing.elapsed(at: now.addingTimeInterval(500)) == 200)
        #expect(source("a", playing: false).elapsed(at: now.addingTimeInterval(5)) == 10)
    }
}
