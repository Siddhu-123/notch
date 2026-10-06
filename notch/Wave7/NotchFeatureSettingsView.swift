import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct NotchFeatureSettingsView: View {
    @State private var destination: Destination = .overview
    @State private var searchText = ""
    @State private var featureRevision = 0
    @State private var permissionRevision = 0

    private enum Destination: Hashable, Identifiable {
        case overview, permissions, panel, backup
        case group(NotchFeatureGroup)

        static let primary: [Destination] = [.overview, .permissions, .panel, .backup]
        var id: String {
            switch self {
            case .overview: return "overview"
            case .permissions: return "permissions"
            case .panel: return "panel"
            case .backup: return "backup"
            case let .group(group): return "group-\(group.rawValue)"
            }
        }
        var title: String {
            switch self {
            case .overview: return String(localized: "Overview")
            case .permissions: return String(localized: "Permissions")
            case .panel: return String(localized: "Panel")
            case .backup: return String(localized: "Backup")
            case let .group(group): return group.localizedTitle
            }
        }
        var symbol: String {
            switch self {
            case .overview: return "square.grid.2x2"
            case .permissions: return "lock.shield"
            case .panel: return "rectangle.topthird.inset.filled"
            case .backup: return "arrow.up.arrow.down"
            case let .group(group): return group.symbol
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $destination) {
                ForEach(Destination.primary) { item in sidebarRow(item) }
                Section(String(localized: "Features")) {
                    ForEach(NotchFeatureGroup.allCases.map(Destination.group)) { item in sidebarRow(item) }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 200)
        } detail: {
            detailView
                .foregroundStyle(.white)
                .background(Color.black)
        }
        .navigationSplitViewStyle(.balanced)
        .preferredColorScheme(.dark)
        .background(Color.black)
        .onReceive(NotificationCenter.default.publisher(for: NotchFeatureRegistry.changed)) { _ in
            featureRevision += 1
        }
        .accessibilityIdentifier("feature-settings-platform")
    }

    private func sidebarRow(_ item: Destination) -> some View {
        Label(item.title, systemImage: item.symbol)
            .tag(item)
            .frame(minHeight: 28)
            .accessibilityIdentifier("feature-settings-sidebar-\(item.id)")
    }

    @ViewBuilder private var detailView: some View {
        switch destination {
        case .overview: overview
        case .permissions: permissions
        case .panel: panel
        case .backup: backup
        case let .group(group):
            Form { section(for: group) }
                .formStyle(.grouped)
                .id(group)
                .foregroundStyle(.white)
                .scrollContentBackground(.hidden)
                .background(Color.black)
        }
    }

    private var overview: some View {
        let _ = featureRevision
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(String.localizedStringWithFormat(
                        String(localized: "%lld of %lld on"),
                        Int64(NotchFeature.allCases.filter { NotchFeatureRegistry.isEnabled($0) }.count),
                        Int64(NotchFeature.allCases.count)
                    ))
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .accessibilityIdentifier("feature-settings-enabled-count")
                    Spacer()
                }
                languageNote
                ForEach(NotchFeatureGroup.allCases.filter(groupMatchesSearch)) { group in
                    let features = NotchFeature.allCases.filter { $0.group == group && featureMatchesSearch($0, group: group) }
                    if !features.isEmpty {
                        Section {
                            VStack(spacing: 1) {
                                ForEach(features) { feature in
                                    NotchFeatureToggle(feature, feature.localizedTitle, detail: feature.summary)
                                        .lineLimit(1)
                                        .padding(.horizontal, 12)
                                        .background(.white.opacity(0.05))
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        } header: {
                            HStack {
                                Text(group.localizedTitle)
                                    .font(.system(.headline, design: .rounded))
                                Spacer()
                                Button(String(localized: "Turn all off")) {
                                    for feature in NotchFeature.allCases where feature.group == group {
                                        NotchFeatureRegistry.setEnabled(feature, false)
                                    }
                                }
                                .buttonStyle(.plain)
                                .frame(minHeight: 28)
                                .contentShape(Rectangle())
                                .help(String(localized: "Turn off every feature in this group."))
                                .accessibilityIdentifier("feature-settings-turn-off-\(group.rawValue)")
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .searchable(text: $searchText, prompt: Text(String(localized: "Search features")))
        .accessibilityIdentifier("feature-settings-overview")
    }

    private var languageNote: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(String(localized: "Language"))
                    .font(.system(.headline, design: .rounded))
                Text(String(localized: "Notch follows your Mac's language (System Settings › General › Language & Region)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button(String(localized: "Open")) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.bordered)
            .frame(minHeight: 28)
            .contentShape(Rectangle())
            .help(String(localized: "Open Language & Region settings."))
            .accessibilityIdentifier("feature-settings-open-language")
        }
        .padding(12)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    private var permissions: some View {
        let _ = permissionRevision
        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(NotchPermission.allCases, id: \.rawValue) { permission in
                    permissionRow(permission)
                }
            }
            .padding(16)
        }
        .onAppear { permissionRevision += 1 }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissionRevision += 1
        }
        .accessibilityIdentifier("feature-settings-permissions")
    }

    private func permissionRow(_ permission: NotchPermission) -> some View {
        let status = NotchPermissionStatus.check(permission)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor(status))
                    .frame(width: 9, height: 9)
                    .accessibilityLabel(statusTitle(status))
                Text(permission.localizedTitle)
                    .font(.system(.headline, design: .rounded))
                Spacer(minLength: 6)
                Text(statusTitle(status))
                    .font(.caption)
                    .foregroundStyle(statusColor(status))
            }
            Text(permission.why)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(permission.features.isEmpty
                 ? String(localized: "No Wave 7 feature currently uses this permission.")
                 : permission.features.map(\.localizedTitle).joined(separator: ", "))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
            HStack {
                Spacer()
                Button(String(localized: "Open Settings")) {
                    if let url = permission.settingsURL { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(.bordered)
                .frame(minHeight: 28)
                .contentShape(Rectangle())
                .help(String(localized: "Open this permission's System Settings page."))
                .accessibilityIdentifier("feature-settings-permission-\(permission.rawValue)-settings")
            }
        }
        .padding(12)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    private func statusTitle(_ status: Bool?) -> String {
        switch status {
        case true: return String(localized: "Allowed")
        case false: return String(localized: "Not allowed")
        case nil: return String(localized: "Unknown")
        }
    }

    private func statusColor(_ status: Bool?) -> Color {
        switch status {
        case true: return .green
        case false: return .orange
        case nil: return .gray
        }
    }

    private var panel: some View {
        PanelLayoutSettingsView()
    }

    private var backup: some View {
        BackupSettingsView()
    }

    @ViewBuilder private func section(for group: NotchFeatureGroup) -> some View {
        switch group {
        case .music: MusicSettingsSection()
        case .island: IslandSettingsSection()
        case .sound: SoundSettingsSection()
        case .windows: WindowsSettingsSection()
        case .pointer: PointerSettingsSection()
        case .keys: KeyboardSettingsSection()
        case .clipboard: ClipboardSettingsSection()
        case .capture: CaptureSettingsSection()
        case .productivity: ProductivitySettingsSection()
        case .mediaTools, .maintenance:
            Section(group.localizedTitle) {
                ForEach(NotchFeature.allCases.filter { $0.group == group }) { feature in
                    NotchFeatureToggle(feature, feature.localizedTitle, detail: feature.summary)
                }
            }
        }
    }

    private func groupMatchesSearch(_ group: NotchFeatureGroup) -> Bool {
        searchText.isEmpty || group.localizedTitle.localizedCaseInsensitiveContains(searchText)
            || NotchFeature.allCases.contains { $0.group == group && featureMatchesSearch($0, group: group) }
    }

    private func featureMatchesSearch(_ feature: NotchFeature, group: NotchFeatureGroup) -> Bool {
        searchText.isEmpty || group.localizedTitle.localizedCaseInsensitiveContains(searchText)
            || feature.localizedTitle.localizedCaseInsensitiveContains(searchText)
            || feature.summary.localizedCaseInsensitiveContains(searchText)
    }
}

private extension NotchFeatureGroup {
    var symbol: String {
        switch self {
        case .music: return "music.note"
        case .island: return "waveform.path"
        case .sound: return "speaker.wave.2"
        case .windows: return "macwindow"
        case .pointer: return "cursorarrow"
        case .keys: return "keyboard"
        case .clipboard: return "doc.on.clipboard"
        case .capture: return "camera"
        case .mediaTools: return "arrow.triangle.2.circlepath"
        case .productivity: return "sparkles"
        case .maintenance: return "wrench.and.screwdriver"
        }
    }
}

private struct PanelLayoutSettingsView: View {
    @State private var pages = NotchPanelLayout.allOrdered
    @State private var hidden = NotchPanelLayout.hidden

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 7) {
                Text(String(localized: "Choose which toolkit pages appear in the notch and set their order."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
                ForEach(pages) { page in
                    HStack(spacing: 8) {
                        Image(systemName: page.symbol).frame(width: 20)
                        Text(page.localizedTitle)
                            .font(.system(.body, design: .rounded))
                        Spacer(minLength: 8)
                        Button {
                            save(NotchPanelLayout.move(page, by: -1, in: pages))
                        } label: {
                            Image(systemName: "arrow.up")
                                .frame(width: 30, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(pages.first == page)
                        .help(String(localized: "Move up"))
                        .accessibilityLabel(String(localized: "Move up"))
                        .accessibilityIdentifier("panel-page-up-\(page.rawValue)")
                        Button {
                            save(NotchPanelLayout.move(page, by: 1, in: pages))
                        } label: {
                            Image(systemName: "arrow.down")
                                .frame(width: 30, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(pages.last == page)
                        .help(String(localized: "Move down"))
                        .accessibilityLabel(String(localized: "Move down"))
                        .accessibilityIdentifier("panel-page-down-\(page.rawValue)")
                        Button {
                            let shouldHide = !hidden.contains(page.rawValue)
                            NotchPanelLayout.setHidden(shouldHide, for: page)
                            hidden = NotchPanelLayout.hidden
                        } label: {
                            Image(systemName: hidden.contains(page.rawValue) ? "eye.slash" : "eye")
                                .frame(width: 30, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(hidden.contains(page.rawValue)
                              ? String(localized: "Show this page in the notch.")
                              : String(localized: "Hide this page from the notch."))
                        .accessibilityLabel(hidden.contains(page.rawValue)
                                            ? String(localized: "Show page")
                                            : String(localized: "Hide page"))
                        .accessibilityIdentifier("panel-page-visibility-\(page.rawValue)")
                    }
                    .padding(.horizontal, 10)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(16)
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NotchPanelLayout.changed)) { _ in refresh() }
        .accessibilityIdentifier("feature-settings-panel")
    }

    private func save(_ value: [NotchToolkitPage]) {
        pages = value
        NotchPanelLayout.saveOrder(value)
    }

    private func refresh() {
        pages = NotchPanelLayout.allOrdered
        hidden = NotchPanelLayout.hidden
    }
}

private struct BackupSettingsView: View {
    @State private var result = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "Export or restore your Notch settings as a JSON file."))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button(String(localized: "Export…"), action: exportSettings)
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: 28)
                    .contentShape(Rectangle())
                    .help(String(localized: "Save your Notch settings to a JSON file."))
                    .accessibilityIdentifier("feature-settings-export")
                Button(String(localized: "Import…"), action: importSettings)
                    .buttonStyle(.bordered)
                    .frame(minHeight: 28)
                    .contentShape(Rectangle())
                    .help(String(localized: "Load Notch settings from a JSON file."))
                    .accessibilityIdentifier("feature-settings-import")
            }
            if !result.isEmpty {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("feature-settings-backup-result")
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .accessibilityIdentifier("feature-settings-backup")
    }

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Notch Settings.json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try NotchSettingsTransfer.export().write(to: url, options: .atomic)
            result = String(localized: "Settings exported.")
        } catch {
            result = String.localizedStringWithFormat(String(localized: "Export failed: %@"), error.localizedDescription)
        }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let count = try NotchSettingsTransfer.importData(Data(contentsOf: url))
            result = String.localizedStringWithFormat(String(localized: "Imported %lld settings."), Int64(count))
        } catch {
            result = String.localizedStringWithFormat(String(localized: "Import failed: %@"), error.localizedDescription)
        }
    }
}
