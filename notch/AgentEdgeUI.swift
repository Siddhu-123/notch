import AppKit
import Combine
import SwiftUI

// Left-edge agent UI: permission bubbles that slide out of the screen edge, and a notch-style
// "peek" panel that morphs out after the pointer rests on the edge. Data comes from AgentMonitor.

// MARK: - Controller

final class AgentEdgePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class AgentEdgeState: ObservableObject {
    @Published var isPeekOpen = false
    @Published var peekAnchorY: CGFloat = 300
    @Published var hoveredID: String?
}

private struct AgentHitRectsKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

private extension View {
    /// Reports this view's frame so the controller can make exactly these regions clickable.
    func agentHitRegion(_ id: String) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: AgentHitRectsKey.self, value: [id: proxy.frame(in: .named(AgentEdgeController.space))])
        })
    }
}

@MainActor
final class AgentEdgeController {
    static let space = "agentEdge"
    static let panelWidth: CGFloat = 400
    static let peekID = "peek"

    private let monitor: AgentMonitor
    private let state = AgentEdgeState()
    private let panel: AgentEdgePanel
    private var hitRects: [String: CGRect] = [:]
    private var eventMonitors: [Any] = []
    private var cancellables = Set<AnyCancellable>()
    private var dwellWorkItem: DispatchWorkItem?
    private var closeWorkItem: DispatchWorkItem?
    private var homeWorkItem: DispatchWorkItem?
    /// Pointer jumps (warps, Mission Control) send no mouseMoved, so poll while the peek is open.
    private var peekPollTimer: Timer?
    private weak var currentScreen: NSScreen?

    init(monitor: AgentMonitor = .shared) {
        self.monitor = monitor
        panel = AgentEdgePanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 600),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = true

        let root = AgentEdgeRootView(
            monitor: monitor,
            state: state,
            onHitRects: { [weak self] rects in self?.hitRects = rects },
            onShowAll: { [weak self] in self?.openPeekFromBubbles() }
        )
        panel.contentView = FirstMouseHostingView(rootView: root)
    }

    func start() {
        monitor.start()
        place(on: homeScreen)
        updatePanelVisibility()

        monitor.objectWillChange.merge(with: state.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in self?.updatePanelVisibility() }
            }
            .store(in: &cancellables)

        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.handlePointer() }
        }) { eventMonitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handlePointer() }
            return event
        }) { eventMonitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.handleOutsideClick() }
        }) { eventMonitors.append(m) }

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.closePeek()
                self.place(on: self.homeScreen)
            }
            .store(in: &cancellables)

        let rehome: (Any) -> Void = { [weak self] _ in
            guard let self else { return }
            self.closePeek()
            self.place(on: self.homeScreen)
        }
        NotchModel.shared.$displayGeometry.map(\.screenNumber).removeDuplicates()
            .receive(on: RunLoop.main)
            .sink(receiveValue: rehome)
            .store(in: &cancellables)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: RunLoop.main)
            .sink(receiveValue: rehome)
            .store(in: &cancellables)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.screensDidWakeNotification)
            .receive(on: RunLoop.main)
            .sink(receiveValue: rehome)
            .store(in: &cancellables)

        monitor.$edgePeekEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in if !enabled { self?.closePeek() } }
            .store(in: &cancellables)

        monitor.$hubAlive
            .receive(on: RunLoop.main)
            .sink { [weak self] alive in
                guard let self else { return }
                if alive {
                    self.updatePanelVisibility()
                } else {
                    self.closePeek()
                    self.panel.orderOut(nil)
                }
            }
            .store(in: &cancellables)
        if !monitor.hubAlive { panel.orderOut(nil) }
    }

    /// An empty transparent overlay has no reason to remain a visible window.
    private func updatePanelVisibility() {
        let hasContent = state.isPeekOpen
            || (monitor.bubblesEnabled && !monitor.requests.isEmpty)
            || (monitor.edgePeekEnabled && monitor.activeCount > 0)
        if monitor.hubAlive && hasContent { panel.orderFrontRegardless() }
        else { panel.orderOut(nil) }
    }

    func stop() {
        eventMonitors.forEach(NSEvent.removeMonitor)
        eventMonitors.removeAll()
        peekPollTimer?.invalidate()
        peekPollTimer = nil
        panel.orderOut(nil)
        monitor.stop()
    }

    // MARK: Placement

    private var homeScreen: NSScreen? {
        let number = NotchModel.shared.displayGeometry.screenNumber
        if number != 0, let match = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == UInt32(truncatingIfNeeded: number)
        }) { return match }
        return NSScreen.screens.first ?? NSScreen.main
    }

    private func place(on screen: NSScreen?) {
        guard let screen else { return }
        currentScreen = screen
        let visible = screen.visibleFrame
        let frame = NSRect(x: screen.frame.minX, y: visible.minY, width: Self.panelWidth, height: visible.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    /// Clickable regions in screen coordinates (SwiftUI reports them top-left based).
    private func screenRect(_ rect: CGRect) -> CGRect {
        let frame = panel.frame
        return CGRect(x: frame.minX + rect.minX, y: frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    // MARK: Pointer

    private func handlePointer() {
        let point = NSEvent.mouseLocation
        let rects = hitRects.mapValues(screenRect)

        let hovered = rects.first { $0.value.insetBy(dx: -2, dy: -2).contains(point) }?.key
        let interactive = rects.values.contains { $0.insetBy(dx: -6, dy: -6).contains(point) }
        if panel.ignoresMouseEvents == interactive { panel.ignoresMouseEvents = !interactive }
        let bubbleHover = hovered == Self.peekID ? nil : hovered
        if state.hoveredID != bubbleHover { state.hoveredID = bubbleHover }

        if state.isPeekOpen {
            trackPeekExit(point: point, peekRect: rects[Self.peekID])
        } else {
            trackEdgeDwell(point: point, overBubble: hovered != nil)
        }
    }

    private func edgeScreen(at point: NSPoint) -> NSScreen? {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) else { return nil }
        let f = screen.frame
        guard point.x <= f.minX + 1, point.y > f.minY + 48, point.y < f.maxY - 48 else { return nil }
        if screen == homeScreen { return screen }
        // Only a real edge: skip when another display continues to the left.
        let hasNeighbour = NSScreen.screens.contains { other in
            other != screen && abs(other.frame.maxX - f.minX) < 2 && other.frame.maxY > point.y && other.frame.minY < point.y
        }
        return hasNeighbour ? nil : screen
    }

    private func trackEdgeDwell(point: NSPoint, overBubble: Bool) {
        guard monitor.hubAlive, monitor.edgePeekEnabled, !overBubble, NSEvent.pressedMouseButtons == 0, edgeScreen(at: point) != nil else {
            dwellWorkItem?.cancel()
            dwellWorkItem = nil
            return
        }
        guard dwellWorkItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.dwellWorkItem = nil
            let now = NSEvent.mouseLocation
            guard NSEvent.pressedMouseButtons == 0, let screen = self.edgeScreen(at: now) else { return }
            self.openPeek(on: screen, at: now.y)
        }
        dwellWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + monitor.edgeDwell, execute: item)
    }

    private func trackPeekExit(point: NSPoint, peekRect: CGRect?) {
        let screenFrame = currentScreen?.frame ?? .zero
        let onEdge = point.x <= screenFrame.minX + 2 && abs(point.y - (peekRect?.midY ?? point.y)) < 120
        let inside = peekRect.map { $0.insetBy(dx: -18, dy: -18).contains(point) } ?? false
        if inside || onEdge {
            closeWorkItem?.cancel()
            closeWorkItem = nil
            return
        }
        guard closeWorkItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            self?.closeWorkItem = nil
            self?.closePeek()
        }
        closeWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    private func handleOutsideClick() {
        guard state.isPeekOpen else { return }
        let point = NSEvent.mouseLocation
        if let peek = hitRects[Self.peekID].map(screenRect), peek.contains(point) { return }
        closePeek()
    }

    // MARK: Peek

    private func openPeek(on screen: NSScreen, at screenY: CGFloat) {
        guard monitor.hubAlive else { return }
        homeWorkItem?.cancel()
        if screen != currentScreen { place(on: screen) }
        state.peekAnchorY = panel.frame.maxY - screenY
        state.isPeekOpen = true
        peekPollTimer?.invalidate()
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.handlePointer() }
        }
        RunLoop.main.add(timer, forMode: .common)
        peekPollTimer = timer
        if NotchModel.shared.hapticsEnabled {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    private func openPeekFromBubbles() {
        guard monitor.hubAlive, let screen = currentScreen else { return }
        openPeek(on: screen, at: NSEvent.mouseLocation.y)
    }

    private func closePeek() {
        closeWorkItem?.cancel()
        closeWorkItem = nil
        peekPollTimer?.invalidate()
        peekPollTimer = nil
        guard state.isPeekOpen else { return }
        state.isPeekOpen = false
        // Bubbles live on the primary display; go home once the morph has finished.
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.state.isPeekOpen, self.currentScreen != self.homeScreen else { return }
            self.place(on: self.homeScreen)
        }
        homeWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }
}

// MARK: - Root

struct AgentEdgeRootView: View {
    @ObservedObject var monitor: AgentMonitor
    @ObservedObject var state: AgentEdgeState
    let onHitRects: ([String: CGRect]) -> Void
    let onShowAll: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let maxBubbles = 4

    private var bubbles: [AgentRequest] {
        monitor.hubAlive && monitor.bubblesEnabled && !state.isPeekOpen ? monitor.requests : []
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                EdgeAnchorLayout(anchorY: proxy.size.height * 0.36) {
                    bubbleStack
                }

                if monitor.hubAlive && monitor.edgePeekEnabled && bubbles.isEmpty && !state.isPeekOpen && monitor.activeCount > 0 {
                    EdgeActivityHint(platforms: activePlatforms, action: onShowAll)
                        .frame(maxHeight: .infinity, alignment: .center)
                        .transition(.opacity)
                }

                EdgeAnchorLayout(anchorY: state.peekAnchorY) {
                    AgentPeekView(monitor: monitor, isOpen: state.isPeekOpen)
                        .frame(maxHeight: min(620, proxy.size.height - 16), alignment: .topLeading)
                        .agentHitRegion(AgentEdgeController.peekID)
                        .allowsHitTesting(state.isPeekOpen)
                }
                // Stay solid black while morphing (like the notch itself); only the closed sliver fades.
                .animation(state.isPeekOpen ? .easeOut(duration: 0.06) : .easeIn(duration: 0.12).delay(0.22)) {
                    $0.opacity(state.isPeekOpen ? 1 : 0)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .coordinateSpace(name: AgentEdgeController.space)
        .onPreferenceChange(AgentHitRectsKey.self) { rects in
            // A closed peek is invisible and must not swallow clicks.
            onHitRects(state.isPeekOpen ? rects : rects.filter { $0.key != AgentEdgeController.peekID })
        }
        .animation(reduceMotion ? EdgeStyle.reduced : (state.isPeekOpen ? EdgeStyle.open : EdgeStyle.close), value: state.isPeekOpen)
        .animation(reduceMotion ? EdgeStyle.reduced : EdgeStyle.arrive, value: bubbles.map(\.id))
        .animation(.smooth(duration: 0.6), value: monitor.activeCount > 0)
        .preferredColorScheme(.dark)
    }

    private var activePlatforms: [AgentPlatform] {
        var seen: [AgentPlatform] = []
        for s in monitor.sessions where s.status == .working || s.status == .waiting {
            if !seen.contains(s.platform) { seen.append(s.platform) }
        }
        if !monitor.hubJobs.isEmpty && !seen.contains(.hub) { seen.append(.hub) }
        return seen
    }

    private var bubbleStack: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(bubbles.prefix(Self.maxBubbles)) { request in
                AgentBubble(
                    request: request,
                    isHovered: state.hoveredID == request.id,
                    monitor: monitor
                )
                .agentHitRegion(request.id)
                .transition(
                    .asymmetric(
                        insertion: .blurFade(radius: 8, scale: 0.86).combined(with: .offset(x: -22)),
                        removal: .blurFade(radius: 6, scale: 0.92).combined(with: .offset(x: -14))
                    )
                )
            }
            if bubbles.count > Self.maxBubbles {
                Button(action: onShowAll) {
                    Text("+\(bubbles.count - Self.maxBubbles) more")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(.leading, 18)
                        .padding(.trailing, 12)
                        .padding(.vertical, 6 + 6)
                        .background(EdgeTabShape(cornerRadius: 12, fillet: 6).fill(.black))
                        .overlay(EdgeTabShape(cornerRadius: 12, fillet: 6).stroke(EdgeStyle.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .agentHitRegion("more")
                .transition(.blurFade(radius: 4, scale: 0.9))
            }
        }
    }
}

// MARK: - Style

/// Motion and colour tokens, tuned to feel like system chrome: near-critically-damped springs,
/// blur cross-fades rather than slides, low-chroma accents on true black.
enum EdgeStyle {
    static let open = Animation.spring(duration: 0.52, bounce: 0.12)
    static let close = Animation.spring(duration: 0.36, bounce: 0)
    static let arrive = Animation.spring(duration: 0.55, bounce: 0.1)
    static let morph = Animation.smooth(duration: 0.36)
    static let quick = Animation.smooth(duration: 0.22)
    static let reduced = Animation.easeOut(duration: 0.18)

    static let attention = Color(red: 1.0, green: 0.78, blue: 0.45)
    static let success = Color(red: 0.52, green: 0.84, blue: 0.62)
    static let failure = Color(red: 1.0, green: 0.52, blue: 0.5)
    static let hairline = Color.white.opacity(0.07)
    static let primaryText = Color.white.opacity(0.94)
    static let secondaryText = Color.white.opacity(0.58)
    static let tertiaryText = Color.white.opacity(0.38)
}

private struct BlurFade: ViewModifier {
    var radius: CGFloat
    var opacity: Double
    var scale: CGFloat

    func body(content: Content) -> some View {
        content
            .blur(radius: radius)
            .opacity(opacity)
            .scaleEffect(scale, anchor: .leading)
    }
}

extension AnyTransition {
    /// Fades through a soft blur, the way system HUDs and the Dynamic Island resolve content.
    static func blurFade(radius: CGFloat = 6, scale: CGFloat = 1) -> AnyTransition {
        .modifier(active: BlurFade(radius: radius, opacity: 0, scale: scale), identity: BlurFade(radius: 0, opacity: 1, scale: 1))
    }
}

/// Rows settle in one after another when the peek opens.
private struct StaggeredAppear: ViewModifier {
    let index: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 7)
            .blur(radius: shown || reduceMotion ? 0 : 3)
            .onAppear {
                let delay = 0.08 + Double(min(index, 8)) * 0.035
                withAnimation(reduceMotion ? EdgeStyle.reduced : .smooth(duration: 0.44).delay(delay)) { shown = true }
            }
    }
}

private extension View {
    func staggered(_ index: Int) -> some View { modifier(StaggeredAppear(index: index)) }
}

/// Places one child flush with the leading edge, vertically centred on `anchorY` but kept on screen.
struct EdgeAnchorLayout: Layout {
    var anchorY: CGFloat
    var margin: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: bounds.height - margin * 2))
            let top = min(max(anchorY - size.height / 2, margin), max(margin, bounds.height - size.height - margin))
            subview.place(at: CGPoint(x: bounds.minX, y: bounds.minY + top), anchor: .topLeading, proposal: ProposedViewSize(size))
        }
    }
}

// MARK: - Shapes

/// A notch turned on its side: flush with the left screen edge, rounded on the right, with the same
/// concave "ears" a MacBook notch has where it meets the bezel.
struct EdgeTabShape: Shape {
    var cornerRadius: CGFloat
    var fillet: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(cornerRadius, fillet) }
        set { cornerRadius = newValue.first; fillet = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let f = min(max(0, fillet), rect.width * 0.3, rect.height * 0.25)
        let body = CGRect(x: rect.minX + f, y: rect.minY + f, width: rect.width - f, height: rect.height - f * 2)
        let r = min(max(0, cornerRadius), body.height / 2, body.width / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        if f > 0.5 {
            p.addQuadCurve(to: CGPoint(x: body.minX, y: body.minY), control: CGPoint(x: body.minX, y: rect.minY))
        }
        p.addLine(to: CGPoint(x: body.maxX - r, y: body.minY))
        p.addArc(center: CGPoint(x: body.maxX - r, y: body.minY + r), radius: r, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: body.maxX, y: body.maxY - r))
        p.addArc(center: CGPoint(x: body.maxX - r, y: body.maxY - r), radius: r, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: body.minX, y: body.maxY))
        if f > 0.5 {
            p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY), control: CGPoint(x: body.minX, y: rect.maxY))
        } else {
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }
        p.closeSubpath()
        return p
    }
}

private struct EdgeSurface: View {
    var tint: Color
    var glow: Double = 0.1
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            Color.black
            if !reduceTransparency {
                // A faint top sheen and an even fainter wash of the agent's colour from the edge.
                LinearGradient(colors: [.white.opacity(0.045), .clear], startPoint: .top, endPoint: .center)
                RadialGradient(colors: [tint.opacity(glow), .clear], center: .leading, startRadius: 0, endRadius: 220)
            }
        }
    }
}

// MARK: - Bubble

struct AgentBubble: View {
    let request: AgentRequest
    let isHovered: Bool
    @ObservedObject var monitor: AgentMonitor
    @State private var settled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Prompts stay readable until answered; only "waiting for you" notes tuck away to a tab.
    private var expanded: Bool { isHovered || request.kind != .attention || !settled }
    private var showsActions: Bool { isHovered || request.canAnswer }

    var body: some View {
        let shape = EdgeTabShape(cornerRadius: expanded ? 20 : 22, fillet: 8)
        HStack(alignment: .top, spacing: 11) {
            AgentRequestIcon(request: request, size: 30)
                .padding(.top, expanded ? 1 : 0)
            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    AgentRequestContent(request: request, roomy: isHovered)
                    if showsActions {
                        VStack(alignment: .leading, spacing: 6) {
                            AgentRequestActions(request: request, monitor: monitor)
                            if isHovered {
                                Text(request.canAnswer ? "Right-click for more · double-click to open" : "Double-click to open \(appName(for: request.app, platform: request.platform))")
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(EdgeStyle.tertiaryText)
                            }
                        }
                        .transition(.blurFade(radius: 3).combined(with: .offset(y: -3)))
                    }
                }
                .frame(width: 252, alignment: .leading)
                .transition(.blurFade(radius: 4, scale: 0.96))
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, expanded ? 16 : 8)
        .padding(.vertical, expanded ? 8 + 11 : 8 + 8)
        .background(EdgeSurface(tint: request.platform.tint, glow: 0.12))
        .clipShape(shape)
        .overlay(shape.stroke(EdgeStyle.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.28), radius: 16, x: 3, y: 6)
        .contentShape(shape)
        .onTapGesture(count: 2) { monitor.respond(to: request, decision: .app) }
        .contextMenu { AgentRequestMenu(request: request, monitor: monitor) }
        .animation(reduceMotion ? EdgeStyle.reduced : EdgeStyle.morph, value: expanded)
        .animation(reduceMotion ? EdgeStyle.reduced : EdgeStyle.morph, value: isHovered)
        .animation(reduceMotion ? EdgeStyle.reduced : EdgeStyle.quick, value: showsActions)
        .task(id: request.id) {
            try? await Task.sleep(for: .seconds(7))
            settled = true
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(request.platformName): \(request.displayTitle). \(request.displayBody)")
    }
}

/// Notification-style text block shared by the edge bubble and the peek card:
/// a caption (agent · project · age), a title of up to two lines, the detail, and any answer choices.
struct AgentRequestContent: View {
    let request: AgentRequest
    /// Hovered or in the peek: allow more lines.
    var roomy: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text(request.platformName)
                    .foregroundStyle(request.platform.tint.opacity(0.95))
                if !request.project.isEmpty {
                    Text("·").foregroundStyle(EdgeStyle.tertiaryText)
                    Text(request.project)
                        .foregroundStyle(EdgeStyle.secondaryText)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 6)
                RelativeAge(date: request.createdAt)
                    .foregroundStyle(EdgeStyle.tertiaryText)
            }
            .font(.system(size: 10.5, weight: .medium))
            .lineLimit(1)

            Text(request.displayTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(EdgeStyle.primaryText)
                .lineLimit(roomy ? 5 : (request.kind == .question ? 3 : 2))
                .fixedSize(horizontal: false, vertical: true)

            if !request.displayBody.isEmpty {
                Text(request.displayBody)
                    .font(request.kind == .permission ? .system(size: 11, design: .monospaced) : .system(size: 11.5))
                    .foregroundStyle(EdgeStyle.secondaryText)
                    .lineLimit(roomy ? 6 : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !request.choices.isEmpty {
                ChipFlow(spacing: 5) {
                    ForEach(Array(request.choices.prefix(roomy ? 6 : 4).enumerated()), id: \.offset) { _, choice in
                        Text(choice)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.78))
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3.5)
                            .background(Capsule().fill(.white.opacity(0.08)))
                            .overlay(Capsule().stroke(.white.opacity(0.06), lineWidth: 1))
                    }
                }
                .padding(.top, 3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "now", "3m", "2h": compact like Notification Center.
private struct RelativeAge: View {
    let date: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(Self.format(context.date.timeIntervalSince(date)))
                .monospacedDigit()
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<60: "now"
        case ..<3600: "\(Int(seconds / 60))m"
        case ..<86_400: "\(Int(seconds / 3600))h"
        default: "\(Int(seconds / 86_400))d"
        }
    }
}

/// Left-to-right wrapping row, for answer chips.
private struct ChipFlow: Layout {
    var spacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            for (index, x, size) in row.items {
                subviews[index].place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + row.y), anchor: .topLeading, proposal: ProposedViewSize(size))
            }
        }
    }

    private struct Row { var y: CGFloat; var height: CGFloat = 0; var width: CGFloat = 0; var items: [(Int, CGFloat, CGSize)] = [] }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row(y: 0)
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            let x = row.items.isEmpty ? 0 : row.width + spacing
            if !row.items.isEmpty && x + size.width > width {
                rows.append(row)
                row = Row(y: row.y + row.height + spacing)
                row.items.append((index, 0, size))
                row.width = size.width
            } else {
                row.items.append((index, x, size))
                row.width = x + size.width
            }
            row.height = max(row.height, size.height)
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}

extension AgentRequest {
    /// Older bridges sent "Claude Code is asking" with the question in the detail.
    private var isGenericQuestion: Bool { kind == .question && title.hasSuffix(" is asking") }

    /// The title without the agent's name (the caption already says who), e.g. "Wants to run a command".
    var displayTitle: String {
        if isGenericQuestion, !detail.isEmpty { return detail }
        var text = title
        for name in [platformName, platform.displayName] where text.hasPrefix(name + " ") {
            text = String(text.dropFirst(name.count + 1))
            if text.hasPrefix("is ") { text = String(text.dropFirst(3)) }
            break
        }
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    var displayBody: String {
        if isGenericQuestion { return "" }
        if kind == .question { return detail == header && !header.contains("more") ? "" : detail }
        return detail
    }
}

struct AgentRequestIcon: View {
    let request: AgentRequest
    var size: CGFloat = 34
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if request.canAnswer && !reduceMotion {
                // A slow breath, not a siren.
                Circle()
                    .stroke(request.platform.tint.opacity(pulse ? 0 : 0.3), lineWidth: 1.5)
                    .scaleEffect(pulse ? 1.38 : 1)
            }
            Circle()
                .fill(request.platform.tint.opacity(0.16))
            Image(systemName: request.platform.symbol)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(request.platform.tint)
            if request.canAnswer, let until = request.holdUntil {
                HoldCountdownRing(start: request.createdAt, end: until, tint: request.platform.tint)
            }
            Image(systemName: kindSymbol)
                .font(.system(size: size * 0.22, weight: .bold))
                .foregroundStyle(.black.opacity(0.82))
                .frame(width: size * 0.38, height: size * 0.38)
                .background(Circle().fill(kindColor))
                .overlay(Circle().stroke(.black, lineWidth: 2))
                .offset(x: size * 0.35, y: size * 0.35)
        }
        .frame(width: size, height: size)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 2.4).repeatForever(autoreverses: false)) { pulse = true }
        }
    }

    private var kindSymbol: String {
        switch request.kind {
        case .permission: "hand.raised.fill"
        case .question: "questionmark"
        case .attention: "bell.fill"
        }
    }

    private var kindColor: Color {
        switch request.kind {
        case .permission: EdgeStyle.attention
        case .question: .white.opacity(0.92)
        case .attention: .white.opacity(0.7)
        }
    }
}

private struct HoldCountdownRing: View {
    let start: Date
    let end: Date
    let tint: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let total = max(1, end.timeIntervalSince(start))
            let remaining = min(1, max(0, end.timeIntervalSince(context.date) / total))
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.08), lineWidth: 1.8)
                Circle()
                    .trim(from: 0, to: remaining)
                    .stroke(tint.opacity(0.9), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .padding(-2.5)
        }
    }
}

struct AgentRequestActions: View {
    let request: AgentRequest
    @ObservedObject var monitor: AgentMonitor

    var body: some View {
        HStack(spacing: 6) {
            if request.canAnswer {
                AgentPillButton(title: "Deny", style: .secondary) { monitor.respond(to: request, decision: .deny) }
                if request.supportsAlways {
                    AgentPillButton(title: "Always", style: .secondary) { monitor.respond(to: request, decision: .always) }
                }
                AgentPillButton(title: "Allow", style: .primary(request.platform.tint)) { monitor.respond(to: request, decision: .allow) }
            } else {
                AgentPillButton(title: "Open \(appName(for: request.app, platform: request.platform))", style: .primary(request.platform.tint)) {
                    monitor.respond(to: request, decision: .app)
                }
                AgentPillButton(title: "Dismiss", style: .secondary) { monitor.dismiss(request) }
            }
        }
    }
}

struct AgentRequestMenu: View {
    let request: AgentRequest
    let monitor: AgentMonitor

    var body: some View {
        if request.canAnswer {
            Button("Allow once") { monitor.respond(to: request, decision: .allow) }
            if request.supportsAlways {
                Button("Always allow") { monitor.respond(to: request, decision: .always) }
            }
            Button("Deny") { monitor.respond(to: request, decision: .deny) }
            Divider()
        }
        Button("Open in \(appName(for: request.app, platform: request.platform))") { monitor.respond(to: request, decision: .app) }
        if !request.detail.isEmpty {
            Button("Copy details") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(request.detail, forType: .string)
            }
        }
        Divider()
        Button("Dismiss") { monitor.dismiss(request) }
    }
}

struct AgentPillButton: View {
    enum Style { case primary(Color), secondary }
    let title: String
    let style: Style
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 5.5)
                .foregroundStyle(foreground)
                .background(Capsule().fill(background))
                .contentShape(Capsule())
        }
        .buttonStyle(TactileButtonStyle())
        .onHover { hovering = $0 }
        .animation(.smooth(duration: 0.16), value: hovering)
    }

    private var foreground: Color {
        if case .primary = style { return .black.opacity(0.88) }
        return .white.opacity(0.88)
    }

    private var background: Color {
        switch style {
        case .primary: .white.opacity(hovering ? 1 : 0.9)
        case .secondary: .white.opacity(hovering ? 0.17 : 0.1)
        }
    }
}

private struct EdgeActivityHint: View {
    let platforms: [AgentPlatform]
    let action: () -> Void
    @State private var glow = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Capsule()
            .fill(LinearGradient(colors: platforms.map(\.tint).ifEmpty([.white]), startPoint: .top, endPoint: .bottom))
            .frame(width: 3, height: 30)
            .opacity(glow ? 0.7 : 0.28)
            .shadow(color: (platforms.first?.tint ?? .white).opacity(0.45), radius: glow ? 6 : 2)
            .frame(width: 14, height: 44, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .agentHitRegion("hint")
            .help("Show agents")
            .accessibilityLabel("Show agents")
            .accessibilityAddTraits(.isButton)
            .onAppear {
                guard !reduceMotion else { glow = true; return }
                withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) { glow = true }
            }
    }
}

private extension Array {
    func ifEmpty(_ fallback: [Element]) -> [Element] { isEmpty ? fallback : self }
}

// MARK: - Peek

struct AgentPeekView: View {
    @ObservedObject var monitor: AgentMonitor
    let isOpen: Bool

    static let contentWidth: CGFloat = 344
    private let fillet: CGFloat = 12

    var body: some View {
        let shape = EdgeTabShape(cornerRadius: isOpen ? 24 : 3, fillet: isOpen ? fillet : 0)
        ZStack(alignment: .topLeading) {
            if isOpen {
                content
                    .frame(width: Self.contentWidth, alignment: .topLeading)
                    .transition(.asymmetric(
                        insertion: .opacity.animation(.smooth(duration: 0.2).delay(0.05)),
                        removal: .blurFade(radius: 4).animation(.easeIn(duration: 0.12))
                    ))
            }
        }
        .frame(width: isOpen ? Self.contentWidth : 6, height: isOpen ? nil : 70, alignment: .topLeading)
        .background(EdgeSurface(tint: accent, glow: 0.06))
        .clipShape(shape)
        .overlay(shape.stroke(EdgeStyle.hairline.opacity(isOpen ? 1 : 0), lineWidth: 1))
        .shadow(color: .black.opacity(isOpen ? 0.34 : 0), radius: 26, x: 4, y: 12)
    }

    private var accent: Color {
        monitor.sessions.first(where: { $0.status == .working || $0.status == .waiting })?.platform.tint ?? .blue
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ViewThatFits(in: .vertical) {
                list
                ScrollView(.vertical, showsIndicators: false) { list }
            }
            footer
        }
        .padding(.top, fillet + 14)
        .padding(.bottom, fillet + 12)
        .padding(.leading, fillet + 14)
        .padding(.trailing, 14)
    }

    private var sessionOffset: Int { monitor.requests.isEmpty ? 1 : monitor.requests.count + 2 }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(accent)
            Text("Agents")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(EdgeStyle.primaryText)
            Text(summary)
                .font(.system(size: 11))
                .foregroundStyle(EdgeStyle.tertiaryText)
                .lineLimit(1)
                .contentTransition(.numericText())
            Spacer(minLength: 4)
            HeaderGlyphButton(symbol: "point.3.connected.trianglepath.dotted", help: "Open Agent Hub") { monitor.openHubDashboard() }
        }
        .staggered(0)
    }

    private var summary: String {
        let working = monitor.sessions.filter { $0.status == .working }.count + monitor.hubJobs.count
        let waiting = monitor.requests.count
        var parts: [String] = []
        if working > 0 { parts.append("\(working) working") }
        if waiting > 0 { parts.append("\(waiting) need\(waiting == 1 ? "s" : "") you") }
        return parts.isEmpty ? "All quiet" : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !monitor.requests.isEmpty {
                SectionLabel("Needs you").staggered(1)
                ForEach(Array(monitor.requests.enumerated()), id: \.element.id) { index, request in
                    AgentRequestCard(request: request, monitor: monitor)
                        .staggered(index + 1)
                        .transition(.blurFade(radius: 5, scale: 0.97))
                }
            }

            if !monitor.sessions.isEmpty {
                if !monitor.requests.isEmpty { SectionLabel("Sessions").padding(.top, 4).staggered(sessionOffset) }
                ForEach(Array(monitor.sessions.enumerated()), id: \.element.id) { index, session in
                    AgentSessionCard(session: session, monitor: monitor)
                        .staggered(sessionOffset + index)
                        .transition(.blurFade(radius: 5, scale: 0.97))
                }
            }

            if !monitor.hubJobs.isEmpty {
                SectionLabel("Agent Hub").padding(.top, 4).staggered(sessionOffset + monitor.sessions.count)
                ForEach(Array(monitor.hubJobs.enumerated()), id: \.element.id) { index, job in
                    HubJobRow(job: job)
                        .onTapGesture(count: 2) { monitor.openHubDashboard() }
                        .staggered(sessionOffset + monitor.sessions.count + index + 1)
                        .transition(.blurFade(radius: 5, scale: 0.97))
                }
            }

            if monitor.sessions.isEmpty && monitor.requests.isEmpty && monitor.hubJobs.isEmpty {
                AgentEmptyState(monitor: monitor).staggered(1)
            }
        }
        .animation(EdgeStyle.morph, value: monitor.sessions.map(\.id))
        .animation(EdgeStyle.morph, value: monitor.requests.map(\.id))
        .animation(EdgeStyle.morph, value: monitor.hubJobs.map(\.id))
    }

    @ViewBuilder
    private var footer: some View {
        if monitor.sessions.contains(where: { $0.status == .done || $0.status == .error }) {
            HStack {
                Spacer()
                Button("Clear finished") { monitor.clearFinished() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(EdgeStyle.secondaryText)
            }
        }
    }
}

private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(EdgeStyle.tertiaryText)
    }
}

private struct HeaderGlyphButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(hovering ? 0.92 : 0.55))
                .frame(width: 24, height: 24)
                .background(Circle().fill(.white.opacity(hovering ? 0.14 : 0.07)))
        }
        .buttonStyle(TactileButtonStyle())
        .onHover { hovering = $0 }
        .animation(.smooth(duration: 0.16), value: hovering)
        .help(help)
    }
}

private struct CardBackground: ViewModifier {
    var highlighted: Bool
    var tint: Color?
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.white.opacity(hovering ? 0.085 : 0.055))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke((highlighted ? (tint ?? .white).opacity(0.3) : .white.opacity(0.05)), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .onHover { hovering = $0 }
            .animation(.smooth(duration: 0.18), value: hovering)
    }
}

struct AgentRequestCard: View {
    let request: AgentRequest
    @ObservedObject var monitor: AgentMonitor

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentRequestIcon(request: request, size: 30)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 10) {
                AgentRequestContent(request: request, roomy: true)
                AgentRequestActions(request: request, monitor: monitor)
            }
        }
        .modifier(CardBackground(highlighted: true, tint: request.platform.tint))
        .onTapGesture(count: 2) { monitor.respond(to: request, decision: .app) }
        .contextMenu { AgentRequestMenu(request: request, monitor: monitor) }
    }
}

struct AgentSessionCard: View {
    let session: AgentSession
    @ObservedObject var monitor: AgentMonitor

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            PlatformBadge(platform: session.platform, working: session.status == .working)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(headline)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(EdgeStyle.primaryText)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    AgentStatusChip(status: session.status, tint: session.platform.tint)
                }
                Text(sourceLine)
                    .font(.system(size: 10.5))
                    .foregroundStyle(EdgeStyle.tertiaryText)
                    .lineLimit(1)
                if !session.activity.isEmpty {
                    Text(session.activity)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.74))
                        .lineLimit(2)
                        .shimmering(session.status == .working)
                        .id(session.activity)
                        .transition(.blurFade(radius: 3).combined(with: .offset(y: 3)))
                }
                AgentSessionMeta(session: session)
            }
        }
        .modifier(CardBackground(highlighted: session.status == .waiting, tint: session.platform.tint))
        .onTapGesture(count: 2) { monitor.openApp(for: session) }
        .contextMenu {
            Button("Open in \(appName(for: session.app, platform: session.platform))") { monitor.openApp(for: session) }
            if !session.cwd.isEmpty {
                Button("Copy project path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(session.cwd, forType: .string)
                }
            }
        }
        .help("Double-click to open \(appName(for: session.app, platform: session.platform))")
        .animation(.smooth(duration: 0.32), value: session.activity)
        .animation(EdgeStyle.morph, value: session.status)
    }

    private var headline: String {
        if !session.title.isEmpty { return session.title }
        if !session.project.isEmpty { return session.project }
        return session.platformName
    }

    private var sourceLine: String {
        var parts = [session.platformName]
        if !session.project.isEmpty && session.project != headline { parts.append(session.project) }
        if !session.model.isEmpty { parts.append(session.model) }
        return parts.joined(separator: " · ")
    }
}

private struct AgentSessionMeta: View {
    let session: AgentSession

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 8) {
                Label(timeText(now: context.date), systemImage: "clock")
                if session.steps > 0 {
                    Label("\(session.steps) step\(session.steps == 1 ? "" : "s")", systemImage: "point.forward.to.point.capsulepath")
                }
            }
            .labelStyle(CompactLabelStyle())
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(EdgeStyle.tertiaryText)
        }
    }

    private func timeText(now: Date) -> String {
        switch session.status {
        case .working, .waiting:
            return elapsed(from: session.turnStartedAt ?? session.startedAt, to: now)
        case .done, .error:
            return "\(elapsed(from: session.finishedAt ?? session.updatedAt, to: now)) ago"
        case .idle:
            return "idle \(elapsed(from: session.updatedAt, to: now))"
        }
    }
}

private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

private func elapsed(from start: Date, to now: Date) -> String {
    let s = max(0, Int(now.timeIntervalSince(start)))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m \(String(format: "%02d", s % 60))s" }
    return "\(s / 3600)h \(String(format: "%02d", (s % 3600) / 60))m"
}

struct PlatformBadge: View {
    let platform: AgentPlatform
    var working = false
    var size: CGFloat = 30
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let outline = RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
        ZStack {
            outline.fill(platform.tint.opacity(0.15))
            Image(systemName: platform.symbol)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(platform.tint)
            if working {
                if reduceMotion {
                    outline.stroke(platform.tint.opacity(0.5), lineWidth: 1.5)
                } else {
                    TimelineView(.animation(minimumInterval: 1 / 60)) { context in
                        let period = 1.8
                        let head = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
                        let length = 0.22
                        ZStack {
                            outline.trim(from: head, to: min(1, head + length))
                                .stroke(platform.tint.opacity(0.85), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                            if head + length > 1 {
                                outline.trim(from: 0, to: head + length - 1)
                                    .stroke(platform.tint.opacity(0.85), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                            }
                        }
                    }
                    .transition(.opacity)
                }
            }
        }
        .frame(width: size, height: size)
        .animation(.smooth(duration: 0.3), value: working)
    }
}

struct AgentStatusChip: View {
    let status: AgentStatus
    let tint: Color
    @State private var breathe = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
                .opacity(status == .waiting && breathe ? 0.35 : 1)
            Text(status.label)
                .font(.system(size: 9.5, weight: .semibold))
                .contentTransition(.opacity)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.12)))
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { breathe = true }
        }
    }

    private var color: Color {
        switch status {
        case .working: tint
        case .waiting: EdgeStyle.attention
        case .idle: .white.opacity(0.5)
        case .done: EdgeStyle.success
        case .error: EdgeStyle.failure
        }
    }
}

private struct HubJobRow: View {
    let job: HubJob

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            PlatformBadge(platform: .hub, working: true, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.objective.isEmpty ? job.role : job.objective)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(2)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text([job.worker, job.model, job.project, elapsed(from: job.started, to: context.date)]
                        .filter { !$0.isEmpty }
                        .joined(separator: " · "))
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(EdgeStyle.tertiaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .modifier(CardBackground(highlighted: false, tint: nil))
        .help("Double-click to open Agent Hub")
    }
}

private struct AgentEmptyState: View {
    @ObservedObject var monitor: AgentMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("No agents running", systemImage: "moon.zzz")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
            if !monitor.hubAlive {
                Text("Agent Hub is not running")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                Button("Open Agent Hub") { monitor.openHubDashboard() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(EdgeStyle.secondaryText)
            } else if !monitor.hooksInstalled {
                Text("Install hooks from Agent Hub (agenthubctl install-hooks)")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Claude Code, Codex, Antigravity, OpenCode and Agent Hub jobs show up here while they work.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(CardBackground(highlighted: false, tint: nil))
    }
}

// MARK: - Shimmer

private struct Shimmer: ViewModifier {
    let active: Bool
    @State private var phase: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if active && !reduceMotion {
            content
                .overlay(
                    GeometryReader { proxy in
                        LinearGradient(colors: [.clear, .white.opacity(0.3), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: proxy.size.width * 0.5)
                            .offset(x: phase * proxy.size.width)
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                )
                .onAppear {
                    // Travels past the far edge so each sweep is followed by a short rest.
                    phase = -0.5
                    withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: false)) { phase = 1.9 }
                }
        } else {
            content
        }
    }
}

private extension View {
    func shimmering(_ active: Bool) -> some View { modifier(Shimmer(active: active)) }
}

// MARK: - Helpers

@MainActor
func appName(for bundleID: String?, platform: AgentPlatform) -> String {
    let id = (bundleID?.isEmpty == false ? bundleID : nil) ?? platform.defaultBundleID
    if let id, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
    return platform.displayName
}

// MARK: - Settings

struct AgentSettingsView: View {
    @ObservedObject var monitor: AgentMonitor = .shared

    private let holdChoices: [Double] = [15, 30, 45, 60, 120, 300]

    var body: some View {
        Form {
            Section("Left edge") {
                Toggle("Permission bubbles", isOn: $monitor.bubblesEnabled)
                Toggle("Peek at agents from the left edge", isOn: $monitor.edgePeekEnabled)
                LabeledContent("Edge delay") {
                    HStack {
                        Slider(value: $monitor.edgeDwell, in: 0.15...1.5, step: 0.05)
                            .frame(width: 180)
                        Text(String(format: "%.2f s", monitor.edgeDwell))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                }
                .disabled(!monitor.edgePeekEnabled)
            }

            Section {
                Toggle("Answer permissions from Notch", isOn: $monitor.answerFromNotch)
                Picker("Wait for an answer", selection: $monitor.holdSeconds) {
                    ForEach(holdChoices, id: \.self) { seconds in
                        Text(seconds < 60 ? "\(Int(seconds)) seconds" : "\(Int(seconds / 60)) min").tag(seconds)
                    }
                }
                .disabled(!monitor.answerFromNotch)
            } header: {
                Text("Permissions")
            } footer: {
                Text("Claude Code, Codex and OpenCode prompts appear as bubbles. Right-click to allow or deny, double-click to jump to the app. If you don't answer in time, the app shows its own prompt as usual.")
                    .foregroundStyle(.secondary)
            }

            Section("Connected agents") {
                ForEach([AgentPlatform.claude, .codex, .antigravity, .opencode]) { platform in
                    HStack {
                        Label(platform.displayName, systemImage: platform.symbol)
                            .foregroundStyle(platform.tint, .primary)
                        Spacer()
                        Text(lastSeen(platform))
                            .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Label("Agent Hub", systemImage: AgentPlatform.hub.symbol)
                    Spacer()
                    Text(monitor.hubJobs.isEmpty ? "No running jobs" : "\(monitor.hubJobs.count) running")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if !monitor.hubAlive {
                    HStack {
                        Text("Agent Hub is not running")
                        Spacer()
                        Button("Open Agent Hub") { monitor.openHubDashboard() }
                    }
                } else if !monitor.hooksInstalled {
                    Text("Install hooks from Agent Hub (agenthubctl install-hooks)")
                } else {
                    Text("Hooks installed")
                }
            } header: {
                Text("Agent Hub")
            } footer: {
                if monitor.hubAlive && monitor.hooksInstalled {
                    Text("Claude Code, Codex and OpenCode prompts appear as bubbles. Right-click to allow or deny, double-click to jump to the app. If you don't answer in time, the app shows its own prompt as usual. Antigravity reports progress only; it cannot be answered from Notch.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func lastSeen(_ platform: AgentPlatform) -> String {
        guard let date = monitor.platformLastSeen[platform] else { return "Not seen yet" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "Active \(formatter.localizedString(for: date, relativeTo: Date()))"
    }
}
