import AppKit
import Accelerate
import AudioToolbox
import AVFoundation
import Combine
import CoreAudio
import Darwin
import EventKit
import IOKit.graphics
import IOKit.ps
import QuickLookUI
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

enum NotchModule: String, CaseIterable, Identifiable {
    case nowPlaying
    case shelf
    case apps
    case calendar
    case controls
    case mirror
    case workspace
    case toolkit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nowPlaying: return "Now Playing"
        case .shelf: return "Shelf"
        case .apps: return "Apps"
        case .calendar: return "Calendar"
        case .controls: return "Controls"
        case .mirror: return "Mirror"
        case .workspace: return "Workspace"
        case .toolkit: return "Tools"
        }
    }

    var symbol: String {
        switch self {
        case .nowPlaying: return "waveform"
        case .shelf: return "tray.full"
        case .apps: return "square.grid.2x2.fill"
        case .calendar: return "calendar"
        case .controls: return "slider.horizontal.3"
        case .mirror: return "camera.viewfinder"
        case .workspace: return "square.grid.3x3"
        case .toolkit: return "square.stack.3d.up.fill"
        }
    }

    var tint: Color {
        switch self {
        case .nowPlaying: return Color(red: 0.69, green: 0.39, blue: 1.0)
        case .shelf: return Color(red: 0.23, green: 0.76, blue: 0.96)
        case .apps: return Color(red: 0.20, green: 0.78, blue: 0.55)
        case .calendar: return Color(red: 1.0, green: 0.53, blue: 0.25)
        case .controls: return Color(red: 0.35, green: 0.84, blue: 0.58)
        case .mirror: return Color(red: 0.53, green: 0.57, blue: 1.0)
        case .workspace: return Color(red: 0.35, green: 0.84, blue: 0.75)
        case .toolkit: return Color(red: 0.77, green: 0.83, blue: 0.93)
        }
    }

    var tagline: String {
        switch self {
        case .nowPlaying: return "Music, beautifully close"
        case .shelf: return "Keep files close at hand"
        case .apps: return "Quick launch your apps"
        case .calendar: return "Your next moments"
        case .controls: return "Quick Mac controls"
        case .mirror: return "A private camera preview"
        case .workspace: return "Focus, voice, and a little company"
        case .toolkit: return "Small tools, close at hand"
        }
    }

    var index: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }
}

enum NotchAppearance: String, CaseIterable, Identifiable {
    case automatic
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

enum NotchInteraction: String, CaseIterable, Identifiable {
    case hover
    case click
    case hoverAndClick

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hover: return "Hover to expand"
        case .click: return "Click to expand"
        case .hoverAndClick: return "Hover or click"
        }
    }

    var expandsOnHover: Bool {
        self == .hover || self == .hoverAndClick
    }

    var expandsOnClick: Bool {
        self == .click || self == .hoverAndClick
    }
}

enum NotchSizePreset: String, CaseIterable, Identifiable {
    case compact
    case standard
    case roomy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact: return "Compact"
        case .standard: return "Standard"
        case .roomy: return "Roomy"
        }
    }

    var fallbackCollapsedSize: CGSize {
        switch self {
        case .compact: return CGSize(width: 226, height: 32)
        case .standard: return CGSize(width: 246, height: 34)
        case .roomy: return CGSize(width: 270, height: 38)
        }
    }

    var expandedSize: CGSize {
        switch self {
        case .compact: return CGSize(width: 650, height: 244)
        case .standard: return CGSize(width: 720, height: 270)
        case .roomy: return CGSize(width: 800, height: 300)
        }
    }

    /// Rail thickness stays at the preset's original proportion even when the panel widens.
    var railThickness: CGFloat { expandedSize.width * 0.075 }

    var wingWidth: CGFloat {
        switch self {
        case .compact: return 38
        case .standard: return 46
        case .roomy: return 54
        }
    }
}

struct DisplayNotchGeometry: Equatable {
    var coreWidth: CGFloat
    var height: CGFloat
    var hasHardwareNotch: Bool
    var screenNumber: UInt32

    static let fallback = DisplayNotchGeometry(
        coreWidth: 154,
        height: 34,
        hasHardwareNotch: false,
        screenNumber: 0
    )

    @MainActor
    static func read(from screen: NSScreen?) -> DisplayNotchGeometry {
        guard let screen else { return .fallback }

        let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        let hasHardwareNotch = screen.safeAreaInsets.top > 0
        let measuredWidth: CGFloat
        if let left = screen.auxiliaryTopLeftArea?.width,
           let right = screen.auxiliaryTopRightArea?.width {
            measuredWidth = screen.frame.width - left - right
        } else {
            measuredWidth = 154
        }

        let measuredHeight = hasHardwareNotch ? screen.safeAreaInsets.top : menuBarHeight
        let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        return DisplayNotchGeometry(
            coreWidth: min(max(measuredWidth, 148), 260),
            height: hasHardwareNotch ? measuredHeight : min(max(measuredHeight, 28), 42),
            hasHardwareNotch: hasHardwareNotch,
            screenNumber: number
        )
    }
}

struct DisplayTransferPolicy {
    static let dwellDuration: TimeInterval = 0.25

    static func triggerScreenNumber(
        at point: CGPoint,
        screens: [(number: UInt32, frame: CGRect)],
        currentScreenNumber: UInt32,
        triggerWidth: CGFloat = 220,
        triggerHeight: CGFloat = 16
    ) -> UInt32? {
        for screen in screens where screen.number != currentScreenNumber {
            let trigger = CGRect(
                x: screen.frame.midX - triggerWidth / 2,
                y: screen.frame.maxY - triggerHeight,
                width: triggerWidth,
                height: triggerHeight
            )
            if trigger.contains(point) { return screen.number }
        }
        return nil
    }
}

struct DisplayScreenCandidate {
    let number: UInt32
    let frame: CGRect
    let hasHardwareNotch: Bool
}

enum DisplayScreenTargetPolicy {
    static func screenNumber(
        at point: CGPoint,
        screens: [DisplayScreenCandidate],
        currentScreenNumber: UInt32?,
        followPointerDisplay: Bool
    ) -> UInt32? {
        if followPointerDisplay {
            if let currentScreenNumber,
               screens.contains(where: { $0.number == currentScreenNumber }) {
                return currentScreenNumber
            }
            if let pointerScreen = screens.first(where: { $0.frame.contains(point) }) {
                return pointerScreen.number
            }
        }

        if let notchedScreen = screens.first(where: \.hasHardwareNotch) {
            return notchedScreen.number
        }
        if let currentScreenNumber,
           screens.contains(where: { $0.number == currentScreenNumber }) {
            return currentScreenNumber
        }
        return nil
    }
}

enum ExpandedPanelLayout {
    static let headerHeight: CGFloat = 42
    static let verticalGap: CGFloat = 5
    static let topPadding: CGFloat = 5
    static let bottomPadding: CGFloat = 8

    static func cameraSafeHeight(for geometry: DisplayNotchGeometry) -> CGFloat {
        geometry.hasHardwareNotch ? max(0, geometry.height) : 0
    }

    static func headerWingWidth(expandedWidth: CGFloat, cameraWidth: CGFloat, railThickness: CGFloat, outerPadding: CGFloat = 12) -> CGFloat {
        let railInteriorWidth = max(0, expandedWidth - railThickness * 2)
        let headerContentWidth = max(0, railInteriorWidth - outerPadding * 2)
        return max(0, (headerContentWidth - max(0, cameraWidth)) / 2)
    }

    /// Keep simultaneous sections readable; the screen remains the upper bound.
    /// `agentsBelow` reserves room for the agent section in normal flow when no side column fits.
    static func fittedHeight(base: CGSize, module: NotchModule, geometry: DisplayNotchGeometry, railThickness: CGFloat, agentsBelow: Bool, availableHeight: CGFloat) -> CGFloat {
        let minimum: CGFloat
        switch module {
        case .calendar: minimum = 240
        // Stacked layouts need room for every section at once: Sound/Power + Voice, and Files + Clipboard + Folders.
        case .controls: minimum = 340
        case .shelf: minimum = base.width - railThickness * 2 - 24 < 640 ? 400 : 220
        case .workspace, .toolkit: minimum = 200
        default: minimum = 160
        }
        let overhead = base.height - contentHeight(expandedHeight: base.height, railThickness: railThickness, geometry: geometry)
        let needed = minimum + (agentsBelow ? AgentColumnLayout.belowHeight + AgentColumnLayout.gap : 0)
        return max(0, min(max(base.height, overhead + needed), availableHeight))
    }

    static func contentHeight(expandedHeight: CGFloat, railThickness: CGFloat, geometry: DisplayNotchGeometry) -> CGFloat {
        let header = max(headerHeight, cameraSafeHeight(for: geometry))
        return max(0, expandedHeight - railThickness - header - verticalGap - topPadding - bottomPadding)
    }
}

/// Agent column beside the destination: total = destination + column + gap (rails and padding are in the preset width).
enum AgentColumnLayout {
    static let width: CGFloat = 320
    static let gap: CGFloat = 12
    static let belowHeight: CGFloat = 200
    static let screenClearance: CGFloat = 16

    static func fitsBeside(destinationWidth: CGFloat, visibleWidth: CGFloat) -> Bool {
        destinationWidth + width + gap <= visibleWidth - screenClearance * 2
    }
}

struct FullScreenDetector {
    struct WindowEvidence {
        let layer: Int
        let alpha: CGFloat
        let bounds: CGRect
        let hasOwnerProcess: Bool
    }

    static func isFullScreen(screenRect: CGRect, hasMenubar: Bool, foregroundWindow: WindowEvidence?) -> Bool {
        guard !screenRect.isEmpty, !hasMenubar,
              let foregroundWindow,
              foregroundWindow.hasOwnerProcess,
              foregroundWindow.layer == 0,
              foregroundWindow.alpha > 0,
              !foregroundWindow.bounds.isEmpty else { return false }
        return foregroundWindow.bounds.contains(screenRect)
    }

    @MainActor
    static func isFullScreen(on screen: NSScreen?) -> Bool {
        guard let screen else { return false }
        let options = CGWindowListOption(arrayLiteral: .excludeDesktopElements, .optionOnScreenOnly)
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }

        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let cgScreenY = primaryHeight - screen.frame.maxY
        let cgScreenRect = CGRect(
            x: screen.frame.origin.x,
            y: cgScreenY,
            width: screen.frame.width,
            height: screen.frame.height
        )

        var hasMenubar = false
        var menubarEvidenceUnavailable = false
        for win in windowList {
            let owner = win[kCGWindowOwnerName as String] as? String ?? ""
            let name = win[kCGWindowName as String] as? String ?? ""
            guard owner == "Window Server" && name == "Menubar" else { continue }
            let boundsDict = win[kCGWindowBounds as String] as? [String: Any] ?? [:]
            guard let x = boundsDict["X"] as? CGFloat,
                  let y = boundsDict["Y"] as? CGFloat,
                  let w = boundsDict["Width"] as? CGFloat,
                  let h = boundsDict["Height"] as? CGFloat else {
                menubarEvidenceUnavailable = true
                continue
            }
            let winRect = CGRect(x: x, y: y, width: w, height: h)
            if winRect.intersects(cgScreenRect) {
                hasMenubar = true
                break
            }
        }
        guard !menubarEvidenceUnavailable else { return false }

        var foregroundWindow: WindowEvidence?
        for win in windowList {
            guard let layer = (win[kCGWindowLayer as String] as? NSNumber)?.intValue else { return false }
            guard layer == 0 else { continue }
            guard let alpha = (win[kCGWindowAlpha as String] as? NSNumber)?.doubleValue else { return false }
            guard alpha > 0 else { continue }
            guard let ownerPID = (win[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  ownerPID > 0,
                  let boundsDict = win[kCGWindowBounds as String] as? [String: Any],
                  let x = boundsDict["X"] as? CGFloat,
                  let y = boundsDict["Y"] as? CGFloat,
                  let width = boundsDict["Width"] as? CGFloat,
                  let height = boundsDict["Height"] as? CGFloat else { return false }
            let bounds = CGRect(x: x, y: y, width: width, height: height)
            guard bounds.intersects(cgScreenRect) else { continue }
            foregroundWindow = WindowEvidence(
                layer: layer,
                alpha: CGFloat(alpha),
                bounds: bounds,
                hasOwnerProcess: true
            )
            break
        }

        return isFullScreen(screenRect: cgScreenRect, hasMenubar: hasMenubar, foregroundWindow: foregroundWindow)
    }
}

public enum NotchExpansionState: String, CaseIterable, Codable {
    case collapsed
    case minimal
    case expanded
}

final class NotchModel: ObservableObject {
    static let shared = NotchModel()

    @Published var expansionState: NotchExpansionState = .collapsed
    @Published var isExpanded = false
    @Published var isLockedOpen = false
    @Published var activeModule: NotchModule = .nowPlaying
    @Published var workspaceSection: WorkspaceSection = .focus
    @Published var toolkitPage: NotchToolkitPage = .notes
    @Published private(set) var showToolkit = true
    @Published var isPinned = false
    @Published var isAgentSidebarPresented = false
    @Published var isVisible = true
    @Published var interaction: NotchInteraction = .hoverAndClick
    @Published var sizePreset: NotchSizePreset = .standard
    @Published var showVisualizer = true
    @Published var showBattery = true
    @Published var showCalendar = true
    @Published var showShelf = true
    @Published var appearance: NotchAppearance = .automatic
    @Published var hud: HUDState?
    @Published private(set) var navigationDirection = 1
    @Published private(set) var displayGeometry = DisplayNotchGeometry.fallback
    @Published var hoverDelay = 0.14
    @Published var closeDelay = 0.18
    @Published var hapticsEnabled = true
    @Published var followPointerDisplay = true
    @Published var autoHideInFullScreen = true
    @Published var isScreenFullScreen = false
    @Published var isRevealedInFullScreen = false
    @Published private(set) var isTucked = false

    private let defaults = UserDefaults.standard
    private var expandWorkItem: DispatchWorkItem?
    private var collapseWorkItem: DispatchWorkItem?
    private var fullScreenTuckWorkItem: DispatchWorkItem?
    private var isPointerInside = false
    private var mirrorAspectCancellable: AnyCancellable?

    var collapsedSize: CGSize {
        let height = displayGeometry.height
        let measured = CGSize(
            width: displayGeometry.coreWidth + sizePreset.wingWidth * 2,
            height: height
        )
        return displayGeometry.screenNumber == 0 ? sizePreset.fallbackCollapsedSize : measured
    }
    var minimalSize: CGSize {
        let width = min(max(displayGeometry.coreWidth + 96, 252), 270)
        let height = displayGeometry.height + 20
        return CGSize(width: width, height: height)
    }
    var railThickness: CGFloat { sizePreset.railThickness }
    private var currentScreen: NSScreen? {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayGeometry.screenNumber } ?? NSScreen.main
    }
    /// Agents open beside the destination when the display allows, otherwise beneath it.
    var showsAgentColumn: Bool {
        isAgentSidebarPresented && AgentColumnLayout.fitsBeside(destinationWidth: sizePreset.expandedSize.width,
                                                                visibleWidth: currentScreen?.visibleFrame.width ?? .infinity)
    }
    var showsAgentsBelow: Bool { isAgentSidebarPresented && !showsAgentColumn }
    /// Base preset size; the agent column adds width, Mirror grows downward to the camera aspect.
    var expandedSize: CGSize {
        let base = sizePreset.expandedSize
        let width = base.width + (showsAgentColumn ? AgentColumnLayout.width + AgentColumnLayout.gap : 0)
        let visibleHeight = currentScreen?.visibleFrame.height ?? .infinity
        let height = ExpandedPanelLayout.fittedHeight(base: base, module: activeModule, geometry: displayGeometry, railThickness: railThickness, agentsBelow: showsAgentsBelow, availableHeight: visibleHeight - 42)
        guard activeModule == .mirror else { return CGSize(width: width, height: height) }
        return CGSize(width: width, height: MirrorLayout.expandedHeight(
            base: CGSize(width: base.width, height: height),
            contentHeight: ExpandedPanelLayout.contentHeight(expandedHeight: height, railThickness: railThickness, geometry: displayGeometry),
            railThickness: railThickness,
            aspect: MirrorAspectStore.shared.aspect,
            maxHeight: visibleHeight - 34 - 8
        ))
    }
    var visibleSize: CGSize {
        switch expansionState {
        case .collapsed:
            return collapsedSize
        case .minimal:
            return minimalSize
        case .expanded:
            return expandedSize
        }
    }
    var panelSize: CGSize {
        CGSize(width: max(expandedSize.width, minimalSize.width) + 48, height: expandedSize.height + 34)
    }
    var coreNotchWidth: CGFloat { displayGeometry.coreWidth }
    var coreNotchHeight: CGFloat { displayGeometry.height }

    var preferredColorScheme: ColorScheme? {
        .dark
    }

    private init() {
        isPinned = defaults.bool(forKey: "notch.isPinned")
        isVisible = defaults.object(forKey: "notch.isVisible") as? Bool ?? true
        if let storedInteraction = defaults.string(forKey: "notch.interaction"),
           let interaction = NotchInteraction(rawValue: storedInteraction) {
            self.interaction = interaction
        } else {
            interaction = defaults.object(forKey: "notch.expandOnHover") as? Bool ?? true ? .hoverAndClick : .click
        }
        sizePreset = NotchSizePreset(rawValue: defaults.string(forKey: "notch.sizePreset") ?? "standard") ?? .standard
        mirrorAspectCancellable = MirrorAspectStore.shared.$aspect.dropFirst().removeDuplicates()
            .sink { [weak self] _ in self?.objectWillChange.send() }
        showVisualizer = defaults.object(forKey: "notch.showVisualizer") as? Bool ?? true
        showBattery = defaults.object(forKey: "notch.showBattery") as? Bool ?? true
        showCalendar = defaults.object(forKey: "notch.showCalendar") as? Bool ?? true
        showShelf = defaults.object(forKey: "notch.showShelf") as? Bool ?? true
        showToolkit = defaults.object(forKey: "notch.showToolkit") as? Bool ?? true
        appearance = NotchAppearance(rawValue: defaults.string(forKey: "notch.appearance") ?? "automatic") ?? .automatic
        activeModule = NotchModule(rawValue: defaults.string(forKey: "notch.activeModule") ?? "nowPlaying") ?? .nowPlaying
        if !showToolkit, activeModule == .toolkit { activeModule = .nowPlaying }
        hoverDelay = defaults.object(forKey: "notch.hoverDelay") as? Double ?? 0.14
        closeDelay = defaults.object(forKey: "notch.closeDelay") as? Double ?? 0.18
        hapticsEnabled = defaults.object(forKey: "notch.hapticsEnabled") as? Bool ?? true
        followPointerDisplay = defaults.object(forKey: "notch.followPointerDisplay") as? Bool ?? true
        autoHideInFullScreen = defaults.object(forKey: "notch.autoHideInFullScreen") as? Bool ?? true

        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            expansionState = .collapsed
            isExpanded = false
            isPinned = false
            isVisible = true
            activeModule = .nowPlaying
            interaction = .click
            sizePreset = .standard
            appearance = .dark
            showVisualizer = true
            showBattery = true
            showCalendar = true
            showShelf = true
            hoverDelay = 0
            closeDelay = 0.1
            hapticsEnabled = false
            followPointerDisplay = false
            autoHideInFullScreen = false
        }
        recalculateTucked()
    }

    func recalculateTucked() {
        let shouldTuck = isVisible
            && autoHideInFullScreen
            && isScreenFullScreen
            && !isPinned
            && !isLockedOpen
            && expansionState == .collapsed
            && !isRevealedInFullScreen
        if isTucked != shouldTuck {
            isTucked = shouldTuck
        }
    }

    func setExpansionState(_ state: NotchExpansionState) {
        expandWorkItem?.cancel()
        collapseWorkItem?.cancel()
        if state == .collapsed { isLockedOpen = false }
        expansionState = state
        isExpanded = state != .collapsed
        recalculateTucked()
    }

    func setExpanded(_ expanded: Bool) {
        setExpansionState(expanded ? .expanded : .collapsed)
    }

    func expandMinimal() {
        setExpansionState(.minimal)
    }

    func expandFull() {
        isLockedOpen = true
        setExpansionState(.expanded)
    }

    func toggleExpanded() {
        if expansionState == .expanded {
            unlockAndCollapse()
        } else {
            expandFull()
        }
    }

    func unlockAndCollapse() {
        isLockedOpen = false
        guard !isPinned else { return }
        setExpansionState(.collapsed)
        if isScreenFullScreen && autoHideInFullScreen && !isPointerInside {
            scheduleFullScreenTuck(after: closeDelay)
        }
    }

    /// Shift+= is an explicit request to minimise, so it also applies while pinned; the pin preference is kept.
    func collapseFromShortcut() {
        isLockedOpen = false
        setExpansionState(.collapsed)
        if isScreenFullScreen && autoHideInFullScreen && !isPointerInside {
            scheduleFullScreenTuck(after: closeDelay)
        }
    }

    func select(_ module: NotchModule) {
        guard module != .toolkit || showToolkit else { return }
        let wasExpanded = isExpanded
        if module != activeModule {
            navigationDirection = module.index >= activeModule.index ? 1 : -1
        }
        activeModule = module
        persist("notch.activeModule", module.rawValue)
        if !wasExpanded || expansionState != .expanded { expandFull() }
    }

    func pointerEntered() {
        isPointerInside = true
        collapseWorkItem?.cancel()
        fullScreenTuckWorkItem?.cancel()
        guard !isLockedOpen, !isPinned else { return }
        guard interaction.expandsOnHover else { return }
        if expansionState == .collapsed {
            expandWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, self.isPointerInside, self.interaction.expandsOnHover else { return }
                self.setExpansionState(.minimal)
            }
            expandWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + hoverDelay, execute: workItem)
        }
    }

    func pointerExited() {
        isPointerInside = false
        expandWorkItem?.cancel()
        guard !isLockedOpen, !isPinned else { return }
        scheduleCollapse(after: closeDelay)
        if isScreenFullScreen && autoHideInFullScreen {
            scheduleFullScreenTuck(after: closeDelay + 0.08)
        }
    }

    func scheduleCollapse(after delay: TimeInterval = 0.18) {
        guard !isPinned, !isLockedOpen else { return }
        collapseWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.isPointerInside, !self.isPinned, !self.isLockedOpen else { return }
            self.setExpansionState(.collapsed)
        }
        collapseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func updateDisplayGeometry(_ geometry: DisplayNotchGeometry) {
        guard geometry != displayGeometry else { return }
        displayGeometry = geometry
    }

    func presentHUD(_ state: HUDState) {
        hud = state
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.65) { [weak self] in
            guard self?.hud?.id == state.id else { return }
            self?.hud = nil
        }
    }

    func showSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    func openShelf() {
        select(.shelf)
    }

    func persist(_ key: String, _ value: Any) {
        defaults.set(value, forKey: key)
    }

    // These setters keep the user-facing preferences in sync without requiring
    // a separate settings store or a hidden configuration window.
    func updatePinned(_ value: Bool) {
        guard isPinned != value else { return }
        isPinned = value
        persist("notch.isPinned", value)
        recalculateTucked()
    }
    func updateVisible(_ value: Bool) {
        guard isVisible != value else { return }
        isVisible = value
        persist("notch.isVisible", value)
        recalculateTucked()
    }
    func updateInteraction(_ value: NotchInteraction) {
        guard interaction != value else { return }
        interaction = value
        persist("notch.interaction", value.rawValue)
        if value == .hover {
            isLockedOpen = false
            if isExpanded, !isPointerInside { scheduleCollapse(after: closeDelay) }
        }
        if !value.expandsOnHover {
            expandWorkItem?.cancel()
            collapseWorkItem?.cancel()
        }
    }
    func updateSize(_ value: NotchSizePreset) {
        guard sizePreset != value else { return }
        sizePreset = value
        persist("notch.sizePreset", value.rawValue)
    }
    func updateVisualizer(_ value: Bool) {
        guard showVisualizer != value else { return }
        showVisualizer = value
        persist("notch.showVisualizer", value)
        SystemAudioSpectrumMonitor.shared.setEnabled(value)
    }
    func updateBattery(_ value: Bool) { guard showBattery != value else { return }; showBattery = value; persist("notch.showBattery", value) }
    func updateCalendar(_ value: Bool) {
        guard showCalendar != value else { return }
        showCalendar = value
        persist("notch.showCalendar", value)
        if !value, activeModule == .calendar { select(.controls) }
    }
    func updateShelf(_ value: Bool) {
        guard showShelf != value else { return }
        showShelf = value
        persist("notch.showShelf", value)
        if !value, activeModule == .shelf { select(.nowPlaying) }
    }
    func updateToolkit(_ value: Bool) {
        guard showToolkit != value else { return }
        showToolkit = value
        persist("notch.showToolkit", value)
        if !value {
            NotificationCenter.default.post(name: .notchToolkitDisabled, object: nil)
            if activeModule == .toolkit { select(.nowPlaying) }
        }
    }
    func openTool(_ page: NotchToolkitPage) {
        guard showToolkit else { return }
        toolkitPage = page
        select(.toolkit)
    }
    func updateAppearance(_ value: NotchAppearance) { guard appearance != value else { return }; appearance = value; persist("notch.appearance", value.rawValue) }
    func updateHoverDelay(_ value: Double) {
        let next = min(max(value, 0), 0.8)
        guard hoverDelay != next else { return }
        hoverDelay = next
        persist("notch.hoverDelay", hoverDelay)
    }
    func updateCloseDelay(_ value: Double) {
        let next = min(max(value, 0.15), 2)
        guard closeDelay != next else { return }
        closeDelay = next
        persist("notch.closeDelay", closeDelay)
    }
    func updateHaptics(_ value: Bool) { guard hapticsEnabled != value else { return }; hapticsEnabled = value; persist("notch.hapticsEnabled", value) }
    func updateFollowPointerDisplay(_ value: Bool) {
        guard followPointerDisplay != value else { return }
        followPointerDisplay = value
        persist("notch.followPointerDisplay", value)
    }
    func updateAutoHideInFullScreen(_ value: Bool) {
        guard autoHideInFullScreen != value else { return }
        autoHideInFullScreen = value
        persist("notch.autoHideInFullScreen", value)
        if !value {
            isRevealedInFullScreen = true
        } else {
            isRevealedInFullScreen = false
        }
        recalculateTucked()
    }
    func updateScreenFullScreen(_ isFullScreen: Bool) {
        if isScreenFullScreen == isFullScreen {
            recalculateTucked()
            return
        }
        isScreenFullScreen = isFullScreen
        fullScreenTuckWorkItem?.cancel()
        isRevealedInFullScreen = false
        recalculateTucked()
    }
    func revealInFullScreen() {
        fullScreenTuckWorkItem?.cancel()
        fullScreenTuckWorkItem = nil
        if !isRevealedInFullScreen {
            isRevealedInFullScreen = true
            recalculateTucked()
        }
    }
    func scheduleFullScreenTuck(after delay: TimeInterval = 0.28) {
        guard isScreenFullScreen, autoHideInFullScreen, !isPinned, !isLockedOpen, expansionState == .collapsed else { return }
        fullScreenTuckWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.isScreenFullScreen,
                  self.autoHideInFullScreen,
                  !self.isPinned,
                  !self.isLockedOpen,
                  self.expansionState == .collapsed,
                  !self.isPointerInside else { return }
            self.isRevealedInFullScreen = false
            self.recalculateTucked()
        }
        fullScreenTuckWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }
    func cancelFullScreenTuck() {
        fullScreenTuckWorkItem?.cancel()
        fullScreenTuckWorkItem = nil
    }
}

struct NowPlayingSong {
    let id: String
    var title: String
    var artist: String
    var album: String
    var artwork: NSImage?
    var artworkURL: URL?
    var sourceApp: String
    var isPlaying: Bool
    var duration: Double
    var elapsed: Double
    var isShuffled: Bool = false
    var repeatMode: String = "off"

    static let placeholder = NowPlayingSong(
        id: "none",
        title: "Nothing playing",
        artist: "Start a song to bring the notch to life",
        album: "",
        artwork: nil,
        artworkURL: nil,
        sourceApp: "",
        isPlaying: false,
        duration: 0,
        elapsed: 0,
        isShuffled: false,
        repeatMode: "off"
    )

    var hasTrack: Bool { id != "none" }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(elapsed / duration, 0), 1)
    }

    var formattedRemainingTime: String {
        guard duration > 0 else { return "-0:00" }
        let remaining = max(0, duration - elapsed)
        let mins = Int(remaining) / 60
        let secs = Int(remaining) % 60
        return String(format: "-%d:%02d", mins, secs)
    }
}

enum AudioSpectrumAnalyzer {
    static let bandCount = 8
    static let floorDecibels: Float = -60
    static let ceilingDecibels: Float = 0
    static let bandEdgesHz: [Float] = [60, 120, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]

    static func normalizedLevel(decibels: Float) -> CGFloat {
        let clamped = min(max(decibels, floorDecibels), ceilingDecibels)
        return CGFloat((clamped - floorDecibels) / (ceilingDecibels - floorDecibels))
    }

    static func analyze(samples: [Float], sampleRate: Float) -> [Float] {
        guard sampleRate > 0, samples.count >= 32 else {
            return Array(repeating: floorDecibels, count: bandCount)
        }

        let fftSize = min(2_048, highestPowerOfTwo(atMost: samples.count))
        guard fftSize >= 32 else {
            return Array(repeating: floorDecibels, count: bandCount)
        }

        let start = samples.count - fftSize
        var windowed = Array(samples[start..<samples.count])
        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        vDSP_vmul(windowed, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        let halfSize = fftSize / 2
        var real = [Float](repeating: 0, count: halfSize)
        var imaginary = [Float](repeating: 0, count: halfSize)
        var magnitudes = [Float](repeating: 0, count: halfSize)
        let log2Size = vDSP_Length(log2(Float(fftSize)))

        let setup = vDSP_create_fftsetup(log2Size, FFTRadix(kFFTRadix2))
        guard let setup else {
            return Array(repeating: floorDecibels, count: bandCount)
        }
        defer { vDSP_destroy_fftsetup(setup) }

        var interleaved = [DSPComplex](repeating: DSPComplex(real: 0, imag: 0), count: halfSize)
        for index in 0..<halfSize {
            interleaved[index] = DSPComplex(
                real: windowed[index * 2],
                imag: windowed[index * 2 + 1]
            )
        }

        real.withUnsafeMutableBufferPointer { realBuffer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                var split = DSPSplitComplex(
                    realp: realBuffer.baseAddress!,
                    imagp: imaginaryBuffer.baseAddress!
                )
                interleaved.withUnsafeBufferPointer { buffer in
                    guard let baseAddress = buffer.baseAddress else { return }
                    vDSP_ctoz(baseAddress, 2, &split, 1, vDSP_Length(halfSize))
                }
                vDSP_fft_zrip(setup, &split, 1, log2Size, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(halfSize))
            }
        }

        let binWidth = sampleRate / Float(fftSize)
        return (0..<bandCount).map { bandIndex in
            let lowerBin = max(1, Int(floor(bandEdgesHz[bandIndex] / binWidth)))
            let upperBin = min(halfSize, Int(ceil(bandEdgesHz[bandIndex + 1] / binWidth)))
            guard lowerBin < upperBin else { return floorDecibels }

            let energy = magnitudes[lowerBin..<upperBin].reduce(0, +) / Float(upperBin - lowerBin)
            let amplitude = sqrt(max(energy, 0)) * 2 / Float(fftSize)
            let decibels = 20 * log10(max(amplitude, 0.000001))
            return min(max(decibels, floorDecibels), ceilingDecibels)
        }
    }

    private static func highestPowerOfTwo(atMost value: Int) -> Int {
        var result = 1
        while result <= value / 2 { result *= 2 }
        return result
    }
}

enum AudioSpectrumCaptureStatus: Equatable {
    case idle
    case starting
    case capturing
    case unavailable

    var title: String {
        switch self {
        case .idle: return "Waiting for playback"
        case .starting: return "Connecting to system audio"
        case .capturing: return "Reading system audio"
        case .unavailable: return "Core Audio output unavailable"
        }
    }
}

enum AudioSpectrumPCMEncoding: Equatable {
    case float32
    case int16
}

struct AudioSpectrumPCMFormat: Equatable {
    let sampleRate: Float
    let channelCount: Int
    let bytesPerFrame: Int
    let encoding: AudioSpectrumPCMEncoding
    let interleaved: Bool

    init?(stream: AudioStreamBasicDescription) {
        let flags = stream.mFormatFlags
        guard stream.mFormatID == kAudioFormatLinearPCM,
              stream.mSampleRate.isFinite, stream.mSampleRate > 0,
              stream.mChannelsPerFrame > 0,
              stream.mChannelsPerFrame <= 32,
              stream.mFramesPerPacket == 1,
              flags & kAudioFormatFlagIsBigEndian == 0 else { return nil }

        let channels = Int(stream.mChannelsPerFrame)
        let interleaved = flags & kAudioFormatFlagIsNonInterleaved == 0
        let bytesPerSample: Int
        let encoding: AudioSpectrumPCMEncoding
        if flags & kAudioFormatFlagIsFloat != 0,
           flags & kAudioFormatFlagIsSignedInteger == 0,
           stream.mBitsPerChannel == 32 {
            bytesPerSample = MemoryLayout<Float>.size
            encoding = .float32
        } else if flags & kAudioFormatFlagIsFloat == 0,
                  flags & kAudioFormatFlagIsSignedInteger != 0,
                  stream.mBitsPerChannel == 16 {
            bytesPerSample = MemoryLayout<Int16>.size
            encoding = .int16
        } else {
            return nil
        }

        let expectedBytesPerFrame = bytesPerSample * (interleaved ? channels : 1)
        guard Int(stream.mBytesPerFrame) == expectedBytesPerFrame,
              Int(stream.mBytesPerPacket) == expectedBytesPerFrame else { return nil }
        let sampleRate = Float(stream.mSampleRate)
        guard sampleRate.isFinite else { return nil }
        self.sampleRate = sampleRate
        self.channelCount = channels
        self.bytesPerFrame = expectedBytesPerFrame
        self.encoding = encoding
        self.interleaved = interleaved
    }

    init?(sampleRate: Float, channelCount: Int, encoding: AudioSpectrumPCMEncoding, interleaved: Bool) {
        guard sampleRate.isFinite, sampleRate > 0, (1...32).contains(channelCount) else { return nil }
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.encoding = encoding
        self.interleaved = interleaved
        let sampleBytes = encoding == .float32 ? MemoryLayout<Float>.size : MemoryLayout<Int16>.size
        self.bytesPerFrame = sampleBytes * (interleaved ? channelCount : 1)
    }
}

struct AudioSpectrumPCMBuffer {
    let data: Data
    let channelCount: Int
}

enum AudioSpectrumPCMDecoder {
    static let maximumFrames = 2_048

    static func decode(_ buffers: [AudioSpectrumPCMBuffer], format: AudioSpectrumPCMFormat) -> [Float]? {
        let expectedBuffers = format.interleaved ? 1 : format.channelCount
        guard buffers.count == expectedBuffers,
              buffers.allSatisfy({ $0.channelCount == (format.interleaved ? format.channelCount : 1) }) else { return nil }
        let sampleBytes = format.encoding == .float32 ? MemoryLayout<Float>.size : MemoryLayout<Int16>.size
        let frameBytes = format.interleaved ? format.bytesPerFrame : sampleBytes
        guard buffers.allSatisfy({ $0.data.count % frameBytes == 0 }),
              Set(buffers.map { $0.data.count }).count == 1 else { return nil }
        let frameCount = min(maximumFrames, buffers.map { $0.data.count / frameBytes }.min() ?? 0)
        guard frameCount >= 32 else { return nil }

        return (0..<frameCount).map { frame in
            var sum: Float = 0
            for channel in 0..<format.channelCount {
                let buffer = buffers[format.interleaved ? 0 : channel].data
                let offset = format.interleaved ? frame * format.bytesPerFrame + channel * sampleBytes : frame * sampleBytes
                let sample: Float = buffer.withUnsafeBytes { bytes in
                    switch format.encoding {
                    case .float32:
                        let value = bytes.loadUnaligned(fromByteOffset: offset, as: Float.self)
                        return value.isFinite ? min(max(value, -1), 1) : 0
                    case .int16:
                        return Float(bytes.loadUnaligned(fromByteOffset: offset, as: Int16.self)) / 32_768
                    }
                }
                sum += sample
            }
            return sum / Float(format.channelCount)
        }
    }
}

final class AudioSpectrumMailbox {
    struct Delivery {
        let bands: [Float]?
        let nextGeneration: UInt64?
    }

    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var latest: (generation: UInt64, bands: [Float])?
    private var hasPendingDelivery = false
    private var lastAnalysisTime: UInt64 = 0

    func beginGeneration() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        latest = nil
        lastAnalysisTime = 0
        return generation
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        latest = nil
        lastAnalysisTime = 0
    }

    func shouldAnalyze(generation: UInt64, now: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard generation == self.generation, now &- lastAnalysisTime >= 33_333_333 else { return false }
        lastAnalysisTime = now
        return true
    }

    func publish(_ bands: [Float], generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard generation == self.generation, bands.count == AudioSpectrumAnalyzer.bandCount else { return false }
        latest = (generation, bands)
        guard !hasPendingDelivery else { return false }
        hasPendingDelivery = true
        return true
    }

    func takeDelivery(for scheduledGeneration: UInt64) -> Delivery {
        lock.lock()
        defer { lock.unlock() }
        hasPendingDelivery = false
        if scheduledGeneration == generation, let latest, latest.generation == generation {
            self.latest = nil
            return Delivery(bands: latest.bands, nextGeneration: nil)
        }
        if latest?.generation == generation {
            hasPendingDelivery = true
            return Delivery(bands: nil, nextGeneration: generation)
        }
        return Delivery(bands: nil, nextGeneration: nil)
    }
}

final class SystemAudioSpectrumMonitor: NSObject, ObservableObject {
    static let shared = SystemAudioSpectrumMonitor()

    @Published private(set) var bandsDB = Array(repeating: AudioSpectrumAnalyzer.floorDecibels, count: AudioSpectrumAnalyzer.bandCount)
    @Published private(set) var status: AudioSpectrumCaptureStatus = .idle

    private let audioQueue = DispatchQueue(label: "sidco.notch.system-audio", qos: .userInteractive)
    private var tapID: AudioObjectID?
    private var aggregateDeviceID: AudioObjectID?
    private var ioProcID: AudioDeviceIOProcID?
    private var wantsCapture = false
    private var isPlaybackActive = false
    private var isEnabled = UserDefaults.standard.object(forKey: "notch.showVisualizer") as? Bool ?? true
    // Accessed only by the serial audio queue; a new capture resets its history.
    private var smoothingGeneration: UInt64?
    private var smoothedBands = Array(repeating: AudioSpectrumAnalyzer.floorDecibels, count: AudioSpectrumAnalyzer.bandCount)
    private var mailbox = AudioSpectrumMailbox()

    override init() {
        super.init()
    }

    func setPlaying(_ isPlaying: Bool) {
        isPlaybackActive = isPlaying
        updateCapture()
    }

    func setEnabled(_ isEnabled: Bool) {
        self.isEnabled = isEnabled
        updateCapture()
    }

    private func updateCapture() {
        guard !ProcessInfo.processInfo.arguments.contains("--ui-testing") else {
            stop()
            return
        }

        let isPlaying = isPlaybackActive && isEnabled
        guard wantsCapture != isPlaying || (isPlaying && aggregateDeviceID == nil) else { return }
        wantsCapture = isPlaying
        if isPlaying {
            startIfNeeded()
        } else {
            stop()
        }
    }

    private func startIfNeeded() {
        guard wantsCapture, aggregateDeviceID == nil else { return }
        status = .starting
        let generation = mailbox.beginGeneration()

        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tapDescription.uuid = UUID()
        tapDescription.name = "Notch System Audio Spectrum"
        tapDescription.isPrivate = true
        tapDescription.isMono = true

        var newTapID = kAudioObjectUnknown
        let tapStatus = AudioHardwareCreateProcessTap(tapDescription, &newTapID)
        guard tapStatus == noErr else {
            markUnavailable(operation: "create process tap", status: tapStatus)
            return
        }

        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var stream = AudioStreamBasicDescription()
        var streamSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let formatStatus = AudioObjectGetPropertyData(newTapID, &formatAddress, 0, nil, &streamSize, &stream)
        guard formatStatus == noErr, let pcmFormat = AudioSpectrumPCMFormat(stream: stream) else {
            _ = AudioHardwareDestroyProcessTap(newTapID)
            markUnavailable(operation: "read process tap format", status: formatStatus == noErr ? kAudio_ParamError : formatStatus)
            return
        }

        let aggregateDescription: [String: Any] = [
            "name": "Notch System Audio Spectrum",
            "uid": "sidco.notch.spectrum.\(UUID().uuidString)",
            "private": true,
            "taps": [[
                "uid": tapDescription.uuid.uuidString,
                "drift": true
            ]],
            "tapautostart": true
        ]

        var newAggregateDeviceID = kAudioObjectUnknown
        let aggregateStatus = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary,
            &newAggregateDeviceID
        )
        guard aggregateStatus == noErr else {
            _ = AudioHardwareDestroyProcessTap(newTapID)
            markUnavailable(operation: "create aggregate device", status: aggregateStatus)
            return
        }

        var newIOProcID: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(
            &newIOProcID,
            newAggregateDeviceID,
            audioQueue
        ) { [weak self] _, inputData, _, _, _ in
            self?.process(inputData, format: pcmFormat, generation: generation)
        }
        guard ioStatus == noErr, let newIOProcID else {
            _ = AudioHardwareDestroyAggregateDevice(newAggregateDeviceID)
            _ = AudioHardwareDestroyProcessTap(newTapID)
            markUnavailable(operation: "create audio callback", status: ioStatus)
            return
        }

        let startStatus = AudioDeviceStart(newAggregateDeviceID, newIOProcID)
        guard startStatus == noErr else {
            _ = AudioDeviceDestroyIOProcID(newAggregateDeviceID, newIOProcID)
            _ = AudioHardwareDestroyAggregateDevice(newAggregateDeviceID)
            _ = AudioHardwareDestroyProcessTap(newTapID)
            markUnavailable(operation: "start audio tap", status: startStatus)
            return
        }

        guard wantsCapture else {
            mailbox.stop()
            _ = AudioDeviceStop(newAggregateDeviceID, newIOProcID)
            _ = AudioDeviceDestroyIOProcID(newAggregateDeviceID, newIOProcID)
            _ = AudioHardwareDestroyAggregateDevice(newAggregateDeviceID)
            _ = AudioHardwareDestroyProcessTap(newTapID)
            status = .idle
            return
        }

        tapID = newTapID
        aggregateDeviceID = newAggregateDeviceID
        ioProcID = newIOProcID
        status = .capturing
    }

    private func stop() {
        wantsCapture = false
        mailbox.stop()
        bandsDB = Array(repeating: AudioSpectrumAnalyzer.floorDecibels, count: AudioSpectrumAnalyzer.bandCount)
        status = .idle

        guard let activeAggregateDeviceID = aggregateDeviceID else { return }
        let activeIOProcID = ioProcID
        let activeTapID = tapID
        aggregateDeviceID = nil
        ioProcID = nil
        tapID = nil

        if let activeIOProcID {
            _ = AudioDeviceStop(activeAggregateDeviceID, activeIOProcID)
            _ = AudioDeviceDestroyIOProcID(activeAggregateDeviceID, activeIOProcID)
        }
        _ = AudioHardwareDestroyAggregateDevice(activeAggregateDeviceID)
        if let activeTapID { _ = AudioHardwareDestroyProcessTap(activeTapID) }
    }

    private func process(_ inputData: UnsafePointer<AudioBufferList>, format: AudioSpectrumPCMFormat, generation: UInt64) {
        guard mailbox.shouldAnalyze(generation: generation, now: DispatchTime.now().uptimeNanoseconds) else { return }

        let audioBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        let expectedCount = format.interleaved ? 1 : format.channelCount
        guard audioBuffers.count == expectedCount else { return }
        let sampleBytes = format.encoding == .float32 ? MemoryLayout<Float>.size : MemoryLayout<Int16>.size
        let bytesPerFrame = format.interleaved ? format.bytesPerFrame : sampleBytes
        let maxBytes = AudioSpectrumPCMDecoder.maximumFrames * bytesPerFrame
        let buffers = audioBuffers.compactMap { buffer -> AudioSpectrumPCMBuffer? in
            guard let data = buffer.mData else { return nil }
            let channels = Int(buffer.mNumberChannels)
            let expectedChannels = format.interleaved ? format.channelCount : 1
            guard channels == expectedChannels else { return nil }
            guard Int(buffer.mDataByteSize) % bytesPerFrame == 0 else { return nil }
            let count = min(Int(buffer.mDataByteSize), maxBytes)
            guard count > 0 else { return nil }
            return AudioSpectrumPCMBuffer(data: Data(bytes: data, count: count), channelCount: channels)
        }
        guard buffers.count == expectedCount,
              let samples = AudioSpectrumPCMDecoder.decode(buffers, format: format) else { return }

        if smoothingGeneration != generation {
            smoothingGeneration = generation
            smoothedBands = Array(repeating: AudioSpectrumAnalyzer.floorDecibels, count: AudioSpectrumAnalyzer.bandCount)
        }
        let target = AudioSpectrumAnalyzer.analyze(samples: samples, sampleRate: format.sampleRate)
        smoothedBands = zip(smoothedBands, target).map { previous, next in
            let response: Float = next > previous ? 0.62 : 0.24
            return previous + (next - previous) * response
        }
        if mailbox.publish(smoothedBands, generation: generation) {
            DispatchQueue.main.async { [weak self] in self?.deliverSpectrum(generation: generation) }
        }
    }

    private func deliverSpectrum(generation: UInt64) {
        let delivery = mailbox.takeDelivery(for: generation)
        if let bands = delivery.bands { bandsDB = bands }
        if let nextGeneration = delivery.nextGeneration {
            DispatchQueue.main.async { [weak self] in self?.deliverSpectrum(generation: nextGeneration) }
        }
    }

    private func markUnavailable(operation: String, status: OSStatus) {
        self.status = .unavailable
        NSLog("[Notch] Core Audio spectrum unavailable while trying to %@ (status %d)", operation, status)
    }

}

struct TrackSnapshot {
    let title: String
    let artist: String
    let album: String
    let sourceApp: String
    let isPlaying: Bool
    let duration: Double
    let elapsed: Double
    let artworkURL: URL?
    var artworkData: Data? = nil
    let isShuffled: Bool
    let repeatMode: String
}

enum ArtworkColorExtractor {
    static func extractAccentColor(from image: NSImage) -> Color? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let size = 16
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var rawData = [UInt8](repeating: 0, count: size * size * 4)
        guard let context = CGContext(
            data: &rawData,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

        var bestColor: (r: CGFloat, g: CGFloat, b: CGFloat, score: CGFloat) = (0.5, 0.5, 0.5, -1)

        for i in stride(from: 0, to: rawData.count, by: 4) {
            let r = CGFloat(rawData[i]) / 255.0
            let g = CGFloat(rawData[i + 1]) / 255.0
            let b = CGFloat(rawData[i + 2]) / 255.0

            let maxC = max(r, max(g, b))
            let minC = min(r, min(g, b))
            let delta = maxC - minC
            let sat = maxC == 0 ? 0 : delta / maxC
            let lum = (maxC + minC) * 0.5

            if sat > 0.18 && lum > 0.2 && lum < 0.88 {
                let score = sat * 1.6 + (1.0 - abs(lum - 0.52))
                if score > bestColor.score {
                    bestColor = (r, g, b, score)
                }
            }
        }

        if bestColor.score > 0 {
            return Color(red: bestColor.r, green: bestColor.g, blue: bestColor.b)
        }
        return nil
    }
}

enum AppleScriptBridge {
    @discardableResult
    static func run(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if let error {
            NSLog("[Notch] AppleScript error: %@", error)
            return nil
        }
        return result.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum MusicPermissionHelper {
    static func testMusicConnection(completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let script = "tell application \"Music\" to get player state"
            let res = AppleScriptBridge.run(script)
            DispatchQueue.main.async {
                completion(res != nil)
            }
        }
    }

    static func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }
}

final class NowPlayingMonitor: ObservableObject {
    static let shared = NowPlayingMonitor()

    @Published var song = NowPlayingSong.placeholder
    @Published private(set) var lastPlaybackUpdate = Date()
    @Published var dynamicAccentColor: Color?
    @Published private(set) var activePID: pid_t?

    private var timer: Timer?
    private var notificationTokens: [NSObjectProtocol] = []
    private var artworkTask: URLSessionDataTask?
    private var lastArtworkKey = ""
    private var lastPollHadTrack = false
    private let mediaRemote = MediaRemoteAdapter()
    private var lastMediaRemoteEvent = Date.distantPast
    private var mediaRemoteControlsActive = false
    private var pollInFlight = false
    private var pollGeneration: UInt64 = 0

    private let dateProvider: () -> Date
    private let monitoringEnabled: Bool

    init(startMonitoring: Bool = true, dateProvider: @escaping () -> Date = Date.init) {
        self.monitoringEnabled = startMonitoring
        self.dateProvider = dateProvider
        self.lastPlaybackUpdate = dateProvider()
        if startMonitoring {
            self.startMonitoring()
            mediaRemote.start { [weak self] snapshot in
                self?.handleMediaRemote(snapshot)
            }
            if !mediaRemote.isAvailable { pollNow() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.lastMediaRemoteEvent == .distantPast else { return }
                self.pollNow()
            }
        }
    }

    deinit {
        timer?.invalidate()
        if monitoringEnabled {
            mediaRemote.stop()
            notificationTokens.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        }
    }

    private func startMonitoring() {
        let center = DistributedNotificationCenter.default()

        let musicToken = center.addObserver(
            forName: NSNotification.Name("com.apple.Music.playerInfo"),
            object: nil,
            queue: .main
        ) { [weak self] notif in
            self?.handleMusicNotification(notif)
        }
        notificationTokens.append(musicToken)

        let spotifyTokens = ["com.spotify.client.PlaybackStateChanged", "com.spotify.client.PlaybackStateChangedV2"].map { name in
            center.addObserver(forName: NSNotification.Name(name), object: nil, queue: .main) { [weak self] notif in
                self?.handleSpotifyNotification(notif)
            }
        }
        notificationTokens.append(contentsOf: spotifyTokens)

        timer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            guard let self,
                  Date().timeIntervalSince(self.lastMediaRemoteEvent) > 20 else { return }
            self.pollNow()
        }
    }

    private func handleMediaRemote(_ remote: MediaRemoteTrackSnapshot?) {
        lastMediaRemoteEvent = Date()
        guard let remote else {
            mediaRemoteControlsActive = false
            apply(nil)
            return
        }

        mediaRemoteControlsActive = true
        activePID = sourceApplicationPID(for: remote)
        apply(TrackSnapshot(
            title: remote.title,
            artist: remote.artist,
            album: remote.album,
            sourceApp: remote.sourceApp,
            isPlaying: remote.isPlaying,
            duration: remote.duration,
            elapsed: remote.elapsed,
            artworkURL: nil,
            artworkData: remote.artworkData,
            isShuffled: song.isShuffled,
            repeatMode: song.repeatMode
        ))
    }

    private func sourceApplicationPID(for remote: MediaRemoteTrackSnapshot) -> pid_t? {
        let bundleID = remote.sourceBundleIdentifier.lowercased()
        if bundleID.contains("google.chrome") {
            return NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").first?.processIdentifier
        }
        if bundleID.contains("safari") {
            return NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").first?.processIdentifier
        }
        if bundleID.contains("spotify") {
            return NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").first?.processIdentifier
        }
        if bundleID.contains("music") {
            return NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").first?.processIdentifier
        }
        return remote.processIdentifier
    }

    private func handleMusicNotification(_ notification: Notification) {
        guard let info = notification.userInfo else { pollNow(); return }
        let state = (info["Player State"] as? String)?.lowercased()
        let isPlaying = state == "playing"
        let title = (info["Name"] as? String) ?? ""
        guard !title.isEmpty else {
            pollNow()
            return
        }
        let artist = (info["Artist"] as? String) ?? ""
        let album = (info["Album"] as? String) ?? ""
        let ms = (info["Total Time"] as? Double ?? Double(info["Total Time"] as? Int ?? 0))
        let duration = ms > 0 ? ms / 1000.0 : song.duration

        let snapshot = TrackSnapshot(
            title: title,
            artist: artist,
            album: album,
            sourceApp: "Music",
            isPlaying: isPlaying,
            duration: duration,
            elapsed: song.title == title ? song.elapsed : 0,
            artworkURL: nil,
            isShuffled: song.isShuffled,
            repeatMode: song.repeatMode
        )
        apply(snapshot)
    }

    private func handleSpotifyNotification(_ notification: Notification) {
        guard let info = notification.userInfo else { pollNow(); return }
        let state = (info["Player State"] as? String)?.lowercased()
        let isPlaying = state == "playing"
        let title = (info["Name"] as? String) ?? ""
        guard !title.isEmpty else {
            pollNow()
            return
        }
        let artist = (info["Artist"] as? String) ?? ""
        let album = (info["Album"] as? String) ?? ""
        let ms = (info["Duration"] as? Double ?? Double(info["Duration"] as? Int ?? 0))
        let duration = ms > 0 ? ms / 1000.0 : song.duration
        let pos = (info["Playback Position"] as? Double ?? Double(info["Playback Position"] as? Int ?? 0))

        let snapshot = TrackSnapshot(
            title: title,
            artist: artist,
            album: album,
            sourceApp: "Spotify",
            isPlaying: isPlaying,
            duration: duration,
            elapsed: pos,
            artworkURL: nil,
            isShuffled: song.isShuffled,
            repeatMode: song.repeatMode
        )
        apply(snapshot)
    }

    func pollNow() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.pollNow() }
            return
        }
        guard !pollInFlight, Date().timeIntervalSince(lastMediaRemoteEvent) >= 20 else { return }
        pollInFlight = true
        pollGeneration &+= 1
        let generation = pollGeneration
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let spotify = Self.readSpotify()
            let music = Self.readMusic()
            let fallback = Self.preferred(spotify: spotify, music: music)
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.pollInFlight, self.pollGeneration == generation else { return }
                self.pollInFlight = false
                guard Date().timeIntervalSince(self.lastMediaRemoteEvent) >= 20 else { return }
                let sourceApp = fallback?.sourceApp
                let bundleID = sourceApp == "Spotify" ? "com.spotify.client" : sourceApp == "Music" ? "com.apple.Music" : nil
                self.activePID = bundleID.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first?.processIdentifier }
                self.apply(fallback)
            }
        }
    }

    func activatePlayingApp() {
        if let activePID, let app = NSRunningApplication(processIdentifier: activePID) {
            app.activate()
            return
        }
        if song.sourceApp == "Music", let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").first {
            app.activate()
            return
        }
        if song.sourceApp == "Spotify", let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").first {
            app.activate()
            return
        }
        if !song.sourceApp.isEmpty, let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName?.localizedCaseInsensitiveContains(song.sourceApp) == true
        }) {
            app.activate()
        }
    }

    private static func preferred(spotify: TrackSnapshot?, music: TrackSnapshot?) -> TrackSnapshot? {
        if spotify?.isPlaying == true { return spotify }
        if music?.isPlaying == true { return music }
        return spotify ?? music
    }

    private static func readSpotify() -> TrackSnapshot? {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").isEmpty == false else {
            return nil
        }
        let script = #"""
        tell application "Spotify"
            if not it is running then return ""
            try
                set pState to (player state as text)
            on error
                return ""
            end try
            if pState is "stopped" then return ""
            try
                set t to current track
                set tName to ""
                set tArtist to ""
                set tAlbum to ""
                set tDuration to 0
                set tPos to 0
                set tArt to ""
                set isShuff to false
                set isRep to false
                try
                    set tName to name of t
                end try
                try
                    set tArtist to artist of t
                end try
                try
                    set tAlbum to album of t
                end try
                try
                    set tDuration to (duration of t) / 1000
                end try
                try
                    set tPos to player position
                end try
                try
                    set tArt to artwork url of t
                end try
                try
                    set isShuff to shuffling
                end try
                try
                    set isRep to repeating
                end try
                if tName is not "" then
                    set shuffStr to "false"
                    if isShuff then set shuffStr to "true"
                    set repStr to "off"
                    if isRep then set repStr to "all"
                    return tName & "|||" & tArtist & "|||" & tAlbum & "|||" & pState & "|||" & tDuration & "|||" & tPos & "|||" & tArt & "|||" & shuffStr & "|||" & repStr
                end if
            on error
                return ""
            end try
            return ""
        end tell
        """#
        return parse(AppleScriptBridge.run(script), source: "Spotify")
    }

    private static func readMusic() -> TrackSnapshot? {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty == false else {
            return nil
        }
        let script = #"""
        tell application "Music"
            if not it is running then return ""
            try
                set pState to (player state as text)
            on error
                return ""
            end try
            if pState is "stopped" then return ""
            try
                set t to current track
                set tName to ""
                set tArtist to ""
                set tAlbum to ""
                set tDuration to 0
                set tPos to 0
                set isShuff to false
                set repMode to "off"
                try
                    set tName to name of t
                end try
                try
                    set tArtist to artist of t
                end try
                try
                    set tAlbum to album of t
                end try
                try
                    set tDuration to duration of t
                end try
                try
                    set tPos to player position
                end try
                try
                    set isShuff to shuffle enabled
                end try
                try
                    set repMode to (song repeat as text)
                end try
                if tName is not "" then
                    set shuffStr to "false"
                    if isShuff then set shuffStr to "true"
                    return tName & "|||" & tArtist & "|||" & tAlbum & "|||" & pState & "|||" & tDuration & "|||" & tPos & "||||||" & shuffStr & "|||" & repMode
                end if
            on error
                return ""
            end try
            return ""
        end tell
        """#
        return parse(AppleScriptBridge.run(script), source: "Music")
    }

    private static func parse(_ raw: String?, source: String) -> TrackSnapshot? {
        guard let raw, !raw.isEmpty else { return nil }
        let parts = raw.components(separatedBy: "|||")
        guard parts.count >= 6, !parts[0].isEmpty else { return nil }
        let duration = Double(parts[4].replacingOccurrences(of: ",", with: ".")) ?? 0
        let elapsed = Double(parts[5].replacingOccurrences(of: ",", with: ".")) ?? 0
        let artworkURL = parts.count > 6 && !parts[6].isEmpty ? URL(string: parts[6]) : nil
        let isShuffled = parts.count > 7 ? (parts[7].lowercased() == "true") : false
        let repeatMode = parts.count > 8 ? parts[8].lowercased() : "off"

        return TrackSnapshot(
            title: parts[0],
            artist: parts[1].isEmpty ? "Unknown artist" : parts[1],
            album: parts[2],
            sourceApp: source,
            isPlaying: parts[3].lowercased() == "playing",
            duration: max(duration, 0),
            elapsed: max(elapsed, 0),
            artworkURL: artworkURL,
            isShuffled: isShuffled,
            repeatMode: repeatMode
        )
    }

    private func apply(_ snapshot: TrackSnapshot?) {
        SystemAudioSpectrumMonitor.shared.setPlaying(snapshot?.isPlaying == true)
        guard let snapshot else {
            if lastPollHadTrack {
                song = .placeholder
                lastArtworkKey = ""
                dynamicAccentColor = nil
                lastPlaybackUpdate = Date()
            }
            lastPollHadTrack = false
            return
        }

        lastPollHadTrack = true
        let stableID = [snapshot.sourceApp, snapshot.title, snapshot.artist, snapshot.album].joined(separator: "|")
        let artChanged = stableID != lastArtworkKey
        if artChanged {
            artworkTask?.cancel()
            lastArtworkKey = stableID
        }

        var artwork = song.id == stableID ? song.artwork : nil
        if artChanged,
           let data = snapshot.artworkData,
           let embeddedArtwork = NSImage(data: data) {
            artwork = embeddedArtwork
            dynamicAccentColor = ArtworkColorExtractor.extractAccentColor(from: embeddedArtwork)
        } else if let artwork, dynamicAccentColor == nil {
            dynamicAccentColor = ArtworkColorExtractor.extractAccentColor(from: artwork)
        }

        song = NowPlayingSong(
            id: stableID,
            title: snapshot.title,
            artist: snapshot.artist,
            album: snapshot.album,
            artwork: artwork,
            artworkURL: snapshot.artworkURL,
            sourceApp: snapshot.sourceApp,
            isPlaying: snapshot.isPlaying,
            duration: snapshot.duration,
            elapsed: snapshot.elapsed,
            isShuffled: snapshot.isShuffled,
            repeatMode: snapshot.repeatMode
        )
        lastPlaybackUpdate = Date()

        if artChanged {
            if snapshot.artworkData != nil {
                // MediaRemote supplied the artwork inline.
            } else if let artworkURL = snapshot.artworkURL {
                loadArtwork(from: artworkURL, for: stableID)
            } else if snapshot.sourceApp == "Music" {
                loadMusicArtwork(for: stableID)
            }
        }
    }

    private func loadArtwork(from url: URL, for songID: String) {
        artworkTask = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let image = NSImage(data: data) else { return }
            let accent = ArtworkColorExtractor.extractAccentColor(from: image)
            DispatchQueue.main.async {
                guard self?.song.id == songID else { return }
                self?.song.artwork = image
                self?.dynamicAccentColor = accent
            }
        }
        artworkTask?.resume()
    }

    private func loadMusicArtwork(for songID: String) {
        let path = NSTemporaryDirectory().appending("notch-artwork-\(UUID().uuidString).jpg")
        FileManager.default.createFile(atPath: path, contents: nil)
        let escapedPath = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = #"""
        tell application "Music"
            try
                set artworkData to data of artwork 1 of current track
                set outFile to POSIX file "__PATH__" as alias
                open for access outFile with write permission
                set eof outFile to 0
                write artworkData to outFile
                close access outFile
                return "ok"
            on error
                try
                    close access (POSIX file "__PATH__" as alias)
                end try
                return "error"
            end try
        end tell
        """#.replacingOccurrences(of: "__PATH__", with: escapedPath)

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard AppleScriptBridge.run(script) == "ok",
                  let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let image = NSImage(data: data) else {
                try? FileManager.default.removeItem(atPath: path)
                return
            }
            try? FileManager.default.removeItem(atPath: path)
            let accent = ArtworkColorExtractor.extractAccentColor(from: image)
            DispatchQueue.main.async {
                guard self?.song.id == songID else { return }
                self?.song.artwork = image
                self?.dynamicAccentColor = accent
            }
        }
    }

    func playPause() {
        guard song.hasTrack else { return }
        let now = dateProvider()
        song.elapsed = estimatedElapsed(at: now)
        song.isPlaying.toggle()
        lastPlaybackUpdate = now
        perform(remote: .togglePlayPause, appleScript: "playpause")
    }

    func nextTrack() {
        guard song.hasTrack else { return }
        perform(remote: .next, appleScript: "next track")
    }

    func previousTrack() {
        guard song.hasTrack else { return }
        perform(remote: .previous, appleScript: "previous track")
    }

    var supportsQueueModes: Bool {
        song.sourceApp == "Spotify" || song.sourceApp == "Music"
    }

    func toggleShuffle() {
        guard song.hasTrack, supportsQueueModes else { return }
        let newShuffle = !song.isShuffled
        song.isShuffled = newShuffle
        if song.sourceApp == "Music" {
            let script = "tell application \"Music\" to set shuffle enabled to \(newShuffle)"
            DispatchQueue.global(qos: .userInitiated).async { _ = AppleScriptBridge.run(script) }
        } else if song.sourceApp == "Spotify" {
            let script = "tell application \"Spotify\" to set shuffling to \(newShuffle)"
            DispatchQueue.global(qos: .userInitiated).async { _ = AppleScriptBridge.run(script) }
        }
    }

    func toggleRepeat() {
        guard song.hasTrack, supportsQueueModes else { return }
        if song.sourceApp == "Music" {
            let nextMode: String
            switch song.repeatMode {
            case "off": nextMode = "all"
            case "all": nextMode = "one"
            default: nextMode = "off"
            }
            song.repeatMode = nextMode
            let script = "tell application \"Music\" to set song repeat to \(nextMode)"
            DispatchQueue.global(qos: .userInitiated).async { _ = AppleScriptBridge.run(script) }
        } else if song.sourceApp == "Spotify" {
            let newRepeat = song.repeatMode == "off"
            song.repeatMode = newRepeat ? "all" : "off"
            let script = "tell application \"Spotify\" to set repeating to \(newRepeat)"
            DispatchQueue.global(qos: .userInitiated).async { _ = AppleScriptBridge.run(script) }
        }
    }

    func seek(by seconds: Double) {
        guard song.hasTrack else { return }
        let position = max(0, min(song.duration, estimatedElapsed(at: Date()) + seconds))
        song.elapsed = position
        lastPlaybackUpdate = Date()
        if mediaRemoteControlsActive {
            mediaRemote.seek(to: position)
            return
        }
        guard song.sourceApp == "Spotify" || song.sourceApp == "Music" else { return }
        let source = song.sourceApp
        let script = "tell application \"\(source)\" to set player position to \(position)"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = AppleScriptBridge.run(script)
            DispatchQueue.main.async { [weak self] in self?.pollNow() }
        }
    }

    func seek(to progress: Double) {
        guard song.hasTrack, song.duration > 0 else { return }
        let position = max(0, min(song.duration, song.duration * progress))
        song.elapsed = position
        lastPlaybackUpdate = Date()
        if mediaRemoteControlsActive {
            mediaRemote.seek(to: position)
            return
        }
        guard song.sourceApp == "Spotify" || song.sourceApp == "Music" else { return }
        let source = song.sourceApp
        let script = "tell application \"\(source)\" to set player position to \(position)"
        DispatchQueue.global(qos: .userInitiated).async { _ = AppleScriptBridge.run(script) }
    }

    func estimatedElapsed(at date: Date) -> Double {
        guard song.hasTrack, song.duration > 0 else { return 0 }
        let elapsed = song.isPlaying
            ? song.elapsed + max(0, date.timeIntervalSince(lastPlaybackUpdate))
            : song.elapsed
        return min(max(elapsed, 0), song.duration)
    }

    func estimatedProgress(at date: Date) -> Double {
        guard song.duration > 0 else { return 0 }
        return min(max(estimatedElapsed(at: date) / song.duration, 0), 1)
    }

    func estimatedRemaining(at date: Date) -> Double {
        guard song.duration > 0 else { return 0 }
        return max(0, song.duration - estimatedElapsed(at: date))
    }

    func formattedRemainingTime(at date: Date) -> String {
        guard song.duration > 0 else { return "-0:00" }
        let remaining = estimatedRemaining(at: date)
        let mins = Int(remaining) / 60
        let secs = Int(remaining) % 60
        return String(format: "-%d:%02d", mins, secs)
    }

    private func perform(remote command: MediaRemoteAdapter.Command, appleScript: String) {
        guard monitoringEnabled, song.hasTrack else { return }
        if mediaRemoteControlsActive {
            mediaRemote.send(command)
            return
        }
        guard song.sourceApp == "Spotify" || song.sourceApp == "Music" else { return }
        let script = "tell application \"\(song.sourceApp)\" to \(appleScript)"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = AppleScriptBridge.run(script)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self?.pollNow() }
        }
    }
}

final class CameraPreviewController: ObservableObject {
    static let shared = CameraPreviewController()

    let session = AVCaptureSession()
    @Published private(set) var authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @Published private(set) var isAvailable = false
    @Published private(set) var isRunning = false

    private let sessionQueue = DispatchQueue(label: "sidco.notch.camera", qos: .userInitiated)
    private var isConfigured = false

    private init() {
        isAvailable = AVCaptureDevice.default(for: .video) != nil
    }

    deinit {
        sessionQueue.sync {
            if session.isRunning { session.stopRunning() }
        }
    }

    func start() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        DispatchQueue.main.async { [weak self] in self?.authorizationStatus = status }

        switch status {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            requestAccess()
        default:
            break
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.session.isRunning else { return }
            self.session.stopRunning()
            DispatchQueue.main.async { self.isRunning = false }
        }
    }

    func requestAccess() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            DispatchQueue.main.async { self?.authorizationStatus = status }
            if granted { self?.configureAndStart() }
        }
    }

    func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") else { return }
        NSWorkspace.shared.open(url)
    }

    func refreshStatus() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        DispatchQueue.main.async { [weak self] in self?.authorizationStatus = status }
    }

    private func configureAndStart() {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            if !self.isConfigured {
                self.session.beginConfiguration()
                self.session.sessionPreset = .high
                defer { self.session.commitConfiguration() }

                guard let device = AVCaptureDevice.default(for: .video) else {
                    DispatchQueue.main.async {
                        self.isAvailable = false
                        self.isRunning = false
                    }
                    return
                }

                do {
                    let input = try AVCaptureDeviceInput(device: device)
                    guard self.session.canAddInput(input) else { return }
                    self.session.addInput(input)
                    self.isConfigured = true
                    DispatchQueue.main.async { self.isAvailable = true }
                } catch {
                    DispatchQueue.main.async {
                        self.isAvailable = false
                        self.isRunning = false
                    }
                    return
                }
            }

            guard !self.session.isRunning else { return }
            self.session.startRunning()
            DispatchQueue.main.async { self.isRunning = true }
        }
    }
}

struct BatterySnapshot: Equatable {
    var level: Double = 1
    var isCharging = false
    var isPluggedIn = false

    var percentage: Int { Int((min(max(level, 0), 1) * 100).rounded()) }

    var symbol: String {
        if isCharging { return "battery.100percent.bolt" }
        switch percentage {
        case 0..<10: return "battery.0percent"
        case 10..<25: return "battery.25percent"
        case 25..<50: return "battery.50percent"
        case 50..<75: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

struct HUDState: Identifiable {
    let id = UUID()
    let symbol: String
    let title: String
    let value: Double
}

enum DisplayBrightnessController {
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32

    static func read(displayID: CGDirectDisplayID) -> Double? {
        if let getBrightness {
            var level: Float = 0
            if getBrightness(displayID, &level) == 0 {
                return Double(min(max(level, 0), 1))
            }
        }

        guard let service = service(for: displayID) else { return nil }
        defer { IOObjectRelease(service) }

        var level: Float = 0
        guard IODisplayGetFloatParameter(
            service,
            0,
            kIODisplayBrightnessKey as CFString,
            &level
        ) == kIOReturnSuccess else { return nil }
        return Double(min(max(level, 0), 1))
    }

    @discardableResult
    static func write(_ value: Double, displayID: CGDirectDisplayID) -> Bool {
        let clamped = Float(min(max(value, 0), 1))
        if let setBrightness, setBrightness(displayID, clamped) == 0 {
            return true
        }

        guard let service = service(for: displayID) else { return false }
        defer { IOObjectRelease(service) }
        return IODisplaySetFloatParameter(
            service,
            0,
            kIODisplayBrightnessKey as CFString,
            clamped
        ) == kIOReturnSuccess
    }

    private static func service(for displayID: CGDirectDisplayID) -> io_service_t? {
        let expectedVendor = CGDisplayVendorNumber(displayID)
        let expectedModel = CGDisplayModelNumber(displayID)
        var iterator: io_iterator_t = 0

        guard let matching = IOServiceMatching("IODisplayConnect"),
              IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == kIOReturnSuccess else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        while true {
            let candidate = IOIteratorNext(iterator)
            guard candidate != 0 else { break }

            let info = IODisplayCreateInfoDictionary(candidate, 0).takeRetainedValue() as NSDictionary
            let vendor = (info[kDisplayVendorID] as? NSNumber)?.uint32Value
            let model = (info[kDisplayProductID] as? NSNumber)?.uint32Value
            if vendor == expectedVendor, model == expectedModel {
                return candidate
            }
            IOObjectRelease(candidate)
        }
        return nil
    }

    private static let displayServicesHandle: UnsafeMutableRawPointer? = {
        let paths = [
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
            "/System/Library/PrivateFrameworks/DisplayServices.framework/Versions/Current/DisplayServices"
        ]
        for path in paths {
            if let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL) { return handle }
        }
        return nil
    }()

    private static let getBrightness: GetBrightness? = {
        guard let handle = displayServicesHandle,
              let symbol = dlsym(handle, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(symbol, to: GetBrightness.self)
    }()

    private static let setBrightness: SetBrightness? = {
        guard let handle = displayServicesHandle,
              let symbol = dlsym(handle, "DisplayServicesSetBrightness") else { return nil }
        return unsafeBitCast(symbol, to: SetBrightness.self)
    }()
}

enum BatteryController {
    static func read() -> BatterySnapshot {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as Array
        guard let source = sources.first,
              let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] else {
            return BatterySnapshot()
        }

        let current = description[kIOPSCurrentCapacityKey] as? Double ?? Double(description[kIOPSCurrentCapacityKey] as? Int ?? 100)
        let maximum = description[kIOPSMaxCapacityKey] as? Double ?? Double(description[kIOPSMaxCapacityKey] as? Int ?? 100)
        let charging = description[kIOPSIsChargingKey] as? Bool ?? false
        let powerSource = description[kIOPSPowerSourceStateKey] as? String
        let plugged = powerSource == kIOPSACPowerValue || charging
        return BatterySnapshot(level: maximum > 0 ? current / maximum : 1, isCharging: charging, isPluggedIn: plugged)
    }
}

struct AudioOutputDevice: Identifiable, Equatable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let symbol: String
    let isDefault: Bool
}

struct AudioCapabilities: Equatable {
    var volume: Double
    var isMuted: Bool
    var isVolumeAvailable: Bool
    var isMuteAvailable: Bool
    var hint: String
}

protocol AudioSystemBackend {
    func defaultOutputDeviceID() -> AudioDeviceID?
    func listOutputDevices() -> (devices: [AudioOutputDevice], defaultID: AudioDeviceID?)
    func setDefaultOutputDevice(id: AudioDeviceID) -> Result<Void, AudioOutputController.AudioOutputError>
    func readCapabilities(device: AudioDeviceID?) -> AudioCapabilities
    func writeVolume(_ value: Double, forDevice deviceID: AudioDeviceID) -> Bool
    func writeMuted(_ value: Bool, forDevice deviceID: AudioDeviceID) -> Bool
    func addDefaultDeviceListener(_ block: @escaping () -> Void) -> Any?
    func addDeviceListListener(_ block: @escaping () -> Void) -> Any?
    func removeListener(_ token: Any)
}

final class CoreAudioBackend: AudioSystemBackend {
    static let shared = CoreAudioBackend()

    func defaultOutputDeviceID() -> AudioDeviceID? {
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &device
        )
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    func listOutputDevices() -> (devices: [AudioOutputDevice], defaultID: AudioDeviceID?) {
        let currentDefault = defaultOutputDeviceID()

        var prop = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &prop, 0, nil, &size) == noErr else {
            return ([], currentDefault)
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &prop, 0, nil, &size, &deviceIDs) == noErr else {
            return ([], currentDefault)
        }

        var results: [AudioOutputDevice] = []

        for dev in deviceIDs {
            // Must be alive
            var alive: UInt32 = 0
            var aliveSize = UInt32(MemoryLayout<UInt32>.size)
            var aliveProp = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsAlive,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyData(dev, &aliveProp, 0, nil, &aliveSize, &alive) == noErr, alive != 0 else {
                continue
            }

            // Exclude hidden devices
            var hidden: UInt32 = 0
            var hiddenSize = UInt32(MemoryLayout<UInt32>.size)
            var hiddenProp = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyIsHidden,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            if AudioObjectGetPropertyData(dev, &hiddenProp, 0, nil, &hiddenSize, &hidden) == noErr, hidden != 0 {
                continue
            }

            // Must have output streams
            var streamProp = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(dev, &streamProp, 0, nil, &streamSize) == noErr, streamSize > 0 else {
                continue
            }

            // Must be capable of being default device
            var canBeDefault: UInt32 = 0
            var canBeDefaultSize = UInt32(MemoryLayout<UInt32>.size)
            var canBeDefaultProp = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceCanBeDefaultDevice,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyData(dev, &canBeDefaultProp, 0, nil, &canBeDefaultSize, &canBeDefault) == noErr, canBeDefault != 0 else {
                continue
            }

            // Device UID
            var uidProp = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var unmanagedUID: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(dev, &uidProp, 0, nil, &uidSize, &unmanagedUID) == noErr,
                  let cfUID = unmanagedUID?.takeRetainedValue() else {
                continue
            }
            let uid = cfUID as String

            // Exclude private spectrum aggregate or app tap aggregate
            if uid.hasPrefix("sidco.notch.spectrum.") {
                continue
            }

            // Device Name
            var nameProp = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var unmanagedName: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(dev, &nameProp, 0, nil, &nameSize, &unmanagedName) == noErr,
                  let cfName = unmanagedName?.takeRetainedValue() else {
                continue
            }
            let name = cfName as String
            if name == "Notch System Audio Spectrum" {
                continue
            }

            let symbol = AudioOutputController.symbolForDevice(dev, name: name)
            let isDef = (dev == currentDefault)
            results.append(AudioOutputDevice(id: dev, uid: uid, name: name, symbol: symbol, isDefault: isDef))
        }

        return (results, currentDefault)
    }

    func setDefaultOutputDevice(id: AudioDeviceID) -> Result<Void, AudioOutputController.AudioOutputError> {
        // Verify device still alive and exists
        var alive: UInt32 = 0
        var aliveSize = UInt32(MemoryLayout<UInt32>.size)
        var aliveProp = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(id, &aliveProp, 0, nil, &aliveSize, &alive) == noErr, alive != 0 else {
            return .failure(.disconnected)
        }

        var targetID = id
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            size,
            &targetID
        )

        guard status == noErr else {
            return .failure(.hardwareFailure)
        }

        // Bounded retry readback check for asynchronous or Bluetooth transitions
        var verified = false
        for _ in 0..<8 {
            var readbackID = AudioDeviceID(kAudioObjectUnknown)
            var readbackSize = UInt32(MemoryLayout<AudioDeviceID>.size)
            let readStatus = AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &readbackSize,
                &readbackID
            )
            if readStatus == noErr && readbackID == id {
                verified = true
                break
            }
            usleep(25_000)
        }

        if verified {
            return .success(())
        } else {
            return .failure(.routeUnconfirmed)
        }
    }

    private func preferredStereoChannels(for device: AudioDeviceID) -> [UInt32] {
        var channelsAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyPreferredChannelsForStereo,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var channels: [UInt32] = [1, 2]
        if AudioObjectHasProperty(device, &channelsAddr) {
            var pair: [UInt32] = [0, 0]
            var size = UInt32(MemoryLayout<UInt32>.size * 2)
            if AudioObjectGetPropertyData(device, &channelsAddr, 0, nil, &size, &pair) == noErr && pair[0] > 0 {
                channels = pair
            }
        }
        return channels
    }

    func readCapabilities(device: AudioDeviceID?) -> AudioCapabilities {
        guard let device = device ?? defaultOutputDeviceID() else {
            return AudioCapabilities(
                volume: 0,
                isMuted: false,
                isVolumeAvailable: false,
                isMuteAvailable: false,
                hint: "No audio output device found"
            )
        }

        // Check controls: prefer writable control paths.
        // 1. Virtual Main Volume
        var virtVolAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var isVirtVolSettable: DarwinBoolean = false
        let hasVirtVol = AudioObjectHasProperty(device, &virtVolAddr)
        if hasVirtVol {
            AudioObjectIsPropertySettable(device, &virtVolAddr, &isVirtVolSettable)
        }

        // 2. Scalar Main Volume
        var scalarMainAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var isScalarMainSettable: DarwinBoolean = false
        let hasScalarMain = AudioObjectHasProperty(device, &scalarMainAddr)
        if hasScalarMain {
            AudioObjectIsPropertySettable(device, &scalarMainAddr, &isScalarMainSettable)
        }

        // 3. Stereo channels
        let channels = preferredStereoChannels(for: device)
        var channelSettableCount = 0
        var channelVols: [Double] = []

        for ch in channels {
            var chAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: ch
            )
            guard AudioObjectHasProperty(device, &chAddr) else { continue }
            var isSettable: DarwinBoolean = false
            AudioObjectIsPropertySettable(device, &chAddr, &isSettable)
            if isSettable.boolValue {
                channelSettableCount += 1
            }
            var vol = Float32(0)
            var volSize = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(device, &chAddr, 0, nil, &volSize, &vol) == noErr,
               vol.isFinite {
                channelVols.append(Double(min(max(vol, 0), 1)))
            }
        }

        var readVolume: Double? = nil
        var canSetVolume = false

        // Pick writable properties first
        if hasVirtVol && isVirtVolSettable.boolValue {
            var vol = Float32(0)
            var volSize = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(device, &virtVolAddr, 0, nil, &volSize, &vol) == noErr,
               vol.isFinite {
                readVolume = Double(min(max(vol, 0), 1))
                canSetVolume = true
            }
        }

        if (!canSetVolume || readVolume == nil) && hasScalarMain && isScalarMainSettable.boolValue {
            var vol = Float32(0)
            var volSize = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(device, &scalarMainAddr, 0, nil, &volSize, &vol) == noErr,
               vol.isFinite {
                readVolume = Double(min(max(vol, 0), 1))
                canSetVolume = true
            }
        }

        if (!canSetVolume || readVolume == nil) && !channels.isEmpty && channelSettableCount == channels.count && !channelVols.isEmpty {
            readVolume = channelVols.max() ?? 0
            canSetVolume = true
        }

        // If not settable, read for display if available, but canSetVolume remains false
        if readVolume == nil {
            if hasVirtVol {
                var vol = Float32(0)
                var volSize = UInt32(MemoryLayout<Float32>.size)
                if AudioObjectGetPropertyData(device, &virtVolAddr, 0, nil, &volSize, &vol) == noErr,
                   vol.isFinite {
                    readVolume = Double(min(max(vol, 0), 1))
                }
            } else if hasScalarMain {
                var vol = Float32(0)
                var volSize = UInt32(MemoryLayout<Float32>.size)
                if AudioObjectGetPropertyData(device, &scalarMainAddr, 0, nil, &volSize, &vol) == noErr,
                   vol.isFinite {
                    readVolume = Double(min(max(vol, 0), 1))
                }
            } else if !channelVols.isEmpty {
                readVolume = channelVols.max()
            }
        }

        // Mute
        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let hasMute = AudioObjectHasProperty(device, &muteAddr)
        var isMuteSettable: DarwinBoolean = false
        if hasMute {
            AudioObjectIsPropertySettable(device, &muteAddr, &isMuteSettable)
        }

        var readMute = false
        var canSetMute = false

        if hasMute {
            var muted: UInt32 = 0
            var muteSize = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(device, &muteAddr, 0, nil, &muteSize, &muted) == noErr {
                readMute = (muted != 0)
                canSetMute = isMuteSettable.boolValue
            }
        }

        let isVolAvailable = (readVolume != nil) && canSetVolume
        let isMuteAvailable = hasMute && canSetMute
        let hint = isVolAvailable ? "" : "Volume fixed • use device controls"

        return AudioCapabilities(
            volume: readVolume ?? 0,
            isMuted: readMute,
            isVolumeAvailable: isVolAvailable,
            isMuteAvailable: isMuteAvailable,
            hint: hint
        )
    }

    func writeVolume(_ value: Double, forDevice deviceID: AudioDeviceID) -> Bool {
        guard value.isFinite else { return false }
        let clamped = Float32(min(max(value, 0), 1))

        // 1. Try virtual main volume first if settable
        var virtAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(deviceID, &virtAddr) {
            var settable: DarwinBoolean = false
            AudioObjectIsPropertySettable(deviceID, &virtAddr, &settable)
            if settable.boolValue {
                var vol = clamped
                let size = UInt32(MemoryLayout<Float32>.size)
                if AudioObjectSetPropertyData(deviceID, &virtAddr, 0, nil, size, &vol) == noErr {
                    return true
                }
            }
        }

        // 2. Try scalar main volume if settable
        var scalarMainAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(deviceID, &scalarMainAddr) {
            var settable: DarwinBoolean = false
            AudioObjectIsPropertySettable(deviceID, &scalarMainAddr, &settable)
            if settable.boolValue {
                var vol = clamped
                let size = UInt32(MemoryLayout<Float32>.size)
                if AudioObjectSetPropertyData(deviceID, &scalarMainAddr, 0, nil, size, &vol) == noErr {
                    return true
                }
            }
        }

        // 3. Try per-channel scalar fallback (e.g. stereo balance preservation)
        let channels = preferredStereoChannels(for: deviceID)
        guard !channels.isEmpty else { return false }

        // Key channel volumes by actual element
        var currentByChannel: [UInt32: Float32] = [:]
        for ch in channels {
            var chAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: ch
            )
            guard AudioObjectHasProperty(deviceID, &chAddr) else { return false }
            var settable: DarwinBoolean = false
            AudioObjectIsPropertySettable(deviceID, &chAddr, &settable)
            guard settable.boolValue else { return false }

            var vol: Float32 = 1.0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(deviceID, &chAddr, 0, nil, &size, &vol) == noErr,
               vol.isFinite {
                currentByChannel[ch] = vol
            } else {
                return false
            }
        }

        let maxCurrent = currentByChannel.values.max() ?? 1.0

        for ch in channels {
            guard let cur = currentByChannel[ch] else { return false }
            let ratio = maxCurrent > 0.001 ? (cur / maxCurrent) : 1.0
            var chTarget = Float32(min(max(clamped * ratio, 0), 1))
            var chAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: ch
            )
            let size = UInt32(MemoryLayout<Float32>.size)
            let status = AudioObjectSetPropertyData(deviceID, &chAddr, 0, nil, size, &chTarget)
            guard status == noErr else {
                return false
            }
        }

        return true
    }

    func writeMuted(_ value: Bool, forDevice deviceID: AudioDeviceID) -> Bool {
        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &muteAddr) else { return false }
        var settable: DarwinBoolean = false
        AudioObjectIsPropertySettable(deviceID, &muteAddr, &settable)
        guard settable.boolValue else { return false }

        var muted: UInt32 = value ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectSetPropertyData(deviceID, &muteAddr, 0, nil, size, &muted) == noErr
    }

    private struct RegisteredListener {
        let address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    func addDefaultDeviceListener(_ block: @escaping () -> Void) -> Any? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listenerBlock: AudioObjectPropertyListenerBlock = { _, _ in
            block()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            listenerBlock
        )
        return status == noErr ? RegisteredListener(address: address, block: listenerBlock) : nil
    }

    func addDeviceListListener(_ block: @escaping () -> Void) -> Any? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listenerBlock: AudioObjectPropertyListenerBlock = { _, _ in
            block()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            listenerBlock
        )
        return status == noErr ? RegisteredListener(address: address, block: listenerBlock) : nil
    }

    func removeListener(_ token: Any) {
        guard let listener = token as? RegisteredListener else { return }
        var addr = listener.address
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            DispatchQueue.main,
            listener.block
        )
    }
}

enum AudioOutputController {
    static var backend: AudioSystemBackend = CoreAudioBackend.shared

    static func defaultOutputDeviceID() -> AudioDeviceID? {
        backend.defaultOutputDeviceID()
    }

    static func listOutputDevices() -> (devices: [AudioOutputDevice], defaultID: AudioDeviceID?) {
        backend.listOutputDevices()
    }

    static func symbolForDevice(_ device: AudioDeviceID, name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("headphone") || lower.contains("airpods max") || lower.contains("wh-") || lower.contains("quietcomfort") {
            return "headphones"
        }
        if lower.contains("airpod") {
            return "airpodspro"
        }
        if lower.contains("bose") || lower.contains("sony") || lower.contains("beats") {
            return "headphones"
        }

        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &transport) == noErr {
            switch transport {
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
                return "wave.3.right"
            case kAudioDeviceTransportTypeBuiltIn:
                return "laptopcomputer"
            case kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeHDMI:
                return "display"
            case kAudioDeviceTransportTypeAirPlay:
                return "airplayaudio"
            default:
                break
            }
        }

        if lower.contains("bluetooth") {
            return "wave.3.right"
        }

        if lower.contains("macbook") || lower.contains("internal") || lower.contains("speaker") {
            return "laptopcomputer"
        }
        return "speaker.wave.2.fill"
    }

    enum AudioOutputError: LocalizedError, Equatable {
        case disconnected
        case hardwareFailure
        case routeUnconfirmed

        var errorDescription: String? {
            switch self {
            case .disconnected:
                return "The selected sound device is no longer connected."
            case .hardwareFailure:
                return "Unable to switch sound output to this device."
            case .routeUnconfirmed:
                return "Sound output route could not be confirmed."
            }
        }
    }

    static func setDefaultOutputDevice(id: AudioDeviceID) -> Result<Void, AudioOutputError> {
        backend.setDefaultOutputDevice(id: id)
    }

    static func read(device: AudioDeviceID?) -> AudioCapabilities {
        backend.readCapabilities(device: device)
    }

    @discardableResult
    static func writeVolume(_ value: Double, forDevice deviceID: AudioDeviceID) -> Bool {
        backend.writeVolume(value, forDevice: deviceID)
    }

    @discardableResult
    static func writeMuted(_ value: Bool, forDevice deviceID: AudioDeviceID) -> Bool {
        backend.writeMuted(value, forDevice: deviceID)
    }
}

final class SystemControlCenter: ObservableObject {
    static let shared = SystemControlCenter()

    @Published private(set) var volume: Double = 0
    @Published private(set) var isMuted = false
    @Published private(set) var isVolumeAvailable = false
    @Published private(set) var isMuteAvailable = false
    @Published private(set) var audioControlsHint = "Loading audio settings…"

    @Published private(set) var outputDevices: [AudioOutputDevice] = []
    @Published private(set) var currentOutputDeviceID: AudioDeviceID?
    @Published private(set) var currentOutputDeviceUID: String?
    @Published private(set) var isSwitchingOutput = false
    @Published private(set) var outputSwitchError: String?

    @Published private(set) var displayBrightness = 0.72
    @Published private(set) var isDisplayBrightnessAvailable = false
    @Published private(set) var displayBrightnessHint = "Brightness is unavailable for this display"
    @Published private(set) var battery = BatterySnapshot()

    var currentOutputDevice: AudioOutputDevice? {
        guard let currentOutputDeviceID else { return nil }
        return outputDevices.first { $0.id == currentOutputDeviceID }
    }

    private var timer: Timer?
    private var isApplyingBrightness = false
    private var isApplyingAudio = false
    private var brightnessWrite: DispatchWorkItem?
    private var audioWriteItem: DispatchWorkItem?
    private var globalSystemKeyMonitor: Any?
    private var localSystemKeyMonitor: Any?
    private var lastSystemKeyEvent = Date.distantPast
    private var didLoadBattery = false
    private var targetDisplayID = CGMainDisplayID()

    private let backend: AudioSystemBackend
    private var refreshRevision: UInt64 = 0
    private var writeRevision: UInt64 = 0
    private var switchRevision: UInt64 = 0
    private let audioWorkQueue = DispatchQueue(label: "sidco.notch.audioWorkQueue", qos: .userInitiated)

    private var defaultDeviceListenerToken: Any?
    private var devicesListListenerToken: Any?

    init(backend: AudioSystemBackend = CoreAudioBackend.shared, startListeners: Bool = true) {
        self.backend = backend
        if startListeners {
            attachCoreAudioListeners()
            refresh()
            timer = Timer.scheduledTimer(withTimeInterval: 6.0, repeats: true) { [weak self] _ in
                self?.refresh()
            }
            globalSystemKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] event in
                self?.handleSystemKey(event)
            }
            localSystemKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .systemDefined) { [weak self] event in
                self?.handleSystemKey(event)
                return event
            }
        }
    }

    deinit {
        timer?.invalidate()
        detachCoreAudioListeners()
        if let globalSystemKeyMonitor { NSEvent.removeMonitor(globalSystemKeyMonitor) }
        if let localSystemKeyMonitor { NSEvent.removeMonitor(localSystemKeyMonitor) }
    }

    private func attachCoreAudioListeners() {
        if defaultDeviceListenerToken == nil {
            defaultDeviceListenerToken = backend.addDefaultDeviceListener { [weak self] in
                DispatchQueue.main.async {
                    self?.handleExternalRouteChange()
                }
            }
        }
        if devicesListListenerToken == nil {
            devicesListListenerToken = backend.addDeviceListListener { [weak self] in
                DispatchQueue.main.async {
                    self?.handleExternalRouteChange()
                }
            }
        }
    }

    private func detachCoreAudioListeners() {
        if let token = defaultDeviceListenerToken {
            backend.removeListener(token)
            defaultDeviceListenerToken = nil
        }
        if let token = devicesListListenerToken {
            backend.removeListener(token)
            devicesListListenerToken = nil
        }
    }

    private func handleExternalRouteChange() {
        if isSwitchingOutput {
            // Let the ongoing explicit switch finish and reconcile
            return
        }
        // Invalidate scheduled audio writes and clear audio busy state on external route change
        audioWriteItem?.cancel()
        audioWriteItem = nil
        writeRevision &+= 1
        isApplyingAudio = false
        refreshAudioState()
    }

    func selectOutputDevice(_ device: AudioOutputDevice) {
        // Guard against selecting when already switching or already on this device
        guard !isSwitchingOutput else { return }
        guard device.id != currentOutputDeviceID else { return }

        // Cancel pending audio writes, invalidate scheduled writes, and clear audio busy state
        audioWriteItem?.cancel()
        audioWriteItem = nil
        writeRevision &+= 1
        isApplyingAudio = false

        isSwitchingOutput = true
        outputSwitchError = nil
        switchRevision &+= 1
        let token = switchRevision
        let targetID = device.id
        let targetUID = device.uid

        audioWorkQueue.async { [weak self] in
            guard let self else { return }

            // Fresh backend listing to verify identity and check stable UID match before switching
            let freshListing = self.backend.listOutputDevices()
            guard freshListing.devices.contains(where: { $0.id == targetID && $0.uid == targetUID }) else {
                DispatchQueue.main.async {
                    guard self.switchRevision == token else { return }
                    self.outputSwitchError = AudioOutputController.AudioOutputError.disconnected.localizedDescription
                    self.isSwitchingOutput = false
                    self.refreshAudioState()
                }
                return
            }

            let result = self.backend.setDefaultOutputDevice(id: targetID)
            let listing = self.backend.listOutputDevices()
            let caps = self.backend.readCapabilities(device: listing.defaultID)

            DispatchQueue.main.async {
                guard self.switchRevision == token else { return }

                self.outputDevices = listing.devices
                self.currentOutputDeviceID = listing.defaultID
                self.currentOutputDeviceUID = listing.devices.first(where: { $0.id == listing.defaultID })?.uid

                self.volume = caps.volume
                self.isMuted = caps.isMuted
                self.isVolumeAvailable = caps.isVolumeAvailable
                self.isMuteAvailable = caps.isMuteAvailable
                self.audioControlsHint = caps.hint

                switch result {
                case .success:
                    self.outputSwitchError = nil
                case .failure(let error):
                    self.outputSwitchError = error.localizedDescription
                }

                // Busy state ends only after actual route and capabilities are refreshed
                self.isSwitchingOutput = false
            }
        }
    }

    func dismissOutputSwitchError() {
        outputSwitchError = nil
    }

    func refresh(showHUDFor systemKey: Int? = nil) {
        let displayID = targetDisplayID
        NotchSystemHelperClient.shared.currentBrightness(displayID: displayID) { [weak self] brightness in
            DispatchQueue.main.async {
                guard let self, displayID == self.targetDisplayID else { return }
                self.isDisplayBrightnessAvailable = brightness != nil
                if brightness == nil {
                    let isExternal = NSScreen.screens.first {
                        (($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0) == displayID
                    }?.safeAreaInsets.top == 0
                    self.displayBrightnessHint = isExternal
                        ? "External display • use its controls"
                        : "Brightness is unavailable for this display"
                } else {
                    self.displayBrightnessHint = ""
                }
                if !self.isApplyingBrightness, let brightness {
                    self.displayBrightness = max(0, min(1, brightness))
                }
            }
        }

        refreshAudioState(showHUDFor: systemKey)

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let battery = BatteryController.read()
            DispatchQueue.main.async {
                guard let self else { return }
                let previousBattery = self.battery
                self.battery = battery
                if self.didLoadBattery,
                   NotchModel.shared.showBattery,
                   (previousBattery.isCharging != battery.isCharging || previousBattery.isPluggedIn != battery.isPluggedIn) {
                    self.presentHUD(
                        symbol: battery.symbol,
                        title: battery.isCharging ? "Charging" : (battery.isPluggedIn ? "Power Adapter" : "Battery"),
                        value: battery.level
                    )
                }
                self.didLoadBattery = true
            }
        }
    }

    func refreshAudioState(showHUDFor systemKey: Int? = nil) {
        refreshRevision &+= 1
        let token = refreshRevision

        audioWorkQueue.async { [weak self] in
            guard let self else { return }
            let listing = self.backend.listOutputDevices()
            let caps = self.backend.readCapabilities(device: listing.defaultID)

            DispatchQueue.main.async {
                // Stale refresh must not overwrite newer state
                guard self.refreshRevision == token else { return }

                if !self.isSwitchingOutput {
                    self.outputDevices = listing.devices
                    self.currentOutputDeviceID = listing.defaultID
                    self.currentOutputDeviceUID = listing.devices.first(where: { $0.id == listing.defaultID })?.uid
                }

                if !self.isApplyingAudio && !self.isSwitchingOutput {
                    self.volume = caps.volume
                    self.isMuted = caps.isMuted
                    self.isVolumeAvailable = caps.isVolumeAvailable
                    self.isMuteAvailable = caps.isMuteAvailable
                    self.audioControlsHint = caps.hint
                }

                if let systemKey {
                    switch systemKey {
                    case 0, 1:
                        let symbol = self.isVolumeAvailable ? (self.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill") : "speaker.slash"
                        self.presentHUD(symbol: symbol, title: "Volume", value: (self.isMuted || !self.isVolumeAvailable) ? 0 : self.volume)
                    case 2, 3:
                        self.presentHUD(symbol: "sun.max.fill", title: "Display", value: self.displayBrightness)
                    case 7:
                        let symbol = self.isMuteAvailable && self.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"
                        self.presentHUD(symbol: symbol, title: self.isMuted ? "Muted" : "Volume", value: self.isMuted ? 0 : self.volume)
                    default:
                        break
                    }
                }
            }
        }
    }

    func updateTargetDisplay(_ displayID: CGDirectDisplayID) {
        guard displayID != 0, displayID != targetDisplayID else { return }
        targetDisplayID = displayID
        isDisplayBrightnessAvailable = false
        refresh()
    }

    private func handleSystemKey(_ event: NSEvent) {
        guard event.subtype.rawValue == 8 else { return }
        let keyState = (event.data1 & 0xFF00) >> 8
        guard keyState == 0x0A else { return }
        let keyCode = (event.data1 & 0xFFFF0000) >> 16
        guard [0, 1, 2, 3, 7].contains(keyCode) else { return }
        let now = Date()
        guard now.timeIntervalSince(lastSystemKeyEvent) > 0.035 else { return }
        lastSystemKeyEvent = now
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            self?.refresh(showHUDFor: keyCode)
        }
    }

    func setVolume(_ value: Double) {
        guard !isSwitchingOutput else { return }
        guard isVolumeAvailable,
              let targetDeviceID = currentOutputDeviceID,
              let targetUID = currentOutputDeviceUID,
              value.isFinite else { return }

        let clamped = max(0, min(1, value))
        volume = clamped
        isApplyingAudio = true
        let percent = Int((clamped * 100).rounded())
        presentHUD(symbol: "speaker.wave.2.fill", title: "Volume", value: clamped)

        audioWriteItem?.cancel()
        writeRevision &+= 1
        let token = writeRevision

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }

            var shouldProceed = false
            DispatchQueue.main.sync {
                if self.writeRevision == token &&
                    !self.isSwitchingOutput &&
                    self.currentOutputDeviceID == targetDeviceID &&
                    self.currentOutputDeviceUID == targetUID {
                    shouldProceed = true
                }
            }
            guard shouldProceed else {
                DispatchQueue.main.async {
                    if self.writeRevision == token {
                        self.isApplyingAudio = false
                    }
                }
                return
            }

            // Verify stable identity with fresh backend listing before write
            let freshListing = self.backend.listOutputDevices()
            guard freshListing.defaultID == targetDeviceID,
                  freshListing.devices.contains(where: { $0.id == targetDeviceID && $0.uid == targetUID }) else {
                DispatchQueue.main.async {
                    if self.writeRevision == token {
                        self.isApplyingAudio = false
                        self.refreshAudioState()
                    }
                }
                return
            }

            let success = self.backend.writeVolume(Double(percent) / 100, forDevice: targetDeviceID)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                guard self.writeRevision == token else { return }
                self.isApplyingAudio = false
                if !success {
                    self.outputSwitchError = "Unable to adjust volume on this device."
                    self.refreshAudioState()
                } else if self.currentOutputDeviceID != targetDeviceID || self.currentOutputDeviceUID != targetUID {
                    self.refreshAudioState()
                }
            }
        }
        audioWriteItem = work
        audioWorkQueue.asyncAfter(deadline: .now() + 0.045, execute: work)
    }

    func toggleMute() {
        guard !isSwitchingOutput else { return }
        guard isMuteAvailable,
              let targetDeviceID = currentOutputDeviceID,
              let targetUID = currentOutputDeviceUID else { return }

        // Cancel any pending volume block and invalidate previous writes
        audioWriteItem?.cancel()
        audioWriteItem = nil

        let newValue = !isMuted
        isMuted = newValue
        isApplyingAudio = true
        writeRevision &+= 1
        let token = writeRevision

        audioWorkQueue.async { [weak self] in
            guard let self else { return }

            var shouldProceed = false
            DispatchQueue.main.sync {
                if self.writeRevision == token &&
                    !self.isSwitchingOutput &&
                    self.currentOutputDeviceID == targetDeviceID &&
                    self.currentOutputDeviceUID == targetUID {
                    shouldProceed = true
                }
            }
            guard shouldProceed else {
                DispatchQueue.main.async {
                    if self.writeRevision == token {
                        self.isApplyingAudio = false
                    }
                }
                return
            }

            let freshListing = self.backend.listOutputDevices()
            guard freshListing.defaultID == targetDeviceID,
                  freshListing.devices.contains(where: { $0.id == targetDeviceID && $0.uid == targetUID }) else {
                DispatchQueue.main.async {
                    if self.writeRevision == token {
                        self.isApplyingAudio = false
                        self.refreshAudioState()
                    }
                }
                return
            }

            let success = self.backend.writeMuted(newValue, forDevice: targetDeviceID)
            DispatchQueue.main.async {
                guard self.writeRevision == token else { return }
                self.isApplyingAudio = false
                if success {
                    self.presentHUD(symbol: newValue ? "speaker.slash.fill" : "speaker.wave.2.fill", title: newValue ? "Muted" : "Volume", value: newValue ? 0 : self.volume)
                } else {
                    self.outputSwitchError = "Unable to change mute on this device."
                    self.refreshAudioState()
                }
            }
        }
    }

    func setDisplayBrightness(_ value: Double) {
        guard isDisplayBrightnessAvailable else { return }
        let displayID = targetDisplayID
        let clamped = max(0, min(1, value))
        displayBrightness = clamped
        isApplyingBrightness = true
        presentHUD(symbol: "sun.max.fill", title: "Display", value: clamped)
        brightnessWrite?.cancel()
        let work = DispatchWorkItem { [weak self] in
            NotchSystemHelperClient.shared.setBrightness(clamped, displayID: displayID) { success in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    guard let self else { return }
                    self.isDisplayBrightnessAvailable = success
                    self.isApplyingBrightness = false
                }
            }
        }
        brightnessWrite = work
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.045, execute: work)
    }

    private func presentHUD(symbol: String, title: String, value: Double) {
        NotchModel.shared.presentHUD(HUDState(symbol: symbol, title: title, value: value))
    }
}

struct CalendarEventItem: Identifiable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let calendarName: String
    let calendarColor: NSColor
    let isAllDay: Bool
}

struct ReminderItem: Identifiable {
    let id: String
    let title: String
    let dueDate: Date?
    let isCompleted: Bool
}

final class CalendarProvider: ObservableObject {
    static let shared = CalendarProvider()

    @Published private(set) var events: [CalendarEventItem] = []
    @Published private(set) var reminders: [ReminderItem] = []
    @Published private(set) var hasCalendarAccess = false
    @Published private(set) var hasReminderAccess = false
    @Published private(set) var isLoading = false
    @Published private(set) var selectedDate = Calendar.current.startOfDay(for: Date())

    private let store = EKEventStore()
    private var notificationToken: NSObjectProtocol?
    private var pendingLoads = 0

    private init() {
        notificationToken = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.refresh() }
        refresh()
    }

    @Published private(set) var calendarStatus: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    @Published private(set) var reminderStatus: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .reminder)

    deinit {
        if let notificationToken { NotificationCenter.default.removeObserver(notificationToken) }
    }

    func refresh() {
        let eventStatus = EKEventStore.authorizationStatus(for: .event)
        let remStatus = EKEventStore.authorizationStatus(for: .reminder)
        calendarStatus = eventStatus
        reminderStatus = remStatus
        hasCalendarAccess = Self.isAuthorized(eventStatus)
        hasReminderAccess = Self.isAuthorized(remStatus)
        pendingLoads = (hasCalendarAccess ? 1 : 0) + (hasReminderAccess ? 1 : 0)
        isLoading = pendingLoads > 0
        if hasCalendarAccess { loadEvents() } else { events = [] }
        if hasReminderAccess { loadReminders() }
        if !hasReminderAccess { reminders = [] }
    }

    func requestCalendarAccess() {
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents { [weak self] _, _ in DispatchQueue.main.async { self?.refresh() } }
        } else {
            store.requestAccess(to: .event) { [weak self] _, _ in DispatchQueue.main.async { self?.refresh() } }
        }
    }

    func requestReminderAccess() {
        if #available(macOS 14.0, *) {
            store.requestFullAccessToReminders { [weak self] _, _ in DispatchQueue.main.async { self?.refresh() } }
        } else {
            store.requestAccess(to: .reminder) { [weak self] _, _ in DispatchQueue.main.async { self?.refresh() } }
        }
    }

    func openCalendarSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    func openReminderSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
            NSWorkspace.shared.open(url)
        }
    }

    func selectDate(_ date: Date) {
        selectedDate = Calendar.current.startOfDay(for: date)
        if hasCalendarAccess {
            pendingLoads += 1
            isLoading = true
            loadEvents()
        }
    }

    func toggleReminder(_ item: ReminderItem) {
        guard hasReminderAccess,
              let reminder = store.calendarItem(withIdentifier: item.id) as? EKReminder else { return }
        reminder.isCompleted.toggle()
        reminder.completionDate = reminder.isCompleted ? Date() : nil
        do {
            try store.save(reminder, commit: true)
            refresh()
        } catch {
            NSLog("[Notch] Could not update reminder: %@", error.localizedDescription)
        }
    }

    private func loadEvents() {
        let start = Calendar.current.startOfDay(for: selectedDate)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let upcoming = store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(4)
            .map { event in
                CalendarEventItem(
                    id: event.eventIdentifier ?? "\(event.title ?? "Untitled event")-\(event.startDate.timeIntervalSince1970)",
                    title: event.title ?? "Untitled event",
                    startDate: event.startDate,
                    endDate: event.endDate,
                    calendarName: event.calendar.title,
                    calendarColor: event.calendar.color ?? .systemBlue,
                    isAllDay: event.isAllDay
                )
            }
        events = Array(upcoming)
        finishLoading()
    }

    private func loadReminders() {
        let predicate = store.predicateForReminders(in: nil)
        store.fetchReminders(matching: predicate) { [weak self] reminders in
            let list = (reminders ?? [])
                .filter { !$0.isCompleted }
                .sorted { ($0.dueDateComponents?.date ?? .distantFuture) < ($1.dueDateComponents?.date ?? .distantFuture) }
                .prefix(5)
                .map { reminder in
                    ReminderItem(
                        id: reminder.calendarItemIdentifier,
                        title: reminder.title ?? "Untitled reminder",
                        dueDate: reminder.dueDateComponents?.date,
                        isCompleted: reminder.isCompleted
                    )
                }
            DispatchQueue.main.async {
                self?.reminders = Array(list)
                self?.finishLoading()
            }
        }
    }

    private func finishLoading() {
        pendingLoads = max(0, pendingLoads - 1)
        isLoading = pendingLoads > 0
    }

    private static func isAuthorized(_ status: EKAuthorizationStatus) -> Bool {
        if #available(macOS 14.0, *) {
            return status == .fullAccess || status == .authorized
        } else {
            return status == .authorized
        }
    }
}

enum ShelfItemKind: String, Codable {
    case file
    case link
    case text
}

struct ShelfItem: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var path: String
    var bookmarkData: Data?
    var kind: ShelfItemKind? = nil

    var resolvedKind: ShelfItemKind { kind ?? .file }
    var isFile: Bool { resolvedKind != .link }
    var url: URL {
        resolvedKind == .link
            ? (URL(string: path) ?? URL(fileURLWithPath: path))
            : URL(fileURLWithPath: path)
    }
}

final class ShelfStore: ObservableObject {
    static let shared = ShelfStore()

    @Published var items: [ShelfItem] = []
    private let key = "notch.shelf.items"

    private init() {
        if !ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            load()
        }
    }

    func add(urls: [URL]) {
        var updated = items
        for url in urls where !updated.contains(where: { $0.path == url.path }) {
            let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            updated.append(ShelfItem(id: UUID(), name: url.lastPathComponent, path: url.path, bookmarkData: bookmark, kind: .file))
        }
        items = updated
        save()
    }

    func add(providers: [NSItemProvider], completion: @escaping () -> Void = {}) {
        let group = DispatchGroup()
        var dropped: [DroppedShelfContent] = []
        let lock = NSLock()
        for provider in providers {
            group.enter()
            Self.loadContent(from: provider) { content in
                if let content {
                    lock.lock()
                    dropped.append(content)
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            self?.add(contents: dropped)
            completion()
        }
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = "Add to Shelf"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK { add(urls: panel.urls) }
    }

    func remove(_ item: ShelfItem) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func clear() {
        items.removeAll()
        save()
    }

    func open(_ item: ShelfItem) {
        withScopedURL(item) { url in NSWorkspace.shared.open(url) }
    }

    func reveal(_ item: ShelfItem) {
        guard item.isFile else { return }
        withScopedURL(item) { url in NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    func quickLook(_ item: ShelfItem) {
        guard item.isFile else { open(item); return }
        withScopedURL(item) { ShelfQuickLookController.shared.show($0) }
    }

    func itemProvider(for item: ShelfItem) -> NSItemProvider {
        if item.resolvedKind == .link {
            return NSItemProvider(object: item.url as NSURL)
        }
        return NSItemProvider(contentsOf: item.url) ?? NSItemProvider(object: item.name as NSString)
    }

    func shareViaAirDrop(_ item: ShelfItem) {
        withScopedURL(item) { url in
            NSSharingService(named: .sendViaAirDrop)?.perform(withItems: [url])
        }
    }

    func shareViaAirDrop(providers: [NSItemProvider]) {
        let group = DispatchGroup()
        let lock = NSLock()
        var shareItems: [Any] = []
        for provider in providers {
            group.enter()
            Self.loadContent(from: provider) { content in
                if let content {
                    lock.lock()
                    switch content {
                    case .url(let url): shareItems.append(url)
                    case .text(let text): shareItems.append(text)
                    }
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            guard !shareItems.isEmpty else { return }
            NSSharingService(named: .sendViaAirDrop)?.perform(withItems: shareItems)
        }
    }

    private func withScopedURL(_ item: ShelfItem, action: (URL) -> Void) {
        var isStale = false
        var url = item.url
        if let bookmarkData = item.bookmarkData,
           let resolved = try? URL(resolvingBookmarkData: bookmarkData, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &isStale) {
            url = resolved
        }
        let didStart = url.startAccessingSecurityScopedResource()
        action(url)
        if didStart { url.stopAccessingSecurityScopedResource() }
    }

    private enum DroppedShelfContent {
        case url(URL)
        case text(String)
    }

    private func add(contents: [DroppedShelfContent]) {
        for content in contents {
            switch content {
            case .url(let url):
                if url.isFileURL { add(urls: [url]) } else { add(link: url) }
            case .text(let text):
                add(text: text)
            }
        }
    }

    private func add(link: URL) {
        let path = link.absoluteString
        guard !items.contains(where: { $0.path == path }) else { return }
        let host = link.host?.replacingOccurrences(of: "www.", with: "")
        let name = host?.isEmpty == false ? host! : (link.scheme?.uppercased() ?? "Link")
        items.append(ShelfItem(id: UUID(), name: name, path: path, bookmarkData: nil, kind: .link))
        save()
    }

    private func add(text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notch/Shelf Imports", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            let url = support.appendingPathComponent("Text Snippet \(UUID().uuidString.prefix(6)).txt")
            try value.write(to: url, atomically: true, encoding: .utf8)
            let displayName = value.components(separatedBy: .newlines).first.map { String($0.prefix(28)) } ?? "Text Snippet"
            items.append(ShelfItem(id: UUID(), name: displayName, path: url.path, bookmarkData: nil, kind: .text))
            save()
        } catch {
            NSLog("[Notch] Could not save dropped text: %@", error.localizedDescription)
        }
    }

    private static func loadContent(from provider: NSItemProvider, completion: @escaping (DroppedShelfContent?) -> Void) {
        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    completion(.url(url))
                } else {
                    loadFallbackText(from: provider, completion: completion)
                }
            }
            return
        }
        loadFallbackText(from: provider, completion: completion)
    }

    private static func loadFallbackText(from provider: NSItemProvider, completion: @escaping (DroppedShelfContent?) -> Void) {
        if provider.canLoadObject(ofClass: String.self) {
            _ = provider.loadObject(ofClass: String.self) { str, _ in
                if let str {
                    completion(.text(str))
                } else {
                    completion(nil)
                }
            }
            return
        }
        let textType = provider.hasItemConformingToTypeIdentifier(UTType.utf8PlainText.identifier)
            ? UTType.utf8PlainText.identifier
            : UTType.plainText.identifier
        guard provider.hasItemConformingToTypeIdentifier(textType) else {
            completion(nil)
            return
        }
        provider.loadDataRepresentation(forTypeIdentifier: textType) { data, _ in
            completion(data.flatMap { String(data: $0, encoding: .utf8) }.map(DroppedShelfContent.text))
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode([ShelfItem].self, from: data) else { return }
        items = saved
    }
}

struct QuickLaunchApp: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var path: String
    var bundleIdentifier: String?
}

final class AppLauncherStore: ObservableObject {
    static let shared = AppLauncherStore()

    @Published var apps: [QuickLaunchApp] = []
    private let key = "notch.launcher.apps"

    private init() {
        if !ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            load()
        }
        if apps.isEmpty {
            addDefaultApps()
        }
    }

    func pickAndAddApp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [UTType.application]
        panel.prompt = "Add to Notch"

        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK {
            for url in panel.urls {
                add(appAt: url)
            }
        }
    }

    func add(appAt url: URL) {
        guard !apps.contains(where: { $0.path == url.path }) else { return }
        let bundle = Bundle(url: url)
        let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        let bundleId = bundle?.bundleIdentifier
        let item = QuickLaunchApp(id: UUID(), name: name, path: url.path, bundleIdentifier: bundleId)
        apps.append(item)
        save()
    }

    func remove(_ app: QuickLaunchApp) {
        apps.removeAll { $0.id == app.id }
        save()
    }

    func launch(_ app: QuickLaunchApp) {
        let url = URL(fileURLWithPath: app.path)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(apps) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode([QuickLaunchApp].self, from: data) else { return }
        apps = saved.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func addDefaultApps() {
        let candidates = [
            "/System/Applications/Utilities/Terminal.app",
            "/Applications/Safari.app",
            "/System/Applications/Calculator.app",
            "/System/Applications/Notes.app"
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            add(appAt: URL(fileURLWithPath: path))
        }
    }
}

final class ShelfQuickLookController: NSObject, QLPreviewPanelDataSource {
    static let shared = ShelfQuickLookController()

    private var previewURL: NSURL?

    func show(_ url: URL) {
        previewURL = url as NSURL
        guard let panel = QLPreviewPanel.shared() else {
            NSWorkspace.shared.open(url)
            return
        }
        panel.dataSource = self
        panel.currentPreviewItemIndex = 0
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURL == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> any QLPreviewItem {
        previewURL!
    }
}

enum LaunchAtLoginController {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
