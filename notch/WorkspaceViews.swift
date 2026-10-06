import SwiftUI
import AppKit

private enum ShelfSection: String, CaseIterable, Identifiable {
    case files, clipboard, folders
    var id: String { rawValue }
}

struct ShelfWorkspaceView: View {
    @ObservedObject var shelf: ShelfStore
    @State private var section: ShelfSection = .files
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(spacing: 9) {
            HStack {
                Picker("Shelf section", selection: $section) {
                    ForEach(ShelfSection.allCases) { Text($0.rawValue.capitalized).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 240)
                Spacer()
                Text(section == .files ? "Drop · keep · share" : section == .clipboard ? "Private, local text" : "Your chosen folders")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Group {
                switch section {
                case .files: IntegratedShelfView(store: shelf)
                case .clipboard: ClipboardWorkspaceView()
                case .folders: FolderWorkspaceView()
                }
            }
            .id(section).frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
        }
        .animation(reduceMotion ? nil : NotchMotion.content, value: section)
        .accessibilityIdentifier("shelf-panel")
    }
}

struct ClipboardWorkspaceView: View {
    var compact = false
    @ObservedObject private var store = ClipboardStore.shared
    @State private var query = ""
    @State private var snippet = ""
    private var entries: [ClipboardEntry] {
        store.history.filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) }
            .sorted { $0.isPinned != $1.isPinned ? $0.isPinned : $0.createdAt > $1.createdAt }
    }
    var body: some View {
        if compact {
            compactBody
        } else {
            standardBody
        }
    }

    private var standardBody: some View {
        HStack(alignment: .top, spacing: 10) {
            ScrollView {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Label("Clipboard", systemImage: "doc.on.clipboard").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Toggle("Remember copies", isOn: Binding(get: { store.monitoringEnabled }, set: store.setMonitoringEnabled))
                        .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                }
                Text(store.monitoringEnabled ? "History on · local text" : "Capture off · local text")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    WorkspacePill(title: "Capture", symbol: "plus") { store.captureCurrent() }
                    Button("Clear history") { store.clearHistory() }.controlSize(.mini)
                }
                HStack(spacing: 4) {
                    TextField("Write a snippet", text: $snippet)
                        .textFieldStyle(.roundedBorder).font(.system(size: 11)).onSubmit(addSnippet)
                        .accessibilityIdentifier("clipboard-snippet-input")
                    Button(action: addSnippet) { Image(systemName: "plus.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.cyan).accessibilityLabel("Add snippet")
                        .disabled(snippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            }.frame(width: 210).frame(maxHeight: .infinity, alignment: .top).notchCard(tint: .cyan)
            VStack(spacing: 5) {
                TextField("Search history", text: $query).textFieldStyle(.roundedBorder)
                    .font(.system(size: 11)).accessibilityIdentifier("clipboard-search")
                ScrollView {
                    LazyVStack(spacing: 5) {
                        if entries.isEmpty {
                            Text(query.isEmpty ? "Capture a copy or add a snippet." : "No matching text.")
                                .font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 16)
                        }
                        ForEach(entries) { entry in
                            HStack(spacing: 6) {
                                Button { store.copy(entry.text) } label: {
                                    Text(entry.title).font(.system(size: 11)).lineLimit(2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(.plain).help("Copy text")
                                Button { store.togglePin(entry.id) } label: {
                                    Image(systemName: entry.isPinned ? "pin.fill" : "pin")
                                        .foregroundStyle(entry.isPinned ? .cyan : .secondary)
                                }.buttonStyle(.plain).accessibilityLabel(entry.isPinned ? "Unpin snippet" : "Pin snippet")
                                Button { store.remove(entry.id) } label: { Image(systemName: "xmark") }
                                    .buttonStyle(.plain).accessibilityLabel("Remove snippet")
                            }
                            .padding(8).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
                        }
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.accessibilityIdentifier("clipboard-panel")
    }

    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 7) {
            TextField("Search history", text: $query)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 10))
                .accessibilityIdentifier("clipboard-search")

            HStack(spacing: 6) {
                Toggle("Remember copies", isOn: Binding(get: { store.monitoringEnabled }, set: store.setMonitoringEnabled))
                    .toggleStyle(.switch).controlSize(.mini)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .accessibilityIdentifier("clipboard-monitor-toggle")
                Spacer(minLength: 0)
                Button { store.captureCurrent() } label: { Image(systemName: "plus") }
                    .buttonStyle(.bordered).controlSize(.mini)
                    .help("Capture current clipboard text")
                    .accessibilityLabel("Capture current clipboard text")
                    .accessibilityIdentifier("clipboard-capture")
            }

            HStack(spacing: 5) {
                TextField("Write a snippet", text: $snippet)
                    .textFieldStyle(.roundedBorder).font(.system(size: 10)).onSubmit(addSnippet)
                    .accessibilityIdentifier("clipboard-snippet-input")
                Button(action: addSnippet) { Image(systemName: "plus.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.cyan).accessibilityLabel("Add snippet")
                    .disabled(snippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Clear") { store.clearHistory() }
                    .controlSize(.mini).accessibilityIdentifier("clipboard-clear-history")
            }

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 4) {
                    if entries.isEmpty {
                        Text(query.isEmpty ? "Capture a copy or add a snippet." : "No matching text.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
                    }
                    ForEach(entries) { entry in
                        HStack(spacing: 5) {
                            Button { store.copy(entry.text) } label: {
                                Text(entry.title).font(.system(size: 10)).lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain).help("Copy text")
                            Button { store.togglePin(entry.id) } label: {
                                Image(systemName: entry.isPinned ? "pin.fill" : "pin")
                                    .foregroundStyle(entry.isPinned ? .cyan : .secondary)
                            }.buttonStyle(.plain).accessibilityLabel(entry.isPinned ? "Unpin snippet" : "Pin snippet")
                            Button { store.remove(entry.id) } label: { Image(systemName: "xmark") }
                                .buttonStyle(.plain).accessibilityLabel("Remove snippet")
                        }
                        .padding(5).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
                    }
                }
            }
        }
        .accessibilityIdentifier("clipboard-panel-compact")
    }
    private func addSnippet() {
        guard !snippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        store.addSnippet(text: snippet)
        snippet = ""
    }
}

struct FolderWorkspaceView: View {
    var compact = false
    @ObservedObject private var store = FolderBrowserStore.shared
    var body: some View {
        if compact {
            compactBody
        } else {
            standardBody
        }
    }

    private var standardBody: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(store.folders) { folder in
                        if let url = folder.url {
                            Button(url.lastPathComponent) { store.selectFolder(url) }
                            Button("Remove \(url.lastPathComponent)", role: .destructive) { store.removeFolder(folder.id) }
                        }
                    }
                } label: { Label(store.selectedFolder?.lastPathComponent ?? "Folders", systemImage: "folder.fill").lineLimit(1) }
                .font(.system(size: 12, weight: .semibold))
                Spacer()
                WorkspacePill(title: "Choose", symbol: "folder.badge.plus", tint: .cyan) { store.chooseFolder() }
                Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).accessibilityLabel("Refresh folder")
            }
            if let error = store.lastError { Text(error).font(.system(size: 10)).foregroundStyle(.orange) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    if store.visibleChildren.isEmpty {
                        Text(store.selectedFolder == nil ? "Choose a folder to keep it close. Only its immediate contents are shown." : "This folder has no visible items.")
                            .font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 16)
                    }
                    ForEach(store.visibleChildren) { file in
                        HStack(spacing: 8) {
                            Image(systemName: file.isDirectory ? "folder.fill" : "doc.fill")
                                .foregroundStyle(file.isDirectory ? .cyan : .secondary)
                            Button { store.open(file.id) } label: {
                                Text(file.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain)
                            Text(file.isDirectory ? "Folder" : file.id.pathExtension.uppercased()).foregroundStyle(.secondary)
                            Button { store.reveal(file.id) } label: { Image(systemName: "arrow.up.forward.square") }
                                .buttonStyle(.plain).accessibilityLabel("Reveal \(file.name) in Finder")
                        }
                        .font(.system(size: 11)).padding(7)
                        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
                        .contextMenu {
                            Button("Open") { store.open(file.id) }
                            Button("Show in Finder") { store.reveal(file.id) }
                        }
                    }
                }
            }
        }.accessibilityIdentifier("folders-panel")
    }

    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 7) {
            Menu {
                ForEach(store.folders) { folder in
                    if let url = folder.url {
                        Button(url.lastPathComponent) { store.selectFolder(url) }
                        Button("Remove \(url.lastPathComponent)", role: .destructive) { store.removeFolder(folder.id) }
                    }
                }
            } label: {
                Label(store.selectedFolder?.lastPathComponent ?? "Choose a folder", systemImage: "folder.fill")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("Select saved folder")

            HStack(spacing: 7) {
                Button { store.chooseFolder() } label: { Label("Choose", systemImage: "folder.badge.plus") }
                    .controlSize(.mini).accessibilityIdentifier("folders-choose")
                Spacer(minLength: 0)
                Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).accessibilityLabel("Refresh folder")
            }

            if let error = store.lastError {
                Text(error).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(2)
            }
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if store.visibleChildren.isEmpty {
                        Text(store.selectedFolder == nil ? "Choose a folder to keep it close." : "This folder has no visible items.")
                            .font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 5)
                    }
                    ForEach(store.visibleChildren) { file in
                        HStack(spacing: 5) {
                            Image(systemName: file.isDirectory ? "folder.fill" : "doc.fill")
                                .foregroundStyle(file.isDirectory ? .cyan : .secondary)
                            Button { store.open(file.id) } label: {
                                Text(file.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain).help("Open \(file.name)")
                            Button { store.reveal(file.id) } label: { Image(systemName: "arrow.up.forward.square") }
                                .buttonStyle(.plain).accessibilityLabel("Reveal \(file.name) in Finder")
                        }
                        .font(.system(size: 10)).padding(5)
                        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                        .contextMenu {
                            Button("Open") { store.open(file.id) }
                            Button("Show in Finder") { store.reveal(file.id) }
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("folders-panel-compact")
    }
}

struct WorkspaceView: View {
    @ObservedObject var model: NotchModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch model.workspaceSection {
            case .focus: FocusWorkspaceView()
            case .calls: CallsWorkspaceView()
            }
        }
        .id(model.workspaceSection).frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
        .animation(reduceMotion ? nil : NotchMotion.content, value: model.workspaceSection)
        .accessibilityIdentifier("workspace-panel")
    }
}

private struct WorkspaceActionButton: View {
    let title: String
    let symbol: String?
    let tint: Color
    let minHeight: CGFloat
    let action: () -> Void
    @State private var isHovered = false

    init(_ title: String, symbol: String? = nil, tint: Color = .mint, minHeight: CGFloat = 32, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.minHeight = minHeight
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Group {
                if let symbol {
                    Label(title, systemImage: symbol)
                } else {
                    Text(title)
                }
            }
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 10)
            .frame(minHeight: minHeight)
            .contentShape(Capsule())
        }
        .buttonStyle(WorkspaceCapsuleButtonStyle(tint: tint, isHovered: isHovered))
        .onHover { isHovered = $0 }
    }
}

private struct WorkspaceCapsuleButtonStyle: ButtonStyle {
    let tint: Color
    let isHovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(tint)
            .background(
                Capsule()
                    .fill(tint.opacity(configuration.isPressed ? 0.25 : isHovered ? 0.18 : 0.10))
            )
            .overlay(Capsule().stroke(tint.opacity(configuration.isPressed || isHovered ? 0.42 : 0.18), lineWidth: 0.7))
            .contentShape(Capsule())
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

struct FocusWorkspaceView: View {
    @ObservedObject private var timer = FocusTimerStore.shared
    @State private var minutes = 25
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var activeSessionDurationMinutes: Int {
        max(1, Int((timer.durationSeconds / 60).rounded()))
    }

    private var sessionStatusText: String {
        if timer.isFinished {
            return "Complete"
        } else if timer.isRunning {
            return "Focusing"
        } else if timer.durationSeconds > 0 {
            return "Paused"
        } else {
            return "Ready"
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 145
            let ringSize = min(compact ? 88 : 100, max(68, geometry.size.height - 12))
            HStack(spacing: compact ? 12 : 18) {
                ZStack {
                    Circle().stroke(.white.opacity(0.08), lineWidth: 4)
                    Circle().trim(from: 0, to: timer.progress).stroke(.mint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 3) {
                        Text(timer.durationSeconds > 0 ? timer.formattedRemaining : String(format: "%02d:00", minutes))
                            .font(.system(size: compact ? 21 : 25, weight: .semibold, design: .rounded)).monospacedDigit()
                            .contentTransition(.numericText()).accessibilityIdentifier("focus-clock")
                        Text(sessionStatusText).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: ringSize, height: ringSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(reduceMotion ? nil : NotchMotion.content, value: timer.progress)

                VStack(alignment: .leading, spacing: compact ? 5 : 8) {
                    Text(timer.isFinished ? "A little breathing room." : "One thing at a time.")
                        .font(.system(size: compact ? 12 : 13, weight: .semibold))
                        .foregroundStyle(.primary).lineLimit(1)

                    if timer.durationSeconds == 0 || timer.isFinished {
                        HStack(spacing: 5) {
                            ForEach([1, 15, 25, 45], id: \.self) { value in
                                WorkspaceActionButton("\(value)m", tint: minutes == value ? .mint : .gray, minHeight: 32) {
                                    minutes = value
                                }
                                .accessibilityLabel("\(value) minute focus")
                                .accessibilityAddTraits(minutes == value ? .isSelected : [])
                            }
                        }
                    } else {
                        HStack(spacing: 6) {
                            Label("\(activeSessionDurationMinutes)m session", systemImage: "clock")
                                .font(.system(size: 11, weight: .medium)).foregroundStyle(.mint)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Color.mint.opacity(0.12), in: Capsule())
                            Text(timer.isRunning ? "in progress" : "paused")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }

                    HStack(spacing: 8) {
                        if timer.isRunning {
                            WorkspaceActionButton("Pause", symbol: "pause.fill") { timer.pause() }
                        } else if timer.remainingSeconds > 0 {
                            WorkspaceActionButton("Resume", symbol: "play.fill") { timer.resume() }
                        } else {
                            WorkspaceActionButton("Start focus", symbol: "play.fill") { timer.start(minutes: minutes) }
                        }
                        WorkspaceActionButton("Reset", minHeight: 32) { timer.reset() }
                            .disabled(timer.durationSeconds == 0)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(maxHeight: .infinity)
            }
            .padding(.horizontal, compact ? 8 : 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .notchCard(tint: .mint)
        .accessibilityIdentifier("focus-panel")
    }
}

struct CallsWorkspaceView: View {
    @ObservedObject private var calls = CallCompanionStore.shared

    private var launcherTitle: String {
        if let provider = calls.selectedProvider {
            return "Open \(provider.displayName)"
        }
        return "Choose a call app"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("Call app", selection: Binding(get: { calls.selectedProvider }, set: calls.selectProvider)) {
                        Text("Choose an app").tag(Optional<CallProvider>.none)
                        ForEach(calls.options) { option in
                            Text(option.name).tag(Optional(option.provider))
                        }
                        if let selected = calls.selectedProvider, !calls.options.contains(where: { $0.provider == selected }) {
                            Text("\(selected.displayName) (not installed)").tag(Optional(selected)).disabled(true)
                        }
                    }.frame(width: 220)
                    Spacer()
                    Text(calls.selectedOption?.isRunning == true ? "App running" : calls.selectedOption == nil ? "Select an installed app" : "App closed")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    WorkspaceActionButton("Refresh", symbol: "arrow.clockwise", tint: .secondary) {
                        calls.refresh()
                        calls.refreshMicrophone()
                    }.accessibilityLabel("Refresh call controls")
                }
                HStack(spacing: 8) {
                    WorkspaceActionButton(launcherTitle, symbol: "phone.fill", tint: .green) { calls.openSelectedApp() }
                        .disabled(calls.selectedOption == nil)
                    WorkspaceActionButton(calls.isMicrophoneMuted ? "Unmute microphone" : "Mute microphone", symbol: calls.isMicrophoneMuted ? "mic.slash.fill" : "mic.fill", tint: .orange) {
                        calls.setMicrophoneMuted(!calls.isMicrophoneMuted)
                    }.disabled(!calls.isMicrophoneMuteAvailable)
                }
                Text(calls.microphoneHint).font(.system(size: 10)).foregroundStyle(.secondary)
                Text("Use your call app to answer, end, or mute an individual call. Notch shows app status, not whether a call is active.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                if let error = calls.lastError { Text(error).font(.system(size: 10)).foregroundStyle(.orange) }
            }
        }
        .task {
            calls.refresh()
            calls.refreshMicrophone()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { break }
                calls.refresh()
                calls.refreshMicrophone()
            }
        }
        .accessibilityIdentifier("calls-panel")
    }
}
