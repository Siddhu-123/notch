import AppKit
import SwiftUI

extension Notification.Name {
    static let notchToolkitDisabled = Notification.Name("notch.toolkit.disabled")
}

enum NotchToolkitPage: String, CaseIterable, Identifiable {
    // Ordered by expected use: quick capture and notes first, rare upkeep last.
    case notes, capture, tools, downloads, convert, maintenance, awake
    var id: String { rawValue }
    var title: String {
        switch self {
        case .notes: return "Scratchpad"
        case .capture: return "Capture"
        case .tools: return "Tools"
        case .downloads: return "Downloads"
        case .convert: return "Convert"
        case .maintenance: return "Maintenance"
        case .awake: return "Keep Awake"
        }
    }
    var symbol: String {
        switch self {
        case .notes: return "square.and.pencil"
        case .capture: return "camera.viewfinder"
        case .tools: return "square.grid.2x2.fill"
        case .downloads: return "arrow.down.circle.fill"
        case .convert: return "arrow.triangle.2.circlepath"
        case .maintenance: return "wrench.and.screwdriver.fill"
        case .awake: return "cup.and.saucer.fill"
        }
    }
    /// The feature switch that hides this page, if any.
    var feature: NotchFeature? {
        switch self {
        case .capture: return .capture
        case .tools: return .quickToggles
        case .downloads: return .downloadsPage
        case .convert: return .mediaTools
        case .maintenance: return .maintenance
        case .notes, .awake: return nil
        }
    }
    static var visible: [NotchToolkitPage] {
        allCases.filter { $0 != .awake && ($0.feature.map { NotchFeatureRegistry.isEnabled($0) } ?? true) }
    }
}

struct NotchToolkitView: View {
    let page: NotchToolkitPage
    @ObservedObject private var store = NotchToolkitStore.shared
    @State private var customAwakeMinutes = "45"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            pageStrip
            Group {
                switch page {
                case .notes: scratchpad
                case .capture: CaptureToolView()
                case .tools: QuickToolsView()
                case .downloads: DownloadsToolView()
                case .convert: MediaToolsView()
                case .maintenance: MaintenanceToolView()
                case .awake: keepAwake
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .foregroundStyle(.white)
        .onAppear { store.enabled = true }
        .accessibilityIdentifier("toolkit-\(page.rawValue)-panel")
    }

    /// One row of large page buttons so every tool is one click from any other.
    private var pageStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(NotchToolkitPage.visible) { item in
                    Button { NotchModel.shared.openTool(item) } label: {
                        Label(item.title, systemImage: item.symbol)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 10)
                            .frame(minHeight: 28)
                            .background(.white.opacity(item == page ? 0.16 : 0.05), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(item == page ? 1 : 0.7))
                    .accessibilityIdentifier("toolkit-page-\(item.rawValue)")
                }
            }
        }
    }

    private var scratchpad: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $store.scratchpadText)
                    .font(.system(size: 13)).scrollContentBackground(.hidden)
                    .padding(6).accessibilityIdentifier("toolkit-scratchpad-editor")
                    .disabled(!store.canSaveScratchpad)
                if store.scratchpadText.isEmpty {
                    Text("A thought, a list, something to remember…")
                        .font(.system(size: 13)).foregroundStyle(.white.opacity(0.3))
                        .padding(.horizontal, 11).padding(.top, 14)
                        .allowsHitTesting(false)
                }
            }
            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.07)))
            HStack {
                Text(store.canSaveScratchpad ? "Saved automatically" : "Saved note could not be read. Original data kept.")
                    .font(.system(size: 10)).foregroundStyle(store.canSaveScratchpad ? Color.secondary : .orange)
                Spacer()
                Button("Copy note") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(store.scratchpadText, forType: .string)
                }
                .controlSize(.small).disabled(store.scratchpadText.isEmpty)
                .accessibilityIdentifier("toolkit-copy-note")
            }
        }
    }

    private var keepAwake: some View {
        GeometryReader { geometry in
            VStack(spacing: 6) {
                awakeStatusAndMode
                if geometry.size.width >= 480 {
                    HStack(alignment: .top, spacing: 8) {
                        ScrollView { awakeModeControls }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        ScrollView { awakeDurationControls }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            awakeModeControls
                            awakeDurationControls
                        }
                    }
                }
            }
            .scrollIndicators(.automatic)
        }
    }

    private var awakeStatusAndMode: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 8) {
                Image(systemName: store.isKeepingAwake ? "sun.max.fill" : "moon.zzz.fill")
                    .font(.system(size: 18)).foregroundStyle(store.isKeepingAwake ? .orange : .gray)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.isKeepingAwake ? "Keeping awake" : "Sleep normally")
                        .font(.system(size: 13, weight: .semibold))
                    if store.isKeepingAwake, let until = store.awakeUntil {
                        let seconds = max(0, Int(ceil(until.timeIntervalSince(context.date))))
                        Text("\(countdownText(seconds)) remaining")
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    } else if store.isKeepingAwake {
                        Text("Until stopped").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    } else {
                        Text("Mode: \(store.keepAwakeMode.title)").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    if store.isKeepingAwake {
                        Text(store.keepAwakeMode.title).font(.system(size: 10, weight: .medium)).foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 0)
                Button("Stop") { store.stopKeepingAwake() }
                    .buttonStyle(.bordered).controlSize(.regular).frame(minHeight: 30)
                    .disabled(!store.isKeepingAwake)
                    .accessibilityIdentifier("toolkit-awake-stop")
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityIdentifier("toolkit-awake-status")
        }
    }

    private var awakeModeControls: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Mode").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            ForEach(NotchKeepAwakeMode.allCases) { mode in
                Button { store.updateKeepAwakeMode(mode) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: store.keepAwakeMode == mode ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(store.keepAwakeMode == mode ? .orange : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.title).font(.system(size: 10, weight: .medium))
                            Text(mode.detail).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).padding(.horizontal, 6)
                .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
                .accessibilityIdentifier(mode == .mac ? "toolkit-awake-mode-mac" : "toolkit-awake-mode-display")
            }
        }
    }

    private var awakeDurationControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Duration")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) {
                    awakeDurationButton("15m", minutes: 15, id: "toolkit-awake-15")
                    awakeDurationButton("30m", minutes: 30, id: "toolkit-awake-30")
                    awakeDurationButton("1h", minutes: 60, id: "toolkit-awake-60")
                    awakeDurationButton("2h", minutes: 120, id: "toolkit-awake-120")
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 4) {
                    awakeDurationButton("15 min", minutes: 15, id: "toolkit-awake-15")
                    awakeDurationButton("30 min", minutes: 30, id: "toolkit-awake-30")
                    awakeDurationButton("1 hour", minutes: 60, id: "toolkit-awake-60")
                    awakeDurationButton("2 hours", minutes: 120, id: "toolkit-awake-120")
                }
            }
            HStack(spacing: 7) {
                TextField("1–240", text: $customAwakeMinutes)
                    .textFieldStyle(.roundedBorder).frame(minWidth: 56, maxWidth: 88)
                    .font(.system(size: 12, design: .monospaced))
                    .accessibilityIdentifier("toolkit-awake-custom-minutes")
                Text("minutes").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Start") {
                    guard let value = Int(customAwakeMinutes) else {
                        store.startKeepingAwake(minutes: 0, mode: store.keepAwakeMode)
                        return
                    }
                    store.startKeepingAwake(minutes: value, mode: store.keepAwakeMode)
                }
                .buttonStyle(.bordered).controlSize(.regular).frame(minHeight: 30)
                .accessibilityIdentifier("toolkit-awake-custom-start")
            }
            Button("Until stopped") {
                store.startKeepingAwake(minutes: nil, mode: store.keepAwakeMode)
            }
            .buttonStyle(.bordered).controlSize(.regular).frame(maxWidth: .infinity, minHeight: 30)
            .accessibilityIdentifier("toolkit-awake-until-stopped")
            if let error = store.keepAwakeError {
                Text(error).font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("toolkit-awake-error")
            }
            Text("Custom durations: 1–240 minutes.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private func awakeDurationButton(_ title: String, minutes: Int, id: String) -> some View {
        Button(title) { store.startKeepingAwake(minutes: minutes, mode: store.keepAwakeMode) }
            .buttonStyle(.bordered).controlSize(.regular).frame(maxWidth: .infinity, minHeight: 30)
            .accessibilityIdentifier(id)
    }

    private func countdownText(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remainder = seconds % 60
        if hours > 0 { return "\(hours)h \(minutes)m \(remainder)s" }
        return "\(minutes)m \(remainder)s"
    }
}
