import AppKit
import SwiftUI

enum Phase6AgentPresentation {
    static func title(_ session: AgentSession) -> String {
        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.isEmpty || title.hasPrefix("<") else { return title }
        let project = session.cwd.hasPrefix("/") ? URL(fileURLWithPath: session.cwd).lastPathComponent : session.project
        return project.isEmpty || project.hasPrefix("<") ? "\(session.platformName) activity" : project
    }
}

/// One or two source cards sharing the page width equally. Each card shows only the
/// controls its source really supports; there is no audio spectrum here because the
/// system spectrum cannot be attributed to a single source.
struct Phase6MediaCardsView: View {
    @ObservedObject var store: Phase6MediaSourceStore
    let sources: [Phase6MediaSource]

    var body: some View {
        VStack(spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(sources) { source in
                        Phase6MediaCard(source: source, store: store, compact: sources.count > 1)
                            .frame(minWidth: sources.count > 1 ? 240 : 0, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 8) {
                        ForEach(sources) { source in
                            Phase6MediaCard(source: source, store: store, compact: true).frame(height: 132)
                        }
                    }
                }
            }
            Phase6MediaSourceChips(store: store)
        }
        .accessibilityIdentifier("media-sources")
    }
}

/// Directly show other discovered sources and their supported controls in Notch.
struct Phase6MediaSourceChips: View {
    @ObservedObject var store: Phase6MediaSourceStore

    var body: some View {
        if !store.others.isEmpty {
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 4) {
                    ForEach(store.others) { source in
                        Button { store.select(source) } label: {
                            Text(source.name.uppercased()).font(.system(size: 11, weight: .bold, design: .rounded)).tracking(0.6)
                                .foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                                .padding(.horizontal, 8).padding(.vertical, 4).background(.white.opacity(0.08), in: Capsule())
                        }
                        .buttonStyle(.plain).help("Show controls for \(source.name)").accessibilityLabel("Show controls for \(source.name)")
                    }
                }
            }
            .frame(height: 28)
            .accessibilityIdentifier("media-source-shortcuts")
        }
    }
}

private struct Phase6MediaCard: View {
    let source: Phase6MediaSource
    @ObservedObject var store: Phase6MediaSourceStore
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(source.name.uppercased()).font(.system(size: 11, weight: .bold, design: .rounded)).tracking(0.8)
                    .foregroundStyle(.white.opacity(0.42)).lineLimit(1)
                Spacer(minLength: 2)
                Button { store.open(source) } label: { Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .bold)).frame(width: 24, height: 24).contentShape(Rectangle()) }
                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.4))
                    .help("Open \(source.name)").accessibilityLabel("Open \(source.name)")
            }
            HStack(spacing: 8) {
                artwork.frame(width: compact ? 40 : 56, height: compact ? 40 : 56)
                VStack(alignment: .leading, spacing: 1) {
                    Text(source.hasTrack ? source.title : "Audio stream active").font(.system(size: compact ? 13 : 15, weight: .bold, design: .rounded)).lineLimit(1)
                    Text(source.hasTrack ? source.artist : "No track info available").font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.58)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
            controls
        }
        .padding(8)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder private var controls: some View {
        if source.capability == .none {
            Text(source.hasTrack ? "Open \(source.name) to control playback" : "Controls unavailable. Open \(source.name)")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.5)).lineLimit(2)
        } else {
            VStack(spacing: 4) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    ProgressView(value: source.progress(at: context.date)).progressViewStyle(.linear).controlSize(.mini).tint(.white.opacity(0.8))
                }
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    MusicIconButton(symbol: "backward.fill", label: "Previous track, \(source.name)") { store.transport(.previous, for: source) }
                    MusicIconButton(symbol: source.isPlaying ? "pause.fill" : "play.fill",
                                    label: (source.isPlaying ? "Pause " : "Play ") + source.name, prominent: true) { store.transport(.togglePlayPause, for: source) }
                    MusicIconButton(symbol: "forward.fill", label: "Next track, \(source.name)") { store.transport(.next, for: source) }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    @ViewBuilder private var artwork: some View {
        Group {
            if let image = source.artwork { Image(nsImage: image).resizable().scaledToFill() }
            else { Image(systemName: source.hasTrack ? "music.note" : "speaker.wave.2.fill").font(.system(size: 18)).frame(maxWidth: .infinity, maxHeight: .infinity).background(.white.opacity(0.07)) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Place this in the shell header so Requests stays reachable on every page.
struct Phase6AgentSidebarButton: View {
    @ObservedObject var monitor: AgentMonitor
    @Binding var isPresented: Bool

    private var working: Int { monitor.sessions.filter { $0.status == .working }.count }

    var body: some View {
        Button { isPresented.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: "sidebar.right")
                if !monitor.requests.isEmpty { Text("\(monitor.requests.count)").monospacedDigit().foregroundStyle(.orange) }
                if working > 0 { Text("\(working)").monospacedDigit() }
            }
        }
        .buttonStyle(.plain).help("Requests and progress: \(monitor.requests.count) waiting, \(working) working")
        .accessibilityLabel("Requests and progress, \(monitor.requests.count) waiting, \(working) working")
        .accessibilityIdentifier("agent-sidebar-toggle")
    }
}

/// A single scrolling sidebar, with live requests first and projects beneath.
/// AgentMonitor remains owned by the existing app lifecycle, not this view.
struct Phase6AgentSidebarView: View {
    @ObservedObject var monitor: AgentMonitor
    var onClose: (() -> Void)? = nil
    @State private var navigationError: String?

    private var sessions: [AgentSession] {
        monitor.sessions.sorted {
            let priority: (AgentStatus) -> Int = { $0 == .waiting ? 0 : $0 == .working ? 1 : 2 }
            let first = priority($0.status), second = priority($1.status)
            return first == second ? $0.updatedAt > $1.updatedAt : first < second
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Requests & progress").font(.system(size: 13, weight: .semibold))
                Spacer()
                if let onClose {
                    Button(action: onClose) { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Close requests sidebar")
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(monitor.requests) { request in requestCard(request) }
                    ForEach(sessions) { session in sessionCard(session) }
                    ForEach(monitor.hubJobs) { job in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(job.worker, systemImage: "gearshape.2").font(.system(size: 11, weight: .semibold))
                            Text(job.objective).font(.system(size: 11)).lineLimit(3)
                            Text([job.project, job.model].filter { !$0.isEmpty }.joined(separator: " · ")).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                            Text(job.statusLabel).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                    }
                    if monitor.requests.isEmpty && sessions.isEmpty && monitor.hubJobs.isEmpty {
                        Text(monitor.hubAlive ? "No requests or active projects" : "Agent bridge is offline")
                            .font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 16)
                    }
                }
            }
            if let navigationError { Text(navigationError).font(.caption).foregroundStyle(.secondary) }
            HStack(spacing: 5) {
                Circle().fill(monitor.hubAlive ? Color.green : Color.secondary).frame(width: 5, height: 5)
                Text(monitor.hubAlive ? "Live agent activity" : "Waiting for agent bridge").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("agent-requests-sidebar")
    }

    private func requestCard(_ request: AgentRequest) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 8) {
                AgentRequestContent(request: request, roomy: true)
                if let until = request.holdUntil, request.canAnswer {
                    Text(until > context.date ? "Waiting for your decision · \(Int(ceil(until.timeIntervalSince(context.date))))s" : "Answer in the app")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    if Phase6AgentNavigation.canRespond(request, decision: .deny, at: context.date) {
                        Button("Deny") { respond(request, .deny) }.controlSize(.small)
                    }
                    if Phase6AgentNavigation.canRespond(request, decision: .allow, at: context.date) {
                        Button("Allow once") { respond(request, .allow) }.controlSize(.small)
                    }
                    Button("Open app") { monitor.respond(to: request, decision: .app) }.controlSize(.small)
                }
                if let session = monitor.session(for: request) { navigation(session) }
            }
            .padding(10).background(request.platform.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func respond(_ request: AgentRequest, _ decision: AgentDecision) {
        guard let live = monitor.requests.first(where: { $0.id == request.id }),
              Phase6AgentNavigation.canRespond(live, decision: decision) else { return }
        monitor.respond(to: live, decision: decision)
    }

    private func sessionCard(_ session: AgentSession) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label(session.platformName, systemImage: session.platform.symbol).foregroundStyle(session.platform.tint)
                Spacer(minLength: 4)
                Text(session.status.label).foregroundStyle(.secondary)
            }.font(.system(size: 10, weight: .semibold))
            Text(Phase6AgentPresentation.title(session)).font(.system(size: 12, weight: .semibold)).lineLimit(2)
            if !session.activity.isEmpty { Text(session.activity).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3) }
            Text([session.project, session.model, session.steps > 0 ? "\(session.steps) steps" : ""].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
            navigation(session)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
    }

    private func navigation(_ session: AgentSession) -> some View {
        HStack(spacing: 8) {
            Button(session.platform == .codex && UUID(uuidString: session.sessionId) != nil ? "Open chat" : "Open in app") {
                Phase6AgentNavigation.openTask(session, monitor: monitor)
            }.controlSize(.small)
            if session.cwd.hasPrefix("/") {
                Button("Project") {
                    navigationError = Phase6AgentNavigation.revealProject(session) ? nil : "This project folder could not be opened."
                }.controlSize(.small).help(session.cwd)
            }
        }
    }
}
