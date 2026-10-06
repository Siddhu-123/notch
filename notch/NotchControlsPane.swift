import AppKit
import AVFoundation
import Combine
import SwiftUI

struct BatteryPill: View {
    let snapshot: BatterySnapshot

    var body: some View {
        Label("\(snapshot.percentage)%", systemImage: snapshot.symbol)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(snapshot.isCharging ? .green : .white.opacity(0.7))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(.white.opacity(0.07), in: Capsule())
    }
}

struct CompactControlsPane: View {
    @ObservedObject var controls: SystemControlCenter

    var body: some View {
        GeometryReader { geometry in
            let tight = geometry.size.height < 136
            let wide = geometry.size.width >= 700
            ScrollView(.vertical, showsIndicators: true) {
                Group {
                    if wide {
                        HStack(alignment: .top, spacing: 10) {
                            soundSection(tight: tight)
                            displayPowerSection(tight: tight)
                            ControlsVoiceSection(tight: tight)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .top, spacing: 10) {
                                soundSection(tight: tight)
                                displayPowerSection(tight: tight)
                            }
                            ControlsVoiceSection(tight: tight)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("controls-panel")
    }

    private func section<Content: View>(_ title: String, symbol: String, tight: Bool, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: tight ? 6 : 8) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
            content()
        }
        .padding(tight ? 6 : 8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func soundSection(tight: Bool) -> some View {
        section("Sound", symbol: "speaker.wave.2.fill", tight: tight) {
            soundOutputMenu

            compactSlider(
                symbol: (controls.isMuted || !controls.isVolumeAvailable) ? "speaker.slash.fill" : "speaker.wave.2.fill",
                value: Binding(get: { controls.volume }, set: { controls.setVolume($0) }),
                tint: .white,
                label: "Volume",
                enabled: controls.isVolumeAvailable && !controls.isSwitchingOutput,
                unavailableHint: controls.isSwitchingOutput ? "Switching audio output…" : (controls.audioControlsHint.isEmpty ? "Volume fixed • use device controls" : controls.audioControlsHint)
            )

            HStack(spacing: 8) {
                Button(controls.isMuted ? "Unmute" : "Mute") { controls.toggleMute() }
                    .disabled(!controls.isMuteAvailable || controls.isSwitchingOutput)
                    .accessibilityIdentifier("mute-button")

                Button("Refresh") { controls.refresh() }
                    .accessibilityIdentifier("refresh-controls-button")

                Spacer(minLength: 0)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .frame(minHeight: 28)

            Button {
                openSettings("com.apple.Sound-Settings.extension")
            } label: {
                Label("Sound Settings", systemImage: "arrow.up.forward.app")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .frame(minHeight: 28)
            .help("Open Sound Settings")
            .accessibilityLabel("Open Sound Settings")
            .accessibilityIdentifier("sound-settings-button")

            if let error = controls.outputSwitchError {
                HStack(spacing: 4) {
                    Text(error)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.red.opacity(0.85))
                        .lineLimit(2)
                        .help(error)
                    Spacer(minLength: 0)
                    Button("Dismiss") { controls.dismissOutputSwitchError() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(minHeight: 28)
                        .contentShape(Rectangle())
                }
            } else if controls.isSwitchingOutput {
                hintText("Switching audio output…")
            } else if !controls.isVolumeAvailable {
                hintText(controls.audioControlsHint.isEmpty ? "Volume fixed • use device controls" : controls.audioControlsHint)
            }
        }
    }

    private func displayPowerSection(tight: Bool) -> some View {
        section("Display & Power", symbol: "sun.max.fill", tight: tight) {
            HStack(spacing: 6) {
                compactSlider(
                    symbol: "sun.max.fill",
                    value: Binding(get: { controls.displayBrightness }, set: { controls.setDisplayBrightness($0) }),
                    tint: .yellow,
                    label: "Display",
                    enabled: controls.isDisplayBrightnessAvailable,
                    unavailableHint: controls.displayBrightnessHint
                )
                BatteryPill(snapshot: controls.battery)
            }
            if !controls.isDisplayBrightnessAvailable {
                hintText(controls.displayBrightnessHint)
            }
            KeepAwakeControl()
        }
    }

    private func hintText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.55))
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var soundOutputMenu: some View {
        let currentName = controls.currentOutputDevice?.name ?? (controls.outputDevices.isEmpty ? "No output devices" : "Sound output")
        return HStack(spacing: 7) {
            Image(systemName: controls.currentOutputDevice?.symbol ?? "speaker.wave.2.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 18)

            Menu {
                if controls.outputDevices.isEmpty {
                    Text("No Output Devices Found")
                } else {
                    ForEach(controls.outputDevices) { device in
                        Button {
                            controls.selectOutputDevice(device)
                        } label: {
                            if device.id == controls.currentOutputDeviceID {
                                Label(device.name, systemImage: "checkmark")
                            } else {
                                Text(device.name)
                            }
                        }
                        .help(device.name)
                        .accessibilityLabel(device.name)
                        .accessibilityIdentifier("audio-device-\(device.id)")
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(controls.isSwitchingOutput ? "Switching…" : currentName)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .frame(height: 28)
            .disabled(controls.isSwitchingOutput || controls.outputDevices.isEmpty)
            .help(currentName)
            .accessibilityLabel("Sound output: \(currentName)")
            .accessibilityValue(currentName)
            .accessibilityIdentifier("sound-output-menu")
        }
    }

    private func compactSlider(
        symbol: String,
        value: Binding<Double>,
        tint: Color,
        label: String,
        enabled: Bool = true,
        unavailableHint: String = "Unavailable"
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 18)
            Slider(value: value, in: 0...1)
                .controlSize(.regular)
                .tint(tint)
                .disabled(!enabled)
                .accessibilityLabel(label)
                .accessibilityValue(enabled ? "\(Int((value.wrappedValue * 100).rounded())) percent" : unavailableHint)
            Text(enabled ? "\(Int((value.wrappedValue * 100).rounded()))" : "—")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 28, alignment: .trailing)
                .contentTransition(.numericText())
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.42)
    }
}

private func openSettings(_ pane: String) {
    if let url = URL(string: "x-apple.systempreferences:\(pane)") {
        NSWorkspace.shared.open(url)
    }
}

/// Keep-awake status, mode and duration in one compact row. Observes only the toolkit store.
private struct KeepAwakeControl: View {
    @ObservedObject private var store = NotchToolkitStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: store.isKeepingAwake ? "sun.max.fill" : "moon.zzz.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(store.isKeepingAwake ? .orange : .white.opacity(0.5))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 0) {
                    Text(store.isKeepingAwake ? "Keeping awake" : "Keep Awake")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                    status
                }
                Spacer(minLength: 0)
                Menu {
                    ForEach(NotchKeepAwakeMode.allCases) { mode in
                        Button { store.updateKeepAwakeMode(mode) } label: {
                            if store.keepAwakeMode == mode {
                                Label(mode.title, systemImage: "checkmark")
                            } else {
                                Text(mode.title)
                            }
                        }
                    }
                } label: {
                    Image(systemName: store.keepAwakeMode == .mac ? "laptopcomputer" : "display")
                        .font(.system(size: 12, weight: .medium))
                        .frame(minHeight: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .frame(width: 30)
                .help(store.keepAwakeMode.title)
                .accessibilityLabel("Keep awake mode: \(store.keepAwakeMode.title)")
                .accessibilityIdentifier("keep-awake-mode-menu")
                if store.isKeepingAwake {
                    Button("Stop") { store.stopKeepingAwake() }
                        .frame(minHeight: 28)
                        .accessibilityIdentifier("keep-awake-stop")
                }
            }
            HStack(spacing: 4) {
                durationButton("30m", minutes: 30)
                durationButton("1h", minutes: 60)
                durationButton("2h", minutes: 120)
                durationButton("∞", minutes: nil)
            }
            if let error = store.keepAwakeError {
                Text(error)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .accessibilityIdentifier("keep-awake-control")
    }

    @ViewBuilder private var status: some View {
        if store.isKeepingAwake, let until = store.awakeUntil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let s = max(0, Int(ceil(until.timeIntervalSince(context.date))))
                Text(String(format: "%d:%02d:%02d left", s / 3600, s % 3600 / 60, s % 60))
                    .monospacedDigit()
            }
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.6))
        } else {
            Text(store.isKeepingAwake ? "Until stopped" : store.keepAwakeMode.title)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
        }
    }

    private func durationButton(_ title: String, minutes: Int?) -> some View {
        Button(title) { store.startKeepingAwake(minutes: minutes, mode: store.keepAwakeMode) }
            .frame(maxWidth: .infinity, minHeight: 28)
            .contentShape(Rectangle())
            .accessibilityLabel(minutes.map { "Keep awake for \($0) minutes" } ?? "Keep awake until stopped")
    }
}

/// Dictation controls. Owns its own observation so mic level updates never re-render the rest of the pane.
/// Nothing starts and no permission is requested until the user clicks Dictate.
private struct ControlsVoiceSection: View {
    let tight: Bool
    @ObservedObject private var voice = VoiceControlStore.shared

    private var status: (text: String, color: Color) {
        if let error = voice.lastError { return (error, .orange) }
        if voice.isStarting { return ("Preparing microphone…", .white.opacity(0.5)) }
        if voice.isFinishing { return ("Finishing transcription…", .white.opacity(0.5)) }
        if voice.isListening { return ("Listening…", .cyan) }
        if !voice.transcript.isEmpty { return ("Transcript ready", .mint) }
        return (voice.availability.message, .white.opacity(0.55))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Accessibility & Voice", systemImage: "waveform.and.mic")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)

            Toggle("Voice commands", isOn: $voice.isCommandModeEnabled)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .toggleStyle(.switch)
                .controlSize(.small)
                .frame(minHeight: 28)
                .help("When off, speech is kept as a transcript and never runs commands.")
                .accessibilityIdentifier("voice-command-mode-toggle")
                .disabled(voice.isListening || voice.isStarting || voice.isFinishing)

            HStack(spacing: 8) {
                if voice.isListening {
                    Button { voice.finishListening() } label: { Label(voice.isFinishing ? "Finishing…" : "Finish", systemImage: "stop.fill") }
                        .disabled(voice.isFinishing)
                } else {
                    Button { voice.start() } label: { Label(voice.isStarting ? "Starting…" : "Dictate", systemImage: "mic.fill") }
                        .disabled(voice.isStarting)
                }
                if voice.isListening || voice.isStarting {
                    Button("Cancel") { voice.stop() }
                }
                Spacer(minLength: 0)
                if voice.isListening {
                    Capsule().fill(.cyan.opacity(0.8))
                        .frame(width: 4 + 26 * CGFloat(min(1, max(0, voice.inputLevel))), height: 4)
                        .animation(.easeOut(duration: 0.1), value: voice.inputLevel)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .frame(minHeight: 28)
            .accessibilityIdentifier("voice-dictate-button")

            let s = status
            Text(voice.transcript.isEmpty ? s.text : voice.transcript)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(voice.transcript.isEmpty ? s.color : .white.opacity(0.8))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Button("Copy") { ClipboardStore.shared.copy(voice.transcript) }
                    .disabled(voice.transcript.isEmpty)
                    .lineLimit(1)
                Button("Clear") { voice.clear() }
                    .disabled(voice.transcript.isEmpty)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button { openSettings("com.apple.Accessibility-Settings.extension") } label: {
                    Label("Accessibility", systemImage: "arrow.up.forward.app")
                        .lineLimit(1)
                }
                .help("Open Accessibility Settings")
                .accessibilityLabel("Open Accessibility Settings")
                Button { openSettings("com.apple.Keyboard-Settings.extension") } label: {
                    Label("Dictation", systemImage: "arrow.up.forward.app")
                        .lineLimit(1)
                }
                .help("Open Keyboard and Dictation Settings")
                .accessibilityLabel("Open Keyboard & Dictation Settings")
                Button {} label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.borderless)
                .help("Notch follows Reduce Motion and Reduce Transparency. VoiceOver, Zoom and display filters have no public app API; change them in Settings.")
                .accessibilityLabel("About accessibility support")
                .accessibilityHint("Notch follows Reduce Motion and Reduce Transparency. VoiceOver, Zoom and display filters have no public app API; change them in Settings.")
                .frame(minWidth: 28, minHeight: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .frame(minHeight: 28)
        }
        .padding(tight ? 6 : 8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onDisappear { if voice.isListening || voice.isStarting { voice.stop() } }
        .onAppear(perform: configureVoiceCommands)
        .accessibilityIdentifier("voice-controls-section")
    }

    private func configureVoiceCommands() {
        voice.preflightCommand = { command in
            let model = NotchModel.shared
            let music = NowPlayingMonitor.shared
            let focus = FocusTimerStore.shared
            switch command {
            case .play, .pause, .next, .previous:
                guard music.song.hasTrack else { return "No active music track is available." }
                if command == .play && music.song.isPlaying { return "Music is already playing." }
                if command == .pause && !music.song.isPlaying { return "Music is already paused." }
            case .openShelf:
                guard model.showShelf else { return "Shelf is turned off in Settings." }
            case .openCalendar:
                guard model.showCalendar else { return "Calendar is turned off in Settings." }
            case .pauseFocus:
                guard focus.isRunning else { return "The focus timer is not running." }
            case .resumeFocus:
                guard !focus.isRunning, focus.remainingSeconds > 0 else { return "There is no paused focus timer to resume." }
            case .resetFocus:
                guard focus.durationSeconds > 0 else { return "There is no focus timer to reset." }
            case .openControls, .openMirror, .startFocus:
                break
            }
            return nil
        }
        voice.onCommand = { command in
            let model = NotchModel.shared
            let music = NowPlayingMonitor.shared
            let focus = FocusTimerStore.shared
            switch command {
            case .play:
                if !music.song.isPlaying { music.playPause() }
            case .pause:
                if music.song.isPlaying { music.playPause() }
            case .next:
                music.nextTrack()
            case .previous:
                music.previousTrack()
            case .openShelf:
                model.select(.shelf)
            case .openCalendar:
                model.select(.calendar)
            case .openControls:
                model.select(.controls)
                SystemControlCenter.shared.refresh()
            case .openMirror:
                model.select(.mirror)
            case .startFocus(let minutes):
                focus.start(minutes: minutes)
            case .pauseFocus:
                focus.pause()
            case .resumeFocus:
                focus.resume()
            case .resetFocus:
                focus.reset()
            }
        }
    }
}
