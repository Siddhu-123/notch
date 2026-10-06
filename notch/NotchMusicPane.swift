import AppKit
import AVFoundation
import Combine
import CoreAudio
import SwiftUI

struct IntegratedMusicView: View {
    @ObservedObject var nowPlaying: NowPlayingMonitor
    let availableHeight: CGFloat
    let activityNamespace: Namespace.ID
    let hapticsEnabled: Bool
    @ObservedObject private var controls = SystemControlCenter.shared
    @AppStorage(NotchFeature.upNext.defaultsKey) private var upNextEnabled = NotchFeature.upNext.defaultEnabled
    @AppStorage(NotchFeature.lyrics.defaultsKey) private var lyricsEnabled = NotchFeature.lyrics.defaultEnabled
    @State private var playerLaunchError: String?
    @State private var isSeeking = false
    @State private var seekValue = 0.0
    @State private var trackSwipe = CGFloat.zero
    @State private var trackSwipeThresholdReached = false
    @State private var hapticTrigger = 0
    @StateObject private var sources = Phase6MediaSourceStore()
    @State private var pageVisible = false
    @State private var upcomingTracks: [MusicUpcomingTrack] = []
    @State private var isLoadingUpcoming = false
    @State private var upcomingTask: Task<Void, Never>?
    @State private var lyricsVisible = false
    @State private var lyricsContent: MusicLyrics?
    @State private var isLoadingLyrics = false
    @State private var lyricsTask: Task<Void, Never>?
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
        let showUpcoming = upNextEnabled && nowPlaying.song.hasTrack && nowPlaying.song.sourceApp == "Music"
            && (isLoadingUpcoming || !upcomingTracks.isEmpty)
        let showLyrics = lyricsEnabled && lyricsVisible && nowPlaying.song.hasTrack
        let extraHeight: CGFloat = (showUpcoming ? 50 : 0) + (showLyrics ? 74 : 0) + (showUpcoming || showLyrics ? 12 : 4)
        let artSize = min(max(availableHeight - extraHeight, 64), 172)
        VStack(alignment: .leading, spacing: 5) {
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
            .accessibilityIdentifier("music-album-artwork")
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
                    .frame(minHeight: 28)
                    .contentShape(Rectangle())
                    .help("Open \(nowPlaying.song.sourceApp.isEmpty ? "player" : nowPlaying.song.sourceApp)")
                    .accessibilityIdentifier("music-source-open")

                    Phase6MediaSourceChips(store: sources)
                    outputPicker
                    if lyricsEnabled {
                        Button {
                            lyricsVisible.toggle()
                        } label: {
                            Label(lyricsVisible ? "Lyrics On" : "Lyrics", systemImage: "quote.bubble")
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .lineLimit(1)
                                .frame(minHeight: 28)
                                .padding(.horizontal, 7)
                                .background(lyricsVisible ? .white.opacity(0.14) : .white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(lyricsVisible ? 0.95 : 0.65))
                        .disabled(!nowPlaying.song.hasTrack)
                        .help(lyricsVisible ? "Hide lyrics." : "Show lyrics for this track.")
                        .accessibilityIdentifier("music-lyrics-toggle")
                    }
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
                .frame(minHeight: 28)
                .contentShape(Rectangle())
                .help("Open \(nowPlaying.song.sourceApp.isEmpty ? "player" : nowPlaying.song.sourceApp)")
                .accessibilityIdentifier("music-track-details")

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
                    .help("Seek in the current track.")
                    .accessibilityIdentifier("music-playback-position")
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
        if showUpcoming {
            upcomingStrip
        }
        if showLyrics {
            lyricsPanel
        }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            pageVisible = true
            refreshUpcoming()
            if lyricsVisible { loadLyrics() }
        }
        .onDisappear {
            pageVisible = false
            upcomingTask?.cancel()
            upcomingTask = nil
            lyricsTask?.cancel()
            lyricsTask = nil
        }
        .onChange(of: nowPlaying.song.id) { _, _ in
            refreshUpcoming()
            if lyricsVisible { loadLyrics() }
        }
        .onChange(of: nowPlaying.song.sourceApp) { _, _ in
            refreshUpcoming()
            if lyricsVisible { loadLyrics() }
        }
        .onChange(of: upNextEnabled) { _, enabled in
            if enabled { refreshUpcoming() }
            else {
                upcomingTask?.cancel()
                upcomingTracks = []
                isLoadingUpcoming = false
            }
        }
        .onChange(of: lyricsEnabled) { _, enabled in
            if enabled && lyricsVisible { loadLyrics() }
            if !enabled {
                lyricsVisible = false
                lyricsTask?.cancel()
                lyricsContent = nil
                isLoadingLyrics = false
            }
        }
        .onChange(of: lyricsVisible) { _, visible in
            if visible { loadLyrics() }
            else {
                lyricsTask?.cancel()
                lyricsContent = nil
                isLoadingLyrics = false
            }
        }
        .accessibilityIdentifier("home-panel")
    }

    private var outputPicker: some View {
        Menu {
            ForEach(controls.outputDevices) { device in
                Button {
                    controls.selectOutputDevice(device)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: device.symbol)
                        Text(device.name).lineLimit(1)
                        Spacer(minLength: 8)
                        if device.id == controls.currentOutputDeviceID {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .help("Switch audio output to \(device.name).")
                .accessibilityIdentifier("music-output-option-\(device.id)")
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: controls.currentOutputDevice?.symbol ?? "speaker.wave.2")
                Text(controls.isSwitchingOutput ? "Switching…" : (controls.currentOutputDevice?.name ?? "Sound output"))
                    .lineLimit(1)
            }
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.72))
            .frame(maxWidth: 148, minHeight: 28, alignment: .leading)
            .padding(.horizontal, 7)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .disabled(controls.isSwitchingOutput || controls.outputDevices.isEmpty)
        .help(controls.isSwitchingOutput ? "Switching audio output…" : "Choose the audio output device.")
        .accessibilityLabel("Audio output: \(controls.currentOutputDevice?.name ?? "unavailable")")
        .accessibilityIdentifier("music-output-picker")
    }

    private var upcomingStrip: some View {
        HStack(spacing: 6) {
            Text(isLoadingUpcoming ? "UP NEXT · …" : "UP NEXT")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(.white.opacity(0.42))
                .frame(width: 54, alignment: .leading)
            if upcomingTracks.isEmpty && isLoadingUpcoming {
                Text("Reading playlist…")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer(minLength: 0)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(upcomingTracks) { track in
                            Button {
                                MusicExtrasService.playUpcoming(trackIndex: track.index)
                            } label: {
                                HStack(spacing: 6) {
                                    Group {
                                        if let cover = MusicExtrasCache.cover(for: track.coverCacheKey) {
                                            Image(nsImage: cover).resizable().scaledToFill()
                                        } else {
                                            Image(systemName: "music.note")
                                                .font(.system(size: 13, weight: .medium))
                                                .foregroundStyle(.white.opacity(0.6))
                                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                                .background(.white.opacity(0.07))
                                        }
                                    }
                                    .frame(width: 36, height: 36)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(track.title)
                                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                                            .lineLimit(1)
                                        Text(track.artist)
                                            .font(.system(size: 8, weight: .medium))
                                            .foregroundStyle(.white.opacity(0.52))
                                            .lineLimit(1)
                                    }
                                    .frame(width: 94, alignment: .leading)
                                }
                                .padding(4)
                                .frame(minHeight: 44)
                                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Play \(track.title) by \(track.artist).")
                            .accessibilityIdentifier("music-up-next-\(track.index)")
                        }
                    }
                }
            }
        }
        .frame(height: 48)
        .accessibilityIdentifier("music-up-next-strip")
    }

    @ViewBuilder private var lyricsPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("LYRICS")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .tracking(0.6)
                    .foregroundStyle(.white.opacity(0.42))
                Spacer()
                if isLoadingLyrics {
                    ProgressView().controlSize(.mini).tint(.white.opacity(0.7))
                }
            }
            if let lyricsContent, !lyricsContent.timedLines.isEmpty {
                TimelineView(.animation(minimumInterval: 0.25, paused: !nowPlaying.song.isPlaying)) { timeline in
                    let activeIndex = LyricsParser.currentLineIndex(
                        in: lyricsContent.timedLines,
                        at: nowPlaying.estimatedElapsed(at: timeline.date)
                    )
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: true) {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(Array(lyricsContent.timedLines.enumerated()), id: \.offset) { index, line in
                                    Text(line.text)
                                        .font(.system(size: index == activeIndex ? 11 : 10, weight: index == activeIndex ? .bold : .medium, design: .rounded))
                                        .foregroundStyle(index == activeIndex ? .white : .white.opacity(0.5))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .id(index)
                                }
                            }
                        }
                        .frame(height: 54)
                        .onAppear {
                            if let activeIndex { proxy.scrollTo(activeIndex, anchor: .center) }
                        }
                        .onChange(of: activeIndex) { _, index in
                            if let index { withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(index, anchor: .center) } }
                        }
                    }
                }
            } else if let lyricsContent, !lyricsContent.plainText.isEmpty {
                ScrollView(.vertical, showsIndicators: true) {
                    Text(lyricsContent.plainText)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.82))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 54)
            } else {
                Text(isLoadingLyrics ? "Finding lyrics…" : "Lyrics aren’t available for this track.")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.52))
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            }
        }
        .padding(7)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("music-lyrics-panel")
    }

    private func refreshUpcoming() {
        upcomingTask?.cancel()
        guard pageVisible, upNextEnabled,
              nowPlaying.song.hasTrack, nowPlaying.song.sourceApp == "Music" else {
            upcomingTracks = []
            isLoadingUpcoming = false
            return
        }

        let trackID = nowPlaying.song.id
        let title = nowPlaying.song.title
        let artist = nowPlaying.song.artist
        isLoadingUpcoming = true
        upcomingTask = Task {
            let result = await Task.detached(priority: .utility) {
                MusicExtrasService.readUpcoming(currentTitle: title, currentArtist: artist)
            }.value
            guard !Task.isCancelled, pageVisible, upNextEnabled, nowPlaying.song.id == trackID else { return }
            upcomingTracks = result
            isLoadingUpcoming = false
        }
    }

    private func loadLyrics() {
        lyricsTask?.cancel()
        guard pageVisible, lyricsEnabled, lyricsVisible, nowPlaying.song.hasTrack else {
            lyricsContent = nil
            isLoadingLyrics = false
            return
        }

        let trackID = nowPlaying.song.id
        let artist = nowPlaying.song.artist
        let title = nowPlaying.song.title
        let duration = nowPlaying.song.duration
        let key = MusicExtrasService.lyricsCacheKey(artist: artist, title: title, duration: duration)
        if let cached = MusicExtrasCache.lyrics(for: key) {
            lyricsContent = cached
            isLoadingLyrics = false
            return
        }

        isLoadingLyrics = true
        lyricsContent = nil
        lyricsTask = Task {
            let result = await MusicExtrasService.loadLyrics(artist: artist, title: title, duration: duration)
            guard !Task.isCancelled, pageVisible, lyricsVisible, lyricsEnabled, nowPlaying.song.id == trackID else { return }
            lyricsContent = result
            isLoadingLyrics = false
        }
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
            .frame(minHeight: 28)
            .contentShape(Rectangle())
            .help("Open Apple Music.")
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
                .frame(width: 28, height: 28)
                .background(
                    prominent ? Color.white : (active ? activeTint.opacity(0.24) : .white.opacity(0.055)),
                    in: Circle()
                )
                .contentShape(Circle())
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
        .accessibilityIdentifier("music-control-\(label.lowercased().replacingOccurrences(of: " ", with: "-"))")
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
