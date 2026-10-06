import AppKit
import AVFoundation
import Combine
import SwiftUI

struct IntegratedMusicView: View {
    @ObservedObject var nowPlaying: NowPlayingMonitor
    let availableHeight: CGFloat
    let activityNamespace: Namespace.ID
    let hapticsEnabled: Bool
    @State private var playerLaunchError: String?
    @State private var isSeeking = false
    @State private var seekValue = 0.0
    @State private var trackSwipe = CGFloat.zero
    @State private var trackSwipeThresholdReached = false
    @State private var hapticTrigger = 0
    @StateObject private var sources = Phase6MediaSourceStore()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                switch sources.layout {
                case .system: singlePlayer
                case .cards(let shown):
                    Phase6MediaCardsView(store: sources, sources: shown)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            if let error = sources.actionError {
                Text(error)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .accessibilityIdentifier("media-action-error")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { sources.start() }
        .onDisappear { sources.stop() }
    }

    @ViewBuilder private var singlePlayer: some View {
        let artSize = min(max(availableHeight - 4, 92), 172)
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: trackSwipe < 0 ? .bottomTrailing : .bottomLeading) {
                ArtworkView(
                    image: nowPlaying.song.artwork,
                    fallbackSymbol: nowPlaying.song.hasTrack ? "music.note" : "waveform",
                    accent: NotchModule.nowPlaying.tint,
                    symbolSize: 30
                )
                .matchedGeometryEffect(id: "activity-artwork", in: activityNamespace, isSource: false)
                .offset(x: reduceMotion ? 0 : trackSwipe * 0.12)

                if abs(trackSwipe) > 12, nowPlaying.song.hasTrack {
                    Image(systemName: trackSwipe < 0 ? "forward.fill" : "backward.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(7)
                        .background(.black.opacity(0.62), in: Circle())
                        .padding(7)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: artSize, height: artSize)
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 0.75))
            .shadow(color: NotchModule.nowPlaying.tint.opacity(nowPlaying.song.isPlaying ? 0.22 : 0.08), radius: 18, y: 6)
            .contentShape(Rectangle())
            .onTapGesture {
                nowPlaying.activatePlayingApp()
            }
            .gesture(trackSwipeGesture)
            .sensoryFeedback(.alignment, trigger: hapticTrigger)
            .help(nowPlaying.song.hasTrack ? "Click to open \(nowPlaying.song.sourceApp.isEmpty ? "player" : nowPlaying.song.sourceApp)" : "Album artwork")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Album artwork")
            .accessibilityActions {
                if nowPlaying.song.hasTrack {
                    Button("Previous Track") { nowPlaying.previousTrack() }
                    Button("Next Track") { nowPlaying.nextTrack() }
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                if nowPlaying.song.hasTrack {
                HStack(spacing: 7) {
                    Button {
                        nowPlaying.activatePlayingApp()
                    } label: {
                        HStack(spacing: 4) {
                            Text(nowPlaying.song.hasTrack ? nowPlaying.song.sourceApp.uppercased() : "READY WHEN YOU ARE")
                                .font(.system(size: 8, weight: .bold, design: .rounded))
                                .tracking(0.8)
                                .foregroundStyle(.white.opacity(0.42))
                            if nowPlaying.song.hasTrack {
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 7, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.3))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Open \(nowPlaying.song.sourceApp.isEmpty ? "player" : nowPlaying.song.sourceApp)")

                    Phase6MediaSourceChips(store: sources)
                    Spacer(minLength: 2)
                    MiniVisualizer(isPlaying: nowPlaying.song.isPlaying)
                        .matchedGeometryEffect(id: "activity-spectrum", in: activityNamespace, isSource: false)
                        .frame(width: 28, height: 14)
                }

                Spacer(minLength: 4)

                Button {
                    nowPlaying.activatePlayingApp()
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        MarqueeText(
                            text: nowPlaying.song.title,
                            font: .system(size: 15, weight: .bold, design: .rounded)
                        )
                        .frame(height: 20)

                        MarqueeText(
                            text: nowPlaying.song.artist,
                            font: .system(size: 10, weight: .medium, design: .rounded)
                        )
                        .foregroundStyle(.white.opacity(0.58))
                        .frame(height: 14)
                    }
                }
                .buttonStyle(.plain)
                .help("Open \(nowPlaying.song.sourceApp.isEmpty ? "player" : nowPlaying.song.sourceApp)")

                Spacer(minLength: 5)

                TimelineView(.animation(minimumInterval: 0.1, paused: !nowPlaying.song.isPlaying || isSeeking)) { timeline in
                    Slider(
                        value: Binding(
                            get: { isSeeking ? seekValue : nowPlaying.estimatedProgress(at: timeline.date) },
                            set: { seekValue = $0; isSeeking = true }
                        ),
                        in: 0...1,
                        onEditingChanged: { editing in
                            if !editing {
                                nowPlaying.seek(to: seekValue)
                                isSeeking = false
                            }
                        }
                    )
                    .controlSize(.mini)
                    .tint(nowPlaying.dynamicAccentColor ?? .white)
                    .disabled(!nowPlaying.song.hasTrack)
                }
                .frame(height: 13)

                TimelineView(.animation(minimumInterval: 0.5, paused: !nowPlaying.song.isPlaying)) { timeline in
                    HStack {
                        Text(formatTime(isSeeking ? seekValue * nowPlaying.song.duration : nowPlaying.estimatedElapsed(at: timeline.date)))
                        Spacer()
                        Text(formatTime(nowPlaying.song.duration))
                    }
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.34))
                }

                Spacer(minLength: 3)

                HStack(spacing: 4) {
                    MusicIconButton(
                        symbol: "shuffle",
                        label: "Shuffle",
                        enabled: nowPlaying.song.hasTrack && nowPlaying.supportsQueueModes,
                        active: nowPlaying.song.isShuffled,
                        activeTint: nowPlaying.dynamicAccentColor ?? NotchModule.nowPlaying.tint
                    ) {
                        nowPlaying.toggleShuffle()
                    }
                    MusicIconButton(symbol: "gobackward.15", label: "Back 15 seconds", enabled: nowPlaying.song.hasTrack) {
                        nowPlaying.seek(by: -15)
                    }
                    MusicIconButton(symbol: "backward.fill", label: "Previous", enabled: nowPlaying.song.hasTrack) {
                        nowPlaying.previousTrack()
                    }
                    MusicIconButton(
                        symbol: nowPlaying.song.isPlaying ? "pause.fill" : "play.fill",
                        label: nowPlaying.song.isPlaying ? "Pause" : "Play",
                        prominent: true,
                        enabled: nowPlaying.song.hasTrack
                    ) { nowPlaying.playPause() }
                    MusicIconButton(symbol: "forward.fill", label: "Next", enabled: nowPlaying.song.hasTrack) {
                        nowPlaying.nextTrack()
                    }
                    MusicIconButton(symbol: "goforward.15", label: "Forward 15 seconds", enabled: nowPlaying.song.hasTrack) {
                        nowPlaying.seek(by: 15)
                    }
                    MusicIconButton(
                        symbol: nowPlaying.song.repeatMode == "one" ? "repeat.1" : "repeat",
                        label: "Repeat",
                        enabled: nowPlaying.song.hasTrack && nowPlaying.supportsQueueModes,
                        active: nowPlaying.song.repeatMode != "off",
                        activeTint: nowPlaying.dynamicAccentColor ?? NotchModule.nowPlaying.tint
                    ) {
                        nowPlaying.toggleRepeat()
                    }
                }
                } else {
                    emptyPlayer
                }
            }
            .frame(maxWidth: .infinity, maxHeight: artSize, alignment: .leading)
        }
        .accessibilityIdentifier("home-panel")
    }

    private var emptyPlayer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your music, within reach")
                .font(.system(size: 15, weight: .bold, design: .rounded))
            Text(playerLaunchError ?? "Play in Music, Spotify or your browser. Your track appears here.")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.58))
                .fixedSize(horizontal: false, vertical: true)
            Button(action: openMusic) {
                Label("Open Music", systemImage: "music.note")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(NotchModule.nowPlaying.tint.opacity(0.18), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("open-music")
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }

    private func openMusic() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Music") else {
            playerLaunchError = "Music isn't installed. Play in another app to begin."
            return
        }
        playerLaunchError = nil
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, error in
            guard let error else { return }
            let message = "Couldn't open Music: \(error.localizedDescription)"
            Task { @MainActor in playerLaunchError = message }
        }
    }

    private var trackSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard nowPlaying.song.hasTrack,
                      abs(value.translation.width) > abs(value.translation.height) * 1.4 else { return }
                trackSwipe = min(max(value.translation.width, -78), 78)
                let reached = abs(trackSwipe) > 48
                if reached && !trackSwipeThresholdReached {
                    trackSwipeThresholdReached = true
                    if hapticsEnabled { hapticTrigger += 1 }
                } else if !reached {
                    trackSwipeThresholdReached = false
                }
            }
            .onEnded { value in
                let intent = NotchDragIntent.track(value.translation, hasTrack: nowPlaying.song.hasTrack)
                if intent == .next { nowPlaying.nextTrack() }
                if intent == .previous { nowPlaying.previousTrack() }
                withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.76)) {
                    trackSwipe = 0
                }
                trackSwipeThresholdReached = false
            }
    }
}

struct MusicIconButton: View {
    let symbol: String
    let label: String
    var prominent = false
    var enabled = true
    var active = false
    var activeTint: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: prominent ? 12 : 10, weight: .bold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: prominent ? 28 : 22, height: 22)
                .background(
                    prominent ? Color.white : (active ? activeTint.opacity(0.24) : .white.opacity(0.055)),
                    in: Circle()
                )
                .foregroundStyle(
                    prominent ? .black : (active ? activeTint : .white.opacity(0.72))
                )
                .overlay {
                    if active {
                        Circle().stroke(activeTint.opacity(0.42), lineWidth: 0.75)
                    }
                }
        }
        .buttonStyle(TactileButtonStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.34)
        .help(label)
        .accessibilityLabel(label)
    }
}

struct MarqueeText: View {
    let text: String
    let font: Font
    var minDuration: Double = 7.0
    @State private var offset: CGFloat = 0
    @State private var textWidth: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let diff = textWidth - proxy.size.width
            Group {
                if diff > 6 && !reduceMotion {
                    Text(text)
                        .font(font)
                        .lineLimit(1)
                        .fixedSize()
                        .offset(x: offset)
                        .onAppear { startAnimation(diff: diff) }
                        .onChange(of: text) { _, _ in
                            offset = 0
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                startAnimation(diff: textWidth - proxy.size.width)
                            }
                        }
                } else {
                    Text(text)
                        .font(font)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background {
                Text(text)
                    .font(font)
                    .lineLimit(1)
                    .fixedSize()
                    .background(GeometryReader { textProxy in
                        Color.clear.preference(key: TextWidthPreferenceKey.self, value: textProxy.size.width)
                    })
                    .hidden()
            }
        }
        .onPreferenceChange(TextWidthPreferenceKey.self) { textWidth = $0 }
        .clipped()
    }

    private func startAnimation(diff: CGFloat) {
        guard diff > 6 else { return }
        offset = 0
        let duration = max(minDuration, Double(diff) * 0.08)
        withAnimation(.linear(duration: duration).delay(1.5).repeatForever(autoreverses: true)) {
            offset = -diff - 6
        }
    }
}

struct TextWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

