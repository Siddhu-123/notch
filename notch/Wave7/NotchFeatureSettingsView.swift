import SwiftUI

/// Settings › Features: a sidebar of groups, most-used first, each showing its job's section.
struct NotchFeatureSettingsView: View {
    @State private var group: NotchFeatureGroup = .music

    var body: some View {
        HStack(spacing: 0) {
            List(NotchFeatureGroup.allCases, selection: $group) { item in
                Text(item.title).tag(item).frame(minHeight: 24)
            }
            .listStyle(.sidebar)
            .frame(width: 170)
            Divider()
            Form { section(for: group) }
                .formStyle(.grouped)
                .id(group)
        }
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
            Section(group.title) {
                ForEach(NotchFeature.allCases.filter { $0.group == group }) { NotchFeatureToggle($0, $0.group.title) }
            }
        }
    }
}
