import AppKit
import SwiftUI

struct NotchRailItem: Identifiable {
    let id: String
    let symbol: String
    let title: String
    var tint: Color = .white
    var isSelected = false
    var isEnabled = true
    var weight: CGFloat = 1
    let action: () -> Void
}

/// The sketch's continuous surround: equal-width sides and base, with mitered corners.
struct NotchToolRail<Content: View>: View {
    private let left: [NotchRailItem]
    private let right: [NotchRailItem]
    private let bottom: [NotchRailItem]
    private var bottomWeights: [CGFloat] { bottom.map { max(0.01, $0.weight) } }
    private let content: Content
    @State private var hoveredItemID: String?
    @State private var pressedItemID: String?
    @State private var lastHoverHapticTime = TimeInterval.zero

    private let rail: CGFloat

    init(left: [NotchRailItem], right: [NotchRailItem], bottom: [NotchRailItem], rail: CGFloat,
         @ViewBuilder content: () -> Content) {
        self.rail = rail
        self.left = left
        self.right = right
        self.bottom = bottom
        self.content = content()
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let innerWidth = max(0, size.width - rail * 2)
            let innerHeight = max(0, size.height - rail)
            let radius = rail * 0.5
            let innerShape = UnevenRoundedRectangle(
                topLeadingRadius: 0, bottomLeadingRadius: radius,
                bottomTrailingRadius: radius, topTrailingRadius: 0)
            let outerShape = UnevenRoundedRectangle(
                topLeadingRadius: 0, bottomLeadingRadius: rail * 0.18,
                bottomTrailingRadius: rail * 0.18, topTrailingRadius: 0)

            ZStack(alignment: .topLeading) {
                Color(white: 0.23).allowsHitTesting(false)
                ForEach(left.indices, id: \.self) { index in
                    let item = left[index]
                    let region = NotchRailRegion(kind: .left(index), rail: rail,
                        innerHeight: innerHeight, leftCount: left.count,
                        rightCount: right.count, bottomCount: bottom.count, bottomWeights: bottomWeights)
                    railButton(item, region: region,
                        center: CGPoint(x: rail * 0.5,
                            y: innerHeight * (CGFloat(index) + 0.5) / CGFloat(max(1, left.count))),
                        size: size)
                }
                ForEach(right.indices, id: \.self) { index in
                    let item = right[index]
                    let region = NotchRailRegion(kind: .right(index), rail: rail,
                        innerHeight: innerHeight, leftCount: left.count,
                        rightCount: right.count, bottomCount: bottom.count, bottomWeights: bottomWeights)
                    railButton(item, region: region,
                        center: CGPoint(x: size.width - rail * 0.5,
                            y: innerHeight * (CGFloat(index) + 0.5) / CGFloat(max(1, right.count))),
                        size: size)
                }
                ForEach(bottom.indices, id: \.self) { index in
                    let item = bottom[index]
                    let region = NotchRailRegion(kind: .bottom(index), rail: rail,
                        innerHeight: innerHeight, leftCount: left.count,
                        rightCount: right.count, bottomCount: bottom.count, bottomWeights: bottomWeights)
                    let start = bottomWeights.prefix(index).reduce(0, +)
                    let total = max(0.01, bottomWeights.reduce(0, +))
                    let span = bottomWeights[index]
                    railButton(item, region: region,
                        center: CGPoint(x: rail + innerWidth * (start + span * 0.5) / total,
                            y: innerHeight + rail * 0.5), size: size)
                }

                content
                    .frame(width: innerWidth, height: innerHeight, alignment: .top)
                    .background(.black)
                    .clipShape(innerShape)
                    .contentShape(innerShape)
                    .shadow(color: .black.opacity(pressedItemID == nil ? 0.95 : 0), radius: 5, y: 2)
                    .offset(x: rail)
            }
            .clipShape(outerShape)
            .overlay {
                NotchRailPointerTracker { point in
                    let groups: [(items: [NotchRailItem], kind: (Int) -> NotchRailRegion.Kind)] = [
                        (left, { .left($0) }), (right, { .right($0) }), (bottom, { .bottom($0) })
                    ]
                    let hovered = point.flatMap { point in
                        groups.lazy.flatMap { group in
                            group.items.enumerated().compactMap { index, item -> String? in
                                let region = NotchRailRegion(kind: group.kind(index), rail: rail,
                                    innerHeight: innerHeight, leftCount: left.count,
                                    rightCount: right.count, bottomCount: bottom.count, bottomWeights: bottomWeights)
                                return item.isEnabled && region.path(in: CGRect(origin: .zero, size: size)).contains(point)
                                    ? item.id : nil
                            }
                        }.first
                    }
                    guard hoveredItemID != hovered else { return }
                    hoveredItemID = hovered
                    let now = ProcessInfo.processInfo.systemUptime
                    if hovered != nil, now - lastHoverHapticTime > 0.08 {
                        lastHoverHapticTime = now
                        NotchRailHaptics.perform(.alignment)
                    }
                }
            }
            .onDisappear { hoveredItemID = nil; pressedItemID = nil }
        }
    }

    private func railButton(_ item: NotchRailItem, region: NotchRailRegion,
                            center: CGPoint, size: CGSize) -> some View {
        Button(action: item.action) { Color.clear.frame(width: size.width, height: size.height) }
        .buttonStyle(NotchRailKeyStyle(region: region, symbol: item.symbol, center: center,
                                       selected: item.isSelected, tint: item.tint,
                                       hovered: hoveredItemID == item.id, size: size,
                                       hidesRims: pressedItemID != nil,
                                       onPressChanged: { pressed in
                                           if pressed { pressedItemID = item.id }
                                           else if pressedItemID == item.id { pressedItemID = nil }
                                       }))
        .disabled(!item.isEnabled)
        .help(item.title)
        .accessibilityLabel(item.title)
        .accessibilityIdentifier(item.id)
        .accessibilityAddTraits(item.isSelected ? .isSelected : [])
        .accessibilityHidden(!item.isEnabled)
        .frame(width: size.width, height: size.height)
        .contentShape(.interaction, region)
    }
}

struct NotchRailRegion: Shape, Equatable {
    enum Kind: Equatable { case left(Int), right(Int), bottom(Int) }

    let kind: Kind
    let rail: CGFloat
    let innerHeight: CGFloat
    let leftCount: Int
    let rightCount: Int
    let bottomCount: Int
    var bottomWeights: [CGFloat] = []

    private var normalizedWeights: [CGFloat] {
        let values = bottomWeights.count == bottomCount ? bottomWeights.map { max(0.01, $0) } : Array(repeating: 1, count: bottomCount)
        let total = max(0.01, values.reduce(0, +))
        return values.map { $0 / total }
    }
    private func bottomStart(_ index: Int, width: CGFloat) -> CGFloat { width * normalizedWeights.prefix(index).reduce(0, +) }
    private func bottomEnd(_ index: Int, width: CGFloat) -> CGFloat { bottomStart(index + 1, width: width) }

    func hinge(in size: CGSize) -> UnitPoint {
        switch kind {
        case .left: return UnitPoint(x: rail / max(1, size.width), y: 0.5)
        case .right: return UnitPoint(x: 1 - rail / max(1, size.width), y: 0.5)
        case .bottom: return UnitPoint(x: 0.5, y: innerHeight / max(1, size.height))
        }
    }

    var pressAngle: Double {
        // Orthographic rotation retracts the far edge by exactly five points.
        let angle = acos(max(0, 1 - min(5, rail) / max(1, rail))) * 180 / .pi
        if case .right = kind { return angle }
        return -angle
    }

    var pressAxis: (x: CGFloat, y: CGFloat, z: CGFloat) {
        if case .bottom = kind { return (1, 0, 0) }
        return (0, 1, 0)
    }

    var nearEdge: UnitPoint {
        switch kind {
        case .left: return .trailing
        case .right: return .leading
        case .bottom: return .top
        }
    }

    var farEdge: UnitPoint {
        switch kind {
        case .left: return .leading
        case .right: return .trailing
        case .bottom: return .bottom
        }
    }

    /// The content's bottom corners are circular arcs of this radius; the keys' inner edges follow them.
    /// The miter between the side key and the base key joins the outer corner to the arc midpoint (45 degrees).
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let width = rect.width
        let height = rect.height
        let innerWidth = max(0, width - rail * 2)
        let radius = rail * 0.5
        let inset = radius * (1 - 1 / sqrt(2.0))
        let k = radius * 0.2652, d = k * 0.70711 // cubic handle for a 45 degree arc
        let sideL = CGPoint(x: rail, y: innerHeight - radius), miterL = CGPoint(x: rail + inset, y: innerHeight - inset)
        let baseL = CGPoint(x: rail + radius, y: innerHeight)
        let sideR = CGPoint(x: width - rail, y: innerHeight - radius), miterR = CGPoint(x: width - rail - inset, y: innerHeight - inset)
        let baseR = CGPoint(x: width - rail - radius, y: innerHeight)
        func upperL(_ p: inout Path) { p.addCurve(to: miterL, control1: CGPoint(x: sideL.x, y: sideL.y + k), control2: CGPoint(x: miterL.x - d, y: miterL.y - d)) }
        func lowerL(_ p: inout Path) { p.addCurve(to: baseL, control1: CGPoint(x: miterL.x + d, y: miterL.y + d), control2: CGPoint(x: baseL.x - k, y: baseL.y)) }
        func upperR(_ p: inout Path) { p.addCurve(to: miterR, control1: CGPoint(x: sideR.x, y: sideR.y + k), control2: CGPoint(x: miterR.x + d, y: miterR.y - d)) }
        func lowerR(_ p: inout Path) { p.addCurve(to: baseR, control1: CGPoint(x: miterR.x - d, y: miterR.y + d), control2: CGPoint(x: baseR.x + k, y: baseR.y)) }

        switch kind {
        case .left(let index):
            let count = max(1, leftCount)
            let top = innerHeight * CGFloat(index) / CGFloat(count)
            let bottom = innerHeight * CGFloat(index + 1) / CGFloat(count)
            if index != count - 1 {
                path.addRect(CGRect(x: 0, y: top, width: rail, height: bottom - top))
            } else {
                path.move(to: CGPoint(x: 0, y: top))
                path.addLine(to: CGPoint(x: rail, y: top))
                path.addLine(to: sideL)
                upperL(&path)
                if bottomCount == 0 { lowerL(&path) }
                path.addLine(to: CGPoint(x: 0, y: height))
                path.closeSubpath()
            }
        case .right(let index):
            let count = max(1, rightCount)
            let top = innerHeight * CGFloat(index) / CGFloat(count)
            let bottom = innerHeight * CGFloat(index + 1) / CGFloat(count)
            if index != count - 1 {
                path.addRect(CGRect(x: width - rail, y: top, width: rail, height: bottom - top))
            } else {
                path.move(to: CGPoint(x: width, y: top))
                path.addLine(to: CGPoint(x: width - rail, y: top))
                path.addLine(to: sideR)
                upperR(&path)
                if bottomCount == 0 { lowerR(&path) }
                path.addLine(to: CGPoint(x: width, y: height))
                path.closeSubpath()
            }
        case .bottom(let index):
            let count = max(1, bottomCount)
            let x0 = rail + bottomStart(index, width: innerWidth)
            let x1 = rail + bottomEnd(index, width: innerWidth)
            let left = index == 0
            let right = index == count - 1
            if !left && !right {
                path.addRect(CGRect(x: x0, y: innerHeight, width: x1 - x0, height: height - innerHeight))
            } else {
                if left {
                    if leftCount > 0 {
                        path.move(to: miterL)
                    } else {
                        path.move(to: sideL)
                        upperL(&path)
                    }
                    lowerL(&path)
                    path.addLine(to: CGPoint(x: x1, y: innerHeight))
                    path.addLine(to: CGPoint(x: x1, y: height))
                    path.addLine(to: CGPoint(x: 0, y: height))
                    if leftCount == 0 { path.addLine(to: CGPoint(x: 0, y: innerHeight - radius)) }
                    path.closeSubpath()
                }
                if right {
                    path.move(to: CGPoint(x: x0, y: innerHeight))
                    path.addLine(to: baseR)
                    path.addCurve(to: miterR, control1: CGPoint(x: baseR.x + k, y: baseR.y),
                                  control2: CGPoint(x: miterR.x - d, y: miterR.y + d))
                    if rightCount == 0 {
                        path.addCurve(to: sideR, control1: CGPoint(x: miterR.x + d, y: miterR.y - d),
                                      control2: CGPoint(x: sideR.x, y: sideR.y + k))
                        path.addLine(to: CGPoint(x: width, y: innerHeight - radius))
                    }
                    path.addLine(to: CGPoint(x: width, y: height))
                    path.addLine(to: CGPoint(x: x0, y: height))
                    path.closeSubpath()
                }
            }
        }
        return path
    }
}

private struct NotchRailKeyStyle: ButtonStyle {
    let region: NotchRailRegion
    let symbol: String
    let center: CGPoint
    let selected: Bool
    let tint: Color
    let hovered: Bool
    let size: CGSize
    let hidesRims: Bool
    let onPressChanged: (Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        ZStack {
            Color.clear.contentShape(.interaction, region)
            // Fixed recess behind the retracting face: a fill only, never an outline.
            region.fill(.black.opacity(pressed ? 0.55 : 0)).allowsHitTesting(false)
            face(pressed: pressed)
                .shadow(color: .black.opacity(pressed ? 0 : 0.22), radius: pressed ? 0 : 2, y: pressed ? 0 : 1)
                .rotation3DEffect(.degrees(pressed && !reduceMotion ? region.pressAngle : 0),
                                  axis: region.pressAxis, anchor: region.hinge(in: size), perspective: 0)
                .allowsHitTesting(false)
                .animation(reduceMotion ? nil : (pressed ? .easeOut(duration: 0.07)
                    : .spring(response: 0.24, dampingFraction: 0.58)), value: pressed)
            configuration.label.hidden()
        }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .animation(.easeOut(duration: 0.12), value: selected)
        .onChange(of: pressed) { wasPressed, isPressed in
            onPressChanged(isPressed)
            if isPressed && !wasPressed { NotchRailHaptics.perform(.levelChange) }
        }
    }

    /// Anodised aluminium key: brushed sheen, knurled grip, inner bevels (clipped so they never touch neighbours).
    /// Pressed keys drop every rim and bevel and read as a flat recess.
    private func face(pressed: Bool) -> some View {
        let high = contrast == .increased
        let lit = selected && !pressed
        return ZStack {
            region.fill(LinearGradient(stops: [
                .init(color: Color(white: 0.37), location: 0), .init(color: Color(white: 0.25), location: 0.42),
                .init(color: Color(white: 0.29), location: 0.56), .init(color: Color(white: 0.15), location: 1)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
            if !high { NotchRailGrip(region: region, size: size).equatable() }
            if selected { region.fill(tint.opacity(pressed ? 0.07 : 0.15)) }
            if hovered && !pressed { region.fill(.white.opacity(0.09)) }
            if pressed {
                region.fill(LinearGradient(colors: [.black.opacity(0.12), .black.opacity(0.5)],
                    startPoint: region.nearEdge, endPoint: region.farEdge))
            } else if !hidesRims {
                region.stroke(LinearGradient(colors: [.white.opacity(high ? 0.65 : 0.36), .clear, .black.opacity(0.38)],
                    startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.4).clipShape(region)
                if hovered { region.stroke(.white.opacity(high ? 0.8 : 0.42), lineWidth: 2).clipShape(region) }
                if selected { region.stroke(tint.opacity(high ? 0.9 : 0.5), lineWidth: 2).clipShape(region) }
            }
            if !symbol.isEmpty {
                ZStack {
                    if lit {
                        Circle().fill(RadialGradient(colors: [tint.opacity(0.36), .clear], center: .center,
                            startRadius: 0, endRadius: region.rail * 0.7))
                            .frame(width: region.rail * 1.4, height: region.rail * 1.4)
                    }
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .medium))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(lit ? tint : .white.opacity(pressed ? 0.72 : (hovered ? 1 : 0.9)))
                        .shadow(color: lit ? tint.opacity(0.85) : .clear, radius: 3)
                        .shadow(color: lit ? tint.opacity(0.45) : .clear, radius: 8)
                }
                .position(x: center.x, y: center.y)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(region)
    }
}

/// Fine diagonal knurl. Equatable so hover/press changes never redraw it.
private struct NotchRailGrip: View, Equatable {
    let region: NotchRailRegion
    let size: CGSize

    var body: some View {
        Canvas { context, _ in
            let shape = region.path(in: CGRect(origin: .zero, size: size))
            let box = shape.boundingRect
            context.clip(to: shape)
            var rising = Path(), falling = Path()
            var offset = -box.height
            while offset < box.width {
                let x = box.minX + offset
                rising.move(to: CGPoint(x: x, y: box.maxY)); rising.addLine(to: CGPoint(x: x + box.height, y: box.minY))
                falling.move(to: CGPoint(x: x, y: box.minY)); falling.addLine(to: CGPoint(x: x + box.height, y: box.maxY))
                offset += 3
            }
            context.stroke(rising, with: .color(.white.opacity(0.05)), lineWidth: 0.5)
            context.stroke(falling, with: .color(.black.opacity(0.08)), lineWidth: 0.5)
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }
}

@MainActor
private enum NotchRailHaptics {
    static func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        guard NotchModel.shared.hapticsEnabled,
              !ProcessInfo.processInfo.arguments.contains("--ui-testing") else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}

/// One tracking area for the surround. Full-frame button tracking areas overlap.
private struct NotchRailPointerTracker: NSViewRepresentable {
    let onMove: (CGPoint?) -> Void

    func makeNSView(context: Context) -> TrackingView { TrackingView(onMove: onMove) }
    func updateNSView(_ nsView: TrackingView, context: Context) { nsView.onMove = onMove }

    final class TrackingView: NSView {
        var onMove: (CGPoint?) -> Void
        private var area: NSTrackingArea?
        private var eventMonitor: Any?
        override var isFlipped: Bool { true }

        init(onMove: @escaping (CGPoint?) -> Void) {
            self.onMove = onMove
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
            eventMonitor = nil
            guard window != nil else { return }
            // Observe without consuming events, including movement during a held press.
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) { [weak self] event in
                guard let self, !self.isHiddenOrHasHiddenAncestor else { return event }
                if event.window === self.window {
                    let point = self.convert(event.locationInWindow, from: nil)
                    self.onMove(self.bounds.contains(point) ? point : nil)
                } else {
                    self.onMove(nil)
                }
                return event
            }
        }
        deinit { if let eventMonitor { NSEvent.removeMonitor(eventMonitor) } }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let newArea = NSTrackingArea(rect: .zero,
                options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited, .enabledDuringMouseDrag],
                owner: self, userInfo: nil)
            addTrackingArea(newArea)
            area = newArea
        }
        override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
        override func mouseMoved(with event: NSEvent) { onMove(convert(event.locationInWindow, from: nil)) }
        override func mouseExited(with event: NSEvent) {
            // AppKit can switch tracking owners over child views without leaving the rail.
            let point = convert(event.locationInWindow, from: nil)
            onMove(bounds.contains(point) ? point : nil)
        }
    }
}

/// Open at the display edge, like the camera cutout above the central recess.
struct NotchCameraOutline: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = min(12, rect.height * 0.4)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.maxY),
                          control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - radius),
                          control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}
