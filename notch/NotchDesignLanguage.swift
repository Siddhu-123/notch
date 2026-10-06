import SwiftUI
import Combine

enum WorkspaceSection: String, CaseIterable, Identifiable {
    case focus, calls
    var id: String { rawValue }
    var title: String {
        switch self {
        case .calls: return "Call tools"
        default: return rawValue.capitalized
        }
    }
    var symbol: String {
        switch self {
        case .focus: return "timer"
        case .calls: return "phone.fill"
        }
    }
    var tint: Color {
        switch self {
        case .focus: return .mint
        case .calls: return .green
        }
    }
}

enum NotchMotion {
    static let expand = Animation.spring(response: 0.36, dampingFraction: 0.86)
    static let collapse = Animation.spring(response: 0.28, dampingFraction: 0.92)
    static let press = Animation.easeOut(duration: 0.14)
    static let content = Animation.smooth(duration: 0.22)
    static func transition(direction: Int, reduced: Bool) -> AnyTransition {
        reduced ? .opacity : .asymmetric(
            insertion: .offset(x: CGFloat(direction) * 12).combined(with: .opacity),
            removal: .offset(x: CGFloat(direction) * -8).combined(with: .opacity))
    }
}

@MainActor
final class NotchDesignPreferences: ObservableObject {
    static let shared = NotchDesignPreferences()
    private let defaults: UserDefaults
    @Published var festiveLights: Bool { didSet { defaults.set(festiveLights, forKey: "design.festiveLights") } }
    @Published var dropPaw: Bool { didSet { defaults.set(dropPaw, forKey: "design.dropPaw") } }
    @Published var assistantActivity: Bool { didSet { defaults.set(assistantActivity, forKey: "design.assistantActivity") } }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        festiveLights = defaults.object(forKey: "design.festiveLights") as? Bool ?? false
        dropPaw = defaults.object(forKey: "design.dropPaw") as? Bool ?? true
        assistantActivity = defaults.object(forKey: "design.assistantActivity") as? Bool ?? true
    }
}

private struct NotchCard: ViewModifier {
    var tint: Color
    func body(content: Content) -> some View {
        content.padding(10)
            .background(tint.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.085), lineWidth: 0.7))
    }
}

extension View {
    func notchCard(tint: Color = .white) -> some View { modifier(NotchCard(tint: tint)) }
}

struct WorkspacePill: View {
    let title: String
    let symbol: String
    var tint: Color = .mint
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(tint.opacity(0.10), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(TactileButtonStyle())
    }
}

struct ActivityOrb: View {
    var active: Bool
    var waiting = false
    var level: CGFloat = 0
    var symbol = "sparkles"
    var diameter: CGFloat = 54
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.25, paused: reduceMotion || !active)) { context in
            let wave = reduceMotion || !active ? 0 : sin(context.date.timeIntervalSinceReferenceDate * 2) * 0.035
            ZStack {
                Circle().fill(AngularGradient(colors: [.mint, .blue, .purple, .mint], center: .center))
                    .blur(radius: 9).opacity(active ? 0.55 : 0.18)
                Circle().fill(.black)
                Circle().stroke(AngularGradient(colors: waiting ? [.orange, .pink, .orange] : [.mint, .blue, .purple, .mint], center: .center), lineWidth: 2)
                Image(systemName: symbol).font(.system(size: min(19, diameter * 0.35), weight: .medium))
                    .foregroundStyle(waiting ? .orange : .mint)
            }
            .scaleEffect(reduceMotion ? 1 : 1 + wave + min(max(level, 0), 1) * 0.08)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }
}

struct FestiveNotchLights: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.5, paused: reduceMotion)) { context in
        HStack(spacing: 8) {
            ForEach(0..<7) { index in
                Circle().fill([Color.mint, .pink, .orange, .blue][index % 4])
                    .frame(width: 3, height: 3)
                    .shadow(color: [Color.mint, .pink, .orange, .blue][index % 4], radius: 4)
                    .opacity(reduceMotion ? 1 : 0.75 + sin(context.date.timeIntervalSinceReferenceDate + Double(index)) * 0.25)
            }
        }
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct WorkspaceSettingsSection: View {
    @ObservedObject private var preferences = NotchDesignPreferences.shared
    @ObservedObject private var clipboard = ClipboardStore.shared
    @ObservedObject private var calls = CallCompanionStore.shared
    var body: some View {
        Section("Workspace") {
            Toggle("Clipboard history", isOn: Binding(get: { clipboard.monitoringEnabled }, set: clipboard.setMonitoringEnabled))
                .accessibilityIdentifier("settings-clipboard-history")
            Text("History is local. Capture stays off until you enable it; concealed clipboard items are skipped. Pinned snippets survive Clear history.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Call app", selection: Binding(get: { calls.selectedProvider }, set: calls.selectProvider)) {
                Text("Choose an app").tag(Optional<CallProvider>.none)
                ForEach(calls.options) { option in
                    Text(option.name).tag(Optional(option.provider))
                }
                if let selected = calls.selectedProvider, !calls.options.contains(where: { $0.provider == selected }) {
                    Text("\(selected.displayName) (not installed)").tag(Optional(selected)).disabled(true)
                }
            }
            Text("Voice starts only when you press Start. Speech is processed on this Mac. Use your call app for individual call mute and hang-up.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { calls.refresh() }
        Section("Companions & effects") {
            Toggle("Festive lights", isOn: $preferences.festiveLights).accessibilityIdentifier("settings-festive-lights")
            Toggle("Paw when dropping files", isOn: $preferences.dropPaw).accessibilityIdentifier("settings-drop-paw")
            Toggle("Assistant activity badge", isOn: $preferences.assistantActivity).accessibilityIdentifier("settings-assistant-activity")
            Text("Animations follow the macOS Reduce Motion setting.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
