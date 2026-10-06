import AppKit
import AVFoundation
import Combine
import Darwin
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

@main
struct NotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Notch", systemImage: "sparkles") {
            MenuBarMenu()
        }
        .menuBarExtraStyle(.menu)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { SettingsWindowController.shared.show() }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

private final class SettingsHostingView: NSHostingView<SettingsView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    var isVisible: Bool { window?.isVisible == true }

    func show() {
        let settingsWindow: NSWindow
        if let window {
            settingsWindow = window
        } else {
            let newWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 556, height: 482),
                styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false
            )
            newWindow.contentView = SettingsHostingView(rootView: SettingsView())
            newWindow.title = "Notch Settings"
            newWindow.isReleasedWhenClosed = false
            newWindow.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 4)
            newWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            newWindow.setContentSize(NSSize(width: 556, height: 482))
            newWindow.center()
            newWindow.delegate = self
            window = newWindow
            settingsWindow = newWindow
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow, closingWindow === window else { return }
        closingWindow.contentView = nil
        window = nil
        updateAppActivationPolicy()
    }
}

@MainActor
private func updateAppActivationPolicy() {
    let hasVisibleWindow = SettingsWindowController.shared.isVisible
        || OnboardingWindowController.shared.isVisible
    NSApp.setActivationPolicy(hasVisibleWindow ? .regular : .accessory)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panelController: NotchPanelController?
    private var agentEdgeController: AgentEdgeController?
    private var reopenObserver: NSObjectProtocol?
    private var singleInstanceLockFD: Int32 = -1

    @MainActor @objc func showSettingsWindow(_ sender: Any?) {
        SettingsWindowController.shared.show()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let isTesting = ProcessInfo.processInfo.arguments.contains("--ui-testing")
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
        if !isTesting {
            if !acquireSingleInstance() {
                DistributedNotificationCenter.default().postNotificationName(
                    NSNotification.Name("sidco.notch.reopen"),
                    object: nil,
                    userInfo: nil,
                    deliverImmediately: true
                )
                exit(0)
            }

            reopenObserver = DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name("sidco.notch.reopen"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.panelController?.show()
                    NotchModel.shared.expandFull()
                }
            }
        }

        NSApp.setActivationPolicy(.accessory)
        panelController = NotchPanelController(model: .shared)
        panelController?.show()
        if !isTesting {
            agentEdgeController = AgentEdgeController()
            agentEdgeController?.start()
        }

        let hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        if !isTesting && !hasCompletedOnboarding {
            OnboardingWindowController.shared.show()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panelController?.show()
        NotchModel.shared.expandFull()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        SystemAudioSpectrumMonitor.shared.setPlaying(false)
        VoiceControlStore.shared.stop()
        AccessoryBatteryMonitor.shared.stopPolling()
        ClipboardStore.shared.stopMonitoringLifecycle()
        panelController?.close()
        agentEdgeController?.stop()
        AgentMonitor.shared.stop()
        if let reopenObserver {
            DistributedNotificationCenter.default().removeObserver(reopenObserver)
        }
        if singleInstanceLockFD >= 0 {
            close(singleInstanceLockFD)
            singleInstanceLockFD = -1
        }
    }

    private func acquireSingleInstance() -> Bool {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let bundleID = Bundle.main.bundleIdentifier ?? "sidco.notch"
        let otherApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != currentPID }
        if let existing = otherApps.first {
            existing.activate(options: [.activateIgnoringOtherApps])
            return false
        }

        let lockPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("sidco.notch.instance.lock")
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o666)
        guard fd >= 0 else { return true }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false
        }
        singleInstanceLockFD = fd
        return true
    }
}

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowController()
    private var window: NSWindow?
    var isVisible: Bool { window?.isVisible == true }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let onboardingView = OnboardingView { [weak self] in
            self?.close()
            Task { @MainActor in
                NotchModel.shared.updateVisible(true)
                NotchModel.shared.setExpanded(true)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if !NotchModel.shared.isPinned {
                    NotchModel.shared.setExpanded(false)
                }
            }
        }

        let hostingController = NSHostingController(rootView: onboardingView)
        let newWindow = NSWindow(contentViewController: hostingController)
        newWindow.title = "Welcome to Notch"
        newWindow.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        newWindow.titlebarAppearsTransparent = true
        newWindow.titleVisibility = .hidden
        newWindow.isReleasedWhenClosed = false
        newWindow.center()
        newWindow.delegate = self

        NSApp.setActivationPolicy(.regular)

        self.window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.orderOut(nil)
        window = nil
        updateAppActivationPolicy()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        updateAppActivationPolicy()
    }
}

private final class NotchFirstMouseHostingView: NSHostingView<NotchRootView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class NotchPanelController {
    private let model: NotchModel
    private let panel: NotchPanel
    private let hostingView: NSHostingView<NotchRootView>
    private var cancellables = Set<AnyCancellable>()
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var outsideClickMonitor: Any?
    private var currentScreenNumber: UInt32 = 0
    private var pendingScreenNumber: UInt32?
    private var displayTransferWorkItem: DispatchWorkItem?
    private var passThroughPollTimer: Timer?

    init(model: NotchModel) {
        self.model = model
        panel = NotchPanel(
            contentRect: NSRect(origin: .zero, size: model.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        hostingView = NotchFirstMouseHostingView(rootView: NotchRootView(model: model))

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.animationBehavior = .none
        panel.contentView = hostingView

        model.$sizePreset
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.resize(animated: true) }
            .store(in: &cancellables)

        // Mirror grows the panel downward to the camera's aspect; other modules keep the preset size.
        Publishers.CombineLatest3(model.$activeModule.removeDuplicates(), MirrorAspectStore.shared.$aspect.removeDuplicates(), model.$isAgentSidebarPresented.removeDuplicates())
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in self?.resize(animated: true) }
            .store(in: &cancellables)

        model.$isVisible
            .receive(on: RunLoop.main)
            .sink { [weak self] isVisible in
                if isVisible { self?.show() } else { self?.hide() }
            }
            .store(in: &cancellables)

        model.$followPointerDisplay
            .receive(on: RunLoop.main)
            .sink { [weak self] follows in
                if !follows { self?.cancelPendingDisplayTransfer() }
                self?.resize(animated: true)
            }
            .store(in: &cancellables)

        model.$isTucked
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateMousePassThrough() }
            .store(in: &cancellables)

        model.$expansionState
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateMousePassThrough() }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.checkFullScreenState() }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.checkFullScreenState() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.cancelPendingDisplayTransfer()
                self?.resize(animated: false)
                self?.checkFullScreenState()
            }
            .store(in: &cancellables)

        let pointerEvents: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .leftMouseUp, .rightMouseUp, .otherMouseUp
        ]
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: pointerEvents) { [weak self] _ in
            DispatchQueue.main.async { self?.handleMouseMovement() }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: pointerEvents) { [weak self] event in
            self?.takeKeyForExplicitClick(event)
            self?.handleMouseMovement(at: NSEvent.mouseLocation)
            return event
        }

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async {
                guard !ProcessInfo.processInfo.arguments.contains("--ui-testing") else { return }
                guard let self, self.model.isExpanded, !self.model.isPinned else { return }
                let mouseLoc = NSEvent.mouseLocation
                if !self.panel.frame.contains(mouseLoc) {
                    self.model.unlockAndCollapse()
                }
            }
        }

        checkFullScreenState()
        updateMousePassThrough()
    }

    deinit {
        passThroughPollTimer?.invalidate()
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        displayTransferWorkItem?.cancel()
    }

    func show() {
        guard model.isVisible else { return }
        resize(animated: false)
        panel.orderFrontRegardless()
        updateMousePassThrough()
    }

    func hide() {
        cancelPendingDisplayTransfer()
        panel.orderOut(nil)
    }

    func close() {
        panel.close()
    }

    private func resize(animated: Bool) {
        let screen = targetScreen()
        let geometry = DisplayNotchGeometry.read(from: screen)
        currentScreenNumber = geometry.screenNumber
        model.updateDisplayGeometry(geometry)
        checkFullScreenState()
        SystemControlCenter.shared.updateTargetDisplay(geometry.screenNumber)
        let frame = frameOnScreen(for: model.panelSize, screen: screen)
        let shouldAnimate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if shouldAnimate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.34
                context.allowsImplicitAnimation = true
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.78, 0.24, 1)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    private func targetScreen() -> NSScreen? {
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            return NSScreen.screens.first
        }
        let screens = NSScreen.screens
        let candidates = screens.map {
            DisplayScreenCandidate(
                number: screenNumber(for: $0),
                frame: $0.frame,
                hasHardwareNotch: $0.safeAreaInsets.top > 0
            )
        }
        let currentNumber = currentScreenNumber == 0 ? nil : currentScreenNumber
        let selectedNumber = DisplayScreenTargetPolicy.screenNumber(
            at: NSEvent.mouseLocation,
            screens: candidates,
            currentScreenNumber: currentNumber,
            followPointerDisplay: model.followPointerDisplay
        )
        return screens.first(where: { screenNumber(for: $0) == selectedNumber })
            ?? NSScreen.main
            ?? screens.first
    }

    private func screenNumber(for screen: NSScreen) -> UInt32 {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    private func frameOnScreen(for size: CGSize, screen: NSScreen?) -> NSRect {
        let frame = screen?.frame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(
            x: frame.midX - size.width / 2,
            y: frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    private func followPointerIfNeeded(at point: CGPoint) {
        guard model.followPointerDisplay, model.isVisible, NSEvent.pressedMouseButtons == 0,
              !isEditingText else {
            cancelPendingDisplayTransfer()
            return
        }
        let screenFrames = NSScreen.screens.map { (number: screenNumber(for: $0), frame: $0.frame) }
        let number = DisplayTransferPolicy.triggerScreenNumber(
            at: point,
            screens: screenFrames,
            currentScreenNumber: currentScreenNumber,
            triggerWidth: max(model.collapsedSize.width, 220)
        )
        guard let number, NSScreen.screens.contains(where: { screenNumber(for: $0) == number }) else {
            cancelPendingDisplayTransfer()
            return
        }
        guard pendingScreenNumber != number else { return }

        cancelPendingDisplayTransfer()
        pendingScreenNumber = number
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.model.followPointerDisplay, self.model.isVisible,
                  NSEvent.pressedMouseButtons == 0, !self.isEditingText,
                  let latestNumber = DisplayTransferPolicy.triggerScreenNumber(
                    at: NSEvent.mouseLocation,
                    screens: NSScreen.screens.map { (number: self.screenNumber(for: $0), frame: $0.frame) },
                    currentScreenNumber: self.currentScreenNumber,
                    triggerWidth: max(self.model.collapsedSize.width, 220)
                  ), latestNumber == number,
                  let screen = NSScreen.screens.first(where: { self.screenNumber(for: $0) == number }) else {
                self?.cancelPendingDisplayTransfer()
                return
            }
            let geometry = DisplayNotchGeometry.read(from: screen)
            guard geometry.screenNumber == number else {
                self.cancelPendingDisplayTransfer()
                return
            }
            self.transferPanel(to: screen, geometry: geometry)
        }
        displayTransferWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + DisplayTransferPolicy.dwellDuration, execute: workItem)
    }

    private var isEditingText: Bool {
        CompactShortcutController.isEditingText(in: NSApp.keyWindow)
    }

    private func cancelPendingDisplayTransfer() {
        displayTransferWorkItem?.cancel()
        displayTransferWorkItem = nil
        pendingScreenNumber = nil
    }

    private func transferPanel(to screen: NSScreen, geometry: DisplayNotchGeometry) {
        cancelPendingDisplayTransfer()
        currentScreenNumber = geometry.screenNumber
        model.updateDisplayGeometry(geometry)
        checkFullScreenState()
        SystemControlCenter.shared.updateTargetDisplay(geometry.screenNumber)
        panel.setFrame(frameOnScreen(for: model.panelSize, screen: screen), display: true)
        updateMousePassThrough()
    }

    /// The panel is sized for the fully expanded notch, but only the visible notch may take clicks:
    /// everywhere else in that box must reach the apps underneath.
    private func updateMousePassThrough(at point: CGPoint = NSEvent.mouseLocation) {
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            if panel.ignoresMouseEvents { panel.ignoresMouseEvents = false }
            passThroughPollTimer?.invalidate()
            passThroughPollTimer = nil
            return
        }

        let shouldIgnore: Bool
        if model.isTucked {
            shouldIgnore = true
        } else {
            let size = model.visibleSize
            let frame = panel.frame
            let margin: CGFloat = 10
            let active = NSRect(
                x: frame.midX - size.width / 2 - margin,
                y: frame.maxY - size.height - margin,
                width: size.width + margin * 2,
                height: size.height + margin
            )
            shouldIgnore = !active.contains(point)
        }
        if panel.ignoresMouseEvents != shouldIgnore { panel.ignoresMouseEvents = shouldIgnore }
        if shouldIgnore { relinquishKeyIfNeeded() }

        // While the panel holds the pointer, mouse-moved events may stop reaching our monitors,
        // so poll until the pointer leaves the notch and clicks pass through again.
        if shouldIgnore {
            passThroughPollTimer?.invalidate()
            passThroughPollTimer = nil
        } else if passThroughPollTimer == nil {
            let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateMousePassThrough() }
            }
            RunLoop.main.add(timer, forMode: .common)
            passThroughPollTimer = timer
        }
    }

    /// Hover never takes keyboard focus. An explicit click inside the expanded notch makes the
    /// non-activating panel key so local shortcuts such as Shift+= reach it; the frontmost app stays active.
    private func takeKeyForExplicitClick(_ event: NSEvent) {
        guard event.type == .leftMouseDown, event.window === panel, model.isExpanded, !panel.isKeyWindow else { return }
        panel.makeKey()
    }

    /// Once the pointer leaves the notch, hand keyboard focus back so typing returns to the frontmost app.
    /// Re-ordering the panel lets the window server restore the active app's key window.
    private func relinquishKeyIfNeeded() {
        guard panel.isKeyWindow, !isEditingText, model.isVisible else { return }
        panel.orderOut(nil)
        panel.orderFrontRegardless()
    }

    private func handleMouseMovement(at point: CGPoint = NSEvent.mouseLocation) {
        updateMousePassThrough(at: point)
        followPointerIfNeeded(at: point)
        handleFullScreenHoverIfNeeded()
    }

    private func handleFullScreenHoverIfNeeded() {
        guard model.autoHideInFullScreen, model.isScreenFullScreen else { return }
        let mouseLoc = NSEvent.mouseLocation
        let screen = targetScreen() ?? NSScreen.main
        guard let screen else { return }

        let triggerWidth = max(model.collapsedSize.width + 40, 260)
        let inHorizontalBand = abs(mouseLoc.x - screen.frame.midX) <= triggerWidth / 2
        let atTopEdge = mouseLoc.y >= screen.frame.maxY - 6 && mouseLoc.y <= screen.frame.maxY + 10

        if inHorizontalBand && atTopEdge {
            model.revealInFullScreen()
        } else if model.isRevealedInFullScreen && !model.isExpanded && !model.isPinned && !model.isLockedOpen {
            let activeHeight = model.visibleSize.height + 24
            let activeWidth = model.visibleSize.width + 48
            let notchRect = NSRect(
                x: screen.frame.midX - activeWidth / 2,
                y: screen.frame.maxY - activeHeight,
                width: activeWidth,
                height: activeHeight
            )
            if !notchRect.contains(mouseLoc) {
                model.scheduleFullScreenTuck()
            }
        }
    }

    private func checkFullScreenState() {
        let screen = NSScreen.screens.first(where: { screenNumber(for: $0) == currentScreenNumber }) ?? targetScreen()
        let isFullScreen = FullScreenDetector.isFullScreen(on: screen)
        model.updateScreenFullScreen(isFullScreen)
    }
}

struct MenuBarMenu: View {
    @ObservedObject private var model = NotchModel.shared
    @ObservedObject private var controls = SystemControlCenter.shared

    var body: some View {
        Button(model.isExpanded ? "Hide Notch" : "Show Notch") {
            model.setExpanded(!model.isExpanded)
            model.updateVisible(true)
        }
        .keyboardShortcut("n", modifiers: [.command, .option])

        Button(model.isPinned ? "Unpin from Top" : "Keep Open") {
            model.updatePinned(!model.isPinned)
            if model.isPinned { model.setExpanded(true) }
        }

        Divider()

        Menu("Open Module") {
            ForEach(NotchModule.allCases.filter { $0 != .toolkit || model.showToolkit }) { module in
                Button {
                    model.select(module)
                } label: {
                    Label(module.title, systemImage: module.symbol)
                }
            }
        }

        Toggle("Show Battery", isOn: Binding(
            get: { model.showBattery },
            set: { model.updateBattery($0) }
        ))

        if let current = controls.currentOutputDevice {
            if controls.isVolumeAvailable {
                Text("\(current.name) • Volume \(Int((controls.volume * 100).rounded()))%")
                    .foregroundStyle(.secondary)
            } else {
                Text("\(current.name) • Fixed volume")
                    .foregroundStyle(.secondary)
            }
        } else {
            if controls.isVolumeAvailable {
                Text("Volume \(Int((controls.volume * 100).rounded()))%")
                    .foregroundStyle(.secondary)
            } else {
                Text("Volume unavailable")
                    .foregroundStyle(.secondary)
            }
        }

        Divider()

        Button {
            OnboardingWindowController.shared.show()
        } label: {
            Label("Setup & Permissions…", systemImage: "sparkles")
        }

        Button {
            SettingsWindowController.shared.show()
        } label: {
            Label("Settings…", systemImage: "gearshape")
        }
        .buttonStyle(.plain)

        Button("Quit Notch") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

struct NotchRootView: View {
    @ObservedObject var model: NotchModel
    @StateObject private var nowPlaying = NowPlayingMonitor.shared
    @StateObject private var shelf = ShelfStore.shared
    @StateObject private var appLauncher = AppLauncherStore.shared
    @StateObject private var calendar = CalendarProvider.shared
    @StateObject private var controls = SystemControlCenter.shared
    @ObservedObject private var preferences = NotchDesignPreferences.shared
    @ObservedObject private var focus = FocusTimerStore.shared
    @ObservedObject private var voice = VoiceControlStore.shared
    @State private var isDropTargeted = false
    @State private var gestureTranslation: CGFloat = 0
    @State private var gestureThresholdReached = false
    @State private var hapticTrigger = 0
    @Namespace private var activityNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shape: NotchPanelShape {
        switch model.expansionState {
        case .collapsed:
            return NotchPanelShape(bottomRadius: 14)
        case .minimal:
            return NotchPanelShape(bottomRadius: 18)
        case .expanded:
            return NotchPanelShape(bottomRadius: 10)
        }
    }

    private var gestureScale: CGFloat {
        guard !reduceMotion else { return 1 }
        return 1 + min(abs(gestureTranslation) / 120, 1) * 0.025
    }

    var body: some View {
        ZStack(alignment: .top) {
            ZStack(alignment: .top) {
                switch model.expansionState {
                case .expanded:
                    IntegratedExpandedNotchView(
                        model: model,
                        nowPlaying: nowPlaying,
                        shelf: shelf,
                        appLauncher: appLauncher,
                        calendar: calendar,
                        controls: controls,
                        activityNamespace: activityNamespace
                    )
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.94, anchor: .top).combined(with: .opacity))
                case .minimal:
                    MinimalLiveActivityView(
                        model: model,
                        nowPlaying: nowPlaying,
                        controls: controls,
                        activityNamespace: activityNamespace
                    )
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.96, anchor: .top).combined(with: .opacity))
                case .collapsed:
                    if let hud = model.hud {
                        CompactHUDView(
                            state: hud,
                            coreWidth: model.coreNotchWidth,
                            wingWidth: model.sizePreset.wingWidth
                        )
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.94, anchor: .top).combined(with: .opacity))
                    } else {
                        CollapsedNotchView(
                            model: model,
                            nowPlaying: nowPlaying,
                            controls: controls,
                            activityNamespace: activityNamespace
                        )
                        .simultaneousGesture(verticalNotchGesture)
                        .transition(.opacity)
                    }
                }
            }
            .frame(width: model.visibleSize.width, height: model.visibleSize.height, alignment: .top)
            .background {
                NotchSurface(
                    expansionState: model.expansionState,
                    accent: model.activeModule == .nowPlaying ? (nowPlaying.dynamicAccentColor ?? NotchModule.nowPlaying.tint) : model.activeModule.tint
                )
            }
            .clipShape(shape)
            .overlay {
                shape
                    .stroke(.white.opacity(model.expansionState == .collapsed ? 0 : (model.expansionState == .minimal ? 0.12 : 0.08)), lineWidth: 0.75)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(.black)
                    .frame(height: 1.5)
                    .padding(.horizontal, model.expansionState == .expanded ? 19 : (model.expansionState == .minimal ? 12 : 6))
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(model.expansionState == .collapsed ? 0 : 0.55), radius: model.expansionState == .minimal ? 10 : 14, y: 6)
            .scaleEffect(gestureScale, anchor: .top)
            .offset(y: model.isTucked ? -model.visibleSize.height - 12 : 0)
            .opacity(model.isTucked ? 0 : (reduceMotion ? 1 : 1 - min(abs(gestureTranslation) / 900, 0.08)))
            .tint(model.activeModule == .shelf ? NotchModule.shelf.tint : (model.activeModule == .apps ? NotchModule.apps.tint : (nowPlaying.dynamicAccentColor ?? NotchModule.nowPlaying.tint)))
            .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.82), value: model.isTucked)
            .animation(
                reduceMotion ? nil : (
                    model.expansionState == .collapsed
                        ? NotchMotion.collapse
                        : NotchMotion.expand
                ),
                value: model.expansionState
            )
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.hud?.id)
            .onHover { isInside in
                if isInside { model.pointerEntered() } else { model.pointerExited() }
            }
            .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText], isTargeted: $isDropTargeted) { providers in
                guard model.showShelf, !providers.isEmpty else { return false }
                shelf.add(providers: providers) { model.openShelf() }
                return true
            }
            .overlay {
                if isDropTargeted {
                    shape
                        .stroke(NotchModule.shelf.tint, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                        .padding(2)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottom) {
                if model.expansionState == .expanded && preferences.festiveLights {
                    FestiveNotchLights().offset(y: 11)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if isDropTargeted && preferences.dropPaw {
                    Image(systemName: "pawprint.fill").foregroundStyle(.cyan)
                        .padding(10).allowsHitTesting(false).accessibilityHidden(true)
                        .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
                }
            }
        }
        .frame(width: model.panelSize.width, height: model.panelSize.height, alignment: .top)
        .preferredColorScheme(.dark)
        .sensoryFeedback(.alignment, trigger: hapticTrigger)
        .onChange(of: model.expansionState) { _, state in if state != .expanded { voice.stop() } }
        .onChange(of: model.isVisible) { _, visible in if !visible { voice.stop() } }
        .onChange(of: focus.isFinished) { old, finished in
            if finished && !old { model.presentHUD(HUDState(symbol: "checkmark.circle.fill", title: "Focus complete", value: 1)) }
        }
    }

    private var verticalNotchGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard allowsPanelDrag else { return }
                guard abs(value.translation.height) > abs(value.translation.width) * 1.2 else { return }
                let validTranslation = model.expansionState == .expanded
                    ? min(value.translation.height, 0)
                    : max(value.translation.height, 0)
                gestureTranslation = validTranslation

                let passedThreshold = abs(validTranslation) > 48
                if passedThreshold && !gestureThresholdReached {
                    gestureThresholdReached = true
                    if model.hapticsEnabled { hapticTrigger += 1 }
                } else if !passedThreshold {
                    gestureThresholdReached = false
                }
            }
            .onEnded { value in
                guard allowsPanelDrag else {
                    gestureTranslation = 0
                    gestureThresholdReached = false
                    return
                }
                let intent = NotchDragIntent.vertical(value.translation, isExpanded: model.expansionState == .expanded)
                withAnimation(reduceMotion ? nil : NotchMotion.expand) {
                    gestureTranslation = 0
                    if intent == .expand { model.expandFull() }
                    if intent == .collapse { model.unlockAndCollapse() }
                }
                gestureThresholdReached = false
            }
    }

    private var allowsPanelDrag: Bool {
        model.expansionState != .expanded || model.activeModule != .toolkit
    }
}

struct CollapsedNotchView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var nowPlaying: NowPlayingMonitor
    @ObservedObject var controls: SystemControlCenter
    let activityNamespace: Namespace.ID
    @ObservedObject private var focus = FocusTimerStore.shared
    @ObservedObject private var agents = AgentMonitor.shared
    @ObservedObject private var preferences = NotchDesignPreferences.shared

    var body: some View {
        Button {
            guard model.interaction.expandsOnClick else { return }
            model.toggleExpanded()
        } label: {
            HStack(spacing: 0) {
                HStack {
                    CollapsedMediaBadge(song: nowPlaying.song)
                    .matchedGeometryEffect(id: "activity-artwork", in: activityNamespace, isSource: true)
                    .frame(width: 20, height: 20)
                    .padding(.trailing, 6)
                }
                .frame(width: model.sizePreset.wingWidth, alignment: .trailing)

                Color.clear
                    .frame(width: model.coreNotchWidth)

                HStack {
                    if focus.isRunning {
                        Text(focus.formattedRemaining).font(.system(size: 10, weight: .semibold, design: .rounded))
                            .monospacedDigit().foregroundStyle(.mint).padding(.leading, 4)
                    } else if preferences.assistantActivity && agents.activeCount > 0 && !nowPlaying.song.isPlaying {
                        Image(systemName: agents.sessions.contains { $0.status == .waiting } ? "questionmark.circle.fill" : "sparkles")
                            .font(.system(size: 11)).foregroundStyle(.purple).padding(.leading, 6)
                    } else if model.showVisualizer {
                        MiniVisualizer(isPlaying: nowPlaying.song.isPlaying)
                            .matchedGeometryEffect(id: "activity-spectrum", in: activityNamespace, isSource: true)
                            .frame(width: 28, height: 18)
                            .padding(.leading, 6)
                    } else if model.showBattery {
                        Image(systemName: controls.battery.symbol)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(controls.battery.isCharging ? .green : .white.opacity(0.7))
                    } else {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
                .frame(width: model.sizePreset.wingWidth, alignment: .leading)
            }
            .frame(width: model.collapsedSize.width, height: model.collapsedSize.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open Now Playing") { model.select(.nowPlaying) }
            Button("Open Shelf") { model.select(.shelf) }
            Button("Open Workspace") { model.select(.workspace) }
            Divider()
            Button(model.isPinned ? "Unpin" : "Keep Open") { model.updatePinned(!model.isPinned) }
            Button("Settings…") { SettingsWindowController.shared.show() }
        }
        .accessibilityIdentifier("collapsed-notch")
        .accessibilityLabel(nowPlaying.song.hasTrack ? "Notch, \(nowPlaying.song.title), \(nowPlaying.song.artist)" : "Notch")
        .accessibilityHint(interactionHint)
    }

    private var interactionHint: String {
        switch model.interaction {
        case .hover: return "Hover or pull down to open"
        case .click: return "Click or pull down to open"
        case .hoverAndClick: return "Hover, click, or pull down to open"
        }
    }
}

struct CollapsedMediaBadge: View {
    let song: NowPlayingSong

    var body: some View {
        ZStack {
            if let artwork = song.artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle()
                    .fill(.white.opacity(song.hasTrack ? 0.13 : 0.075))
                Image(systemName: song.hasTrack ? "music.note" : "waveform")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(song.hasTrack ? 0.82 : 0.42))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: song.artwork == nil ? 10 : 5, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: song.artwork == nil ? 10 : 5, style: .continuous)
                .stroke(.white.opacity(0.13), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
        .accessibilityHidden(true)
    }
}

struct IntegratedExpandedNotchView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var nowPlaying: NowPlayingMonitor
    @ObservedObject var shelf: ShelfStore
    @ObservedObject var appLauncher: AppLauncherStore
    @ObservedObject var calendar: CalendarProvider
    @ObservedObject var controls: SystemControlCenter
    let activityNamespace: Namespace.ID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var compactShortcut = CompactShortcutController()

    var body: some View {
        NotchToolRail(left: leftRail, right: rightRail, bottom: bottomRail, rail: model.railThickness) {
            VStack(spacing: ExpandedPanelLayout.verticalGap) {
                let cameraHeaderWidth = hardwareCameraHeight > 0 ? model.coreNotchWidth : 0
                let headerWingWidth = ExpandedPanelLayout.headerWingWidth(
                    expandedWidth: model.expandedSize.width,
                    cameraWidth: cameraHeaderWidth,
                    railThickness: model.railThickness
                )
                HStack(spacing: 0) {
                    Text(activeDestinationTitle)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(1)
                        .frame(width: headerWingWidth, alignment: .leading)
                    Color.clear.frame(width: cameraHeaderWidth)
                    HStack(spacing: 6) {
                        if let hud = model.hud { InlineHeaderHUD(state: hud) }
                        Phase6AgentSidebarButton(monitor: AgentMonitor.shared, isPresented: $model.isAgentSidebarPresented)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(model.isAgentSidebarPresented ? 0.9 : 0.58))
                        PinLeverView(isPinned: Binding(get: { model.isPinned },
                                                       set: { model.updatePinned($0) }))
                    }
                    .frame(width: headerWingWidth, alignment: .trailing)
                }
                .frame(height: max(ExpandedPanelLayout.headerHeight, hardwareCameraHeight))
                .overlay {
                    if hardwareCameraHeight > 0 {
                        NotchCameraOutline()
                            .stroke(.white.opacity(0.20), lineWidth: 0.8)
                            .frame(width: model.coreNotchWidth, height: hardwareCameraHeight)
                            .allowsHitTesting(false)
                    }
                }

                // Agents take their own column (or a section below); the destination keeps its width and state.
                let destinationWidth = model.sizePreset.expandedSize.width - model.railThickness * 2 - 24
                HStack(alignment: .top, spacing: AgentColumnLayout.gap) {
                    VStack(spacing: AgentColumnLayout.gap) {
                        moduleContent
                            .id(model.activeModule.rawValue)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        if model.showsAgentsBelow {
                            agentSection.frame(height: AgentColumnLayout.belowHeight)
                        }
                    }
                    .frame(width: model.showsAgentColumn ? destinationWidth : nil)
                    if model.showsAgentColumn {
                        agentSection.frame(width: AgentColumnLayout.width)
                    }
                }
                .animation(reduceMotion ? nil : NotchMotion.content, value: model.isAgentSidebarPresented)
            }
            .padding(.horizontal, 12)
            .padding(.top, ExpandedPanelLayout.topPadding)
            .padding(.bottom, ExpandedPanelLayout.bottomPadding)
        }
        .frame(width: model.expandedSize.width, height: model.expandedSize.height)
        .overlay(alignment: .bottom) {
            DoubleClickCloseHandle { model.unlockAndCollapse() }
                .simultaneousGesture(verticalNotchGesture)
                .padding(.bottom, model.railThickness + 2)
        }
        .contextMenu {
            Button { SettingsWindowController.shared.show() } label: {
                Label("Settings…", systemImage: "gearshape")
            }
                .accessibilityIdentifier("settings-button")
            Button(model.isPinned ? "Unpin notch" : "Keep open") {
                model.updatePinned(!model.isPinned)
            }
            Button("Collapse notch") { model.unlockAndCollapse() }
        }
        .animation(reduceMotion ? nil : NotchMotion.content, value: model.activeModule)
        .onAppear { compactShortcut.install { model.collapseFromShortcut() } }
        .onDisappear { compactShortcut.removeMonitor() }
    }

    private func moduleKey(_ module: NotchModule, title: String? = nil, symbol: String? = nil) -> NotchRailItem {
        NotchRailItem(id: "module-\(module.rawValue)", symbol: symbol ?? module.symbol,
                      title: title ?? module.title, tint: module.tint, isSelected: model.activeModule == module) {
            model.select(module)
        }
    }

    private var hardwareCameraHeight: CGFloat {
        ExpandedPanelLayout.cameraSafeHeight(for: model.displayGeometry)
    }

    private var activeDestinationTitle: String {
        switch model.activeModule {
        case .workspace: return model.workspaceSection.title
        case .toolkit: return model.toolkitPage.title
        default: return model.activeModule.title
        }
    }

    private var verticalNotchGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onEnded { value in
                guard NotchDragIntent.vertical(value.translation, isExpanded: true) == .collapse else { return }
                model.unlockAndCollapse()
            }
    }

    private var leftRail: [NotchRailItem] {
        [moduleKey(.nowPlaying, title: "Now Playing", symbol: "music.note"),
         model.showShelf ? moduleKey(.shelf, symbol: "tray.fill") : blankKey("module-shelf"),
         moduleKey(.apps)]
    }

    private var rightRail: [NotchRailItem] {
        [moduleKey(.controls), moduleKey(.mirror),
         NotchRailItem(id: "rail-settings", symbol: "gearshape", title: "Settings") {
            SettingsWindowController.shared.show()
         }]
    }

    /// Sound, Keep Awake and voice live inside Controls beside their related settings,
    /// so the bottom row keeps only destinations without a home elsewhere.
    private var bottomRail: [NotchRailItem] {
        var calendar = model.showCalendar ? moduleKey(.calendar) : blankKey("module-calendar")
        calendar.weight = 1.5
        var items = [calendar]
        for section in [WorkspaceSection.focus, .calls] {
            items.append(NotchRailItem(id: "rail-\(section.rawValue)", symbol: section.symbol,
                                       title: section.title, tint: section.tint,
                                       isSelected: model.activeModule == .workspace && model.workspaceSection == section) {
                model.workspaceSection = section
                model.select(.workspace)
            })
        }
        items.append(model.showToolkit
            ? NotchRailItem(id: "rail-notes", symbol: NotchToolkitPage.notes.symbol, title: NotchToolkitPage.notes.title,
                            isSelected: model.activeModule == .toolkit) { model.openTool(.notes) }
            : blankKey("rail-notes"))
        return items
    }

    private func blankKey(_ id: String) -> NotchRailItem {
        NotchRailItem(id: id, symbol: "", title: "", isEnabled: false, action: {})
    }

    private var agentSection: some View {
        Phase6AgentSidebarView(monitor: AgentMonitor.shared) { model.isAgentSidebarPresented = false }
            .frame(maxHeight: .infinity)
            .transition(.opacity)
    }

    @ViewBuilder
    private var moduleContent: some View {
        switch model.activeModule {
        case .nowPlaying:
            IntegratedMusicView(
                nowPlaying: nowPlaying,
                availableHeight: ExpandedPanelLayout.contentHeight(
                    expandedHeight: model.expandedSize.height,
                    railThickness: model.railThickness,
                    geometry: model.displayGeometry
                ) - (model.showsAgentsBelow ? AgentColumnLayout.belowHeight + AgentColumnLayout.gap : 0),
                activityNamespace: activityNamespace,
                hapticsEnabled: model.hapticsEnabled
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .accessibilityIdentifier("home-panel")
        case .calendar:
            CompactCalendarPane(provider: calendar, hapticsEnabled: model.hapticsEnabled)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .controls:
            CompactControlsPane(controls: controls)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .mirror:
            CompactMirrorPane()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .shelf:
            Phase6ShelfOverview(shelf: shelf)
                .transition(NotchMotion.transition(direction: model.navigationDirection, reduced: reduceMotion))
        case .apps:
            IntegratedAppsView(store: appLauncher)
                .transition(NotchMotion.transition(direction: model.navigationDirection, reduced: reduceMotion))
        case .workspace:
            WorkspaceView(model: model)
                .transition(NotchMotion.transition(direction: model.navigationDirection, reduced: reduceMotion))
        case .toolkit:
            if model.showToolkit {
                NotchToolkitView(page: model.toolkitPage)
                    .id(model.toolkitPage)
                    .transition(NotchMotion.transition(direction: model.navigationDirection, reduced: reduceMotion))
            }
        }
    }
}

struct DoubleClickCloseHandle: View {
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Capsule()
            .fill(.white.opacity(hovered ? 0.38 : 0))
            .frame(width: hovered ? 48 : 38, height: 3)
            .frame(width: 156, height: 15)
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: action)
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovered)
            .help("Double-click to close")
            .accessibilityElement()
            .accessibilityLabel("Close notch")
            .accessibilityHint("Double-click to close")
            .accessibilityIdentifier("double-click-close-handle")
            .accessibilityAction(named: "Close notch") { action() }
    }
}

struct IntegratedNotchHeader: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var nowPlaying: NowPlayingMonitor
    @ObservedObject var controls: SystemControlCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            let cameraWidth = min(model.coreNotchWidth, model.expandedSize.width * 0.36)
            let wingWidth = (model.expandedSize.width - cameraWidth - 24) / 2
            HStack(spacing: 7) {
                Image(systemName: "sparkles").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                Text("NOTCH").font(.system(size: 9, weight: .semibold)).tracking(1.4)
                Text("/").foregroundStyle(.white.opacity(0.2))
                Text(model.activeModule == .toolkit ? model.toolkitPage.title : model.activeModule.title)
                    .font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
                .frame(width: wingWidth, alignment: .leading)

            Color.clear
                .frame(width: cameraWidth)

            HStack(spacing: 4) {
                if let hud = model.hud {
                    InlineHeaderHUD(state: hud)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }

                HeaderIconButton(symbol: model.isPinned ? "pin.fill" : "pin", label: model.isPinned ? "Unpin notch" : "Keep open", selected: model.isPinned, tint: .white) {
                    model.updatePinned(!model.isPinned)
                }

                Button { SettingsWindowController.shared.show() } label: {
                    Image(systemName: "gearshape")
                }
                    .buttonStyle(ChromeButtonStyle(size: 24))
                    .help("Settings")
                    .accessibilityIdentifier("settings-button")

                Button { model.unlockAndCollapse() } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(ChromeButtonStyle(size: 24))
                .help("Collapse notch")
                .accessibilityLabel("Collapse notch")
            }
            .frame(width: wingWidth, alignment: .trailing)
            .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: model.hud?.id)
        }
        .padding(.horizontal, 12)
    }
}

struct PrimaryNotchTabs: View {
    @ObservedObject var model: NotchModel
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            tab(title: "Home", symbol: "house.fill", selected: ![NotchModule.shelf, .apps, .workspace, .toolkit].contains(model.activeModule)) {
                model.select(.nowPlaying)
            }
            .accessibilityIdentifier("module-nowPlaying")

            if model.showShelf {
                tab(title: "Shelf", symbol: "tray.fill", selected: model.activeModule == .shelf) {
                    model.select(.shelf)
                }
                .accessibilityIdentifier("module-shelf")
            }

            tab(title: "Apps", symbol: "square.grid.2x2.fill", selected: model.activeModule == .apps) {
                model.select(.apps)
            }
            .accessibilityIdentifier("module-apps")
        }
        .padding(2)
        .background(.white.opacity(0.045), in: Capsule())
    }

    private func tab(title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if compact { Image(systemName: symbol) }
                else { Label(title, systemImage: symbol) }
            }
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(selected ? .white : .white.opacity(0.48))
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(selected ? .white.opacity(0.12) : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .help(title)
        .animation(reduceMotion ? nil : NotchMotion.press, value: selected)
    }
}

struct HeaderIconButton: View {
    let symbol: String
    let label: String
    let selected: Bool
    let tint: Color
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 24, height: 24)
                .foregroundStyle(selected ? .white : .white.opacity(hovered ? 0.72 : 0.46))
                .background(selected ? tint.opacity(0.28) : .white.opacity(hovered ? 0.08 : 0.035), in: Circle())
                .overlay(Circle().stroke(selected ? tint.opacity(0.42) : .clear, lineWidth: 0.75))
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovered)
        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: selected)
    }
}

struct InlineHeaderHUD: View {
    let state: HUDState

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: state.symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 14)
            ProgressView(value: state.value)
                .controlSize(.mini)
                .frame(width: 58)
            Text("\(Int((state.value * 100).rounded()))%")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.58))
                .frame(width: 28, alignment: .trailing)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(.white.opacity(0.075), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(state.title), \(Int((state.value * 100).rounded())) percent")
    }
}

struct IntegratedHomeView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var nowPlaying: NowPlayingMonitor
    @ObservedObject var calendar: CalendarProvider
    @ObservedObject var controls: SystemControlCenter
    let activityNamespace: Namespace.ID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let accessoryWidth = min(228, max(184, geometry.size.width * 0.35))
            HStack(spacing: 12) {
                IntegratedMusicView(
                    nowPlaying: nowPlaying,
                    availableHeight: geometry.size.height,
                    activityNamespace: activityNamespace,
                    hapticsEnabled: model.hapticsEnabled
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Rectangle()
                    .fill(.white.opacity(0.08))
                    .frame(width: 1)
                    .padding(.vertical, 3)

                Group {
                    switch model.activeModule {
                    case .controls:
                        CompactControlsPane(controls: controls)
                    case .mirror:
                        CompactMirrorPane()
                    default:
                        if model.showCalendar {
                            CompactCalendarPane(provider: calendar, hapticsEnabled: model.hapticsEnabled)
                        } else {
                            CompactControlsPane(controls: controls)
                        }
                    }
                }
                .id(model.activeModule == .nowPlaying ? NotchModule.calendar : model.activeModule)
                .frame(width: accessoryWidth)
                .frame(maxHeight: .infinity)
                .transition(reduceMotion ? .opacity : .scale(scale: 0.96).combined(with: .opacity))
                .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: model.activeModule)
            }
        }
    }
}

enum NotchDragIntent: Equatable {
    case expand, collapse, next, previous

    static func vertical(_ translation: CGSize, isExpanded: Bool) -> Self? {
        guard abs(translation.height) > abs(translation.width) * 1.2 else { return nil }
        if !isExpanded && translation.height > 40 { return .expand }
        if isExpanded && translation.height < -40 { return .collapse }
        return nil
    }

    static func track(_ translation: CGSize, hasTrack: Bool) -> Self? {
        guard hasTrack, abs(translation.width) > abs(translation.height) * 1.4 else { return nil }
        if translation.width < -48 { return .next }
        if translation.width > 48 { return .previous }
        return nil
    }
}

struct IntegratedShelfView: View {
    @ObservedObject var store: ShelfStore
    var compact = false
    @State private var shelfTargeted = false
    @State private var shareTargeted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let acceptedTypes: [UTType] = [.fileURL, .url, .utf8PlainText, .plainText]

    var body: some View {
        if compact {
            compactBody
        } else {
            standardBody
        }
    }

    private var standardBody: some View {
        HStack(spacing: 10) {
            VStack(spacing: 7) {
                Image(systemName: shareTargeted ? "airplayaudio.circle.fill" : "square.and.arrow.up")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(shareTargeted ? NotchModule.shelf.tint : .white.opacity(0.62))
                    .symbolEffect(.bounce, value: reduceMotion ? false : shareTargeted)
                Text("Quick Share")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                Text("Drop for AirDrop")
                    .font(.system(size: 8, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.38))
            }
            .frame(width: 126)
            .frame(maxHeight: .infinity)
            .background(.white.opacity(shareTargeted ? 0.09 : 0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(shareTargeted ? NotchModule.shelf.tint : .white.opacity(0.09), style: StrokeStyle(lineWidth: shareTargeted ? 2 : 1, dash: [7, 5]))
            }
            .onDrop(of: acceptedTypes, isTargeted: $shareTargeted) { providers in
                store.shareViaAirDrop(providers: providers)
                return true
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Shelf")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                        Text(store.items.isEmpty ? "Drop files, links, or text" : "\(store.items.count) ready to use")
                            .font(.system(size: 8, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.42))
                    }
                    Spacer()
                    if !store.items.isEmpty {
                        Button("Clear") { store.clear() }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                    }
                    Button { store.chooseFiles() } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }

                if store.items.isEmpty {
                    VStack(spacing: 5) {
                        Image(systemName: shelfTargeted ? "arrow.down.circle.fill" : "tray.and.arrow.down.fill")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(shelfTargeted ? NotchModule.shelf.tint : .white.opacity(0.52))
                        Text(shelfTargeted ? "Release to keep" : "Drop anything here for later")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.white.opacity(shelfTargeted ? 0.08 : 0.035), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(.white.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: [7, 5])))
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 7) {
                            ForEach(store.items) { item in
                                CompactShelfTile(item: item, store: store)
                            }
                        }
                    }
                }
            }
            .onDrop(of: acceptedTypes, isTargeted: $shelfTargeted) { providers in
                store.add(providers: providers)
                return true
            }
        }
        .accessibilityIdentifier("shelf-files-panel")
    }

    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Text(store.items.isEmpty ? "No files yet" : "\(store.items.count) items")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.72)).lineLimit(1)
                Spacer(minLength: 0)
                Button { store.chooseFiles() } label: { Label("Add", systemImage: "plus") }
                    .controlSize(.mini).accessibilityIdentifier("shelf-add-files")
                if !store.items.isEmpty {
                    Button("Clear") { store.clear() }
                        .controlSize(.mini).accessibilityIdentifier("shelf-clear-files")
                }
            }

            HStack(spacing: 7) {
                Image(systemName: shareTargeted ? "airplayaudio.circle.fill" : "square.and.arrow.up")
                    .foregroundStyle(shareTargeted ? NotchModule.shelf.tint : .white.opacity(0.68))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Quick Share").font(.system(size: 10, weight: .semibold, design: .rounded))
                    Text("Drop for AirDrop").font(.system(size: 10, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.45))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
            .background(.white.opacity(shareTargeted ? 0.09 : 0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(shareTargeted ? NotchModule.shelf.tint : .white.opacity(0.09), style: StrokeStyle(lineWidth: shareTargeted ? 2 : 1, dash: [5, 4])))
            .onDrop(of: acceptedTypes, isTargeted: $shareTargeted) { providers in
                store.shareViaAirDrop(providers: providers)
                return true
            }

            Group {
                if store.items.isEmpty {
                    Text("Drop anything here for later, or choose Add.")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        .background(.white.opacity(shelfTargeted ? 0.08 : 0.035), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 6) {
                            ForEach(store.items) { item in
                                CompactShelfTile(item: item, store: store, compact: true)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
            .frame(height: 104)
            .onDrop(of: acceptedTypes, isTargeted: $shelfTargeted) { providers in
                store.add(providers: providers)
                return true
            }
        }
        .accessibilityIdentifier("shelf-files-panel-compact")
    }
}

struct CompactShelfTile: View {
    let item: ShelfItem
    @ObservedObject var store: ShelfStore
    var compact = false
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 4) {
            ShelfThumbnailView(item: item)
                .frame(width: compact ? 40 : 52, height: compact ? 40 : 52)
            Text(item.name)
                .font(.system(size: compact ? 10 : 8, weight: .medium, design: .rounded))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: compact ? 88 : 78, height: compact ? 26 : 22, alignment: .top)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 7)
        .background(.white.opacity(hovered ? 0.085 : 0.035), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(.white.opacity(hovered ? 0.14 : 0.055), lineWidth: 0.75))
        .scaleEffect(hovered ? 1.025 : 1)
        .offset(y: hovered ? -1 : 0)
        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: hovered)
        .onHover { hovered = $0 }
        .onTapGesture(count: 2) { store.open(item) }
        .onDrag { store.itemProvider(for: item) }
        .contextMenu {
            Button("Open") { store.open(item) }
            Button("Quick Look") { store.quickLook(item) }
            if item.isFile { Button("Show in Finder") { store.reveal(item) } }
            Button("Send with AirDrop") { store.shareViaAirDrop(item) }
            Divider()
            Button("Remove", role: .destructive) { store.remove(item) }
        }
        .accessibilityLabel(item.name)
    }
}

struct ShelfThumbnailView: View {
    let item: ShelfItem
    @State private var thumbnail: NSImage?

    private var fallbackSymbol: String {
        switch item.resolvedKind {
        case .link: return "link"
        case .text: return "doc.text.fill"
        case .file: return "doc.fill"
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(0.065))

            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: fallbackSymbol)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(item.resolvedKind == .link ? NotchModule.shelf.tint : .white.opacity(0.62))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.white.opacity(0.1), lineWidth: 0.5))
        .onAppear(perform: loadThumbnail)
    }

    private func loadThumbnail() {
        guard item.isFile else { return }
        let request = QLThumbnailGenerator.Request(
            fileAt: item.url,
            size: CGSize(width: 104, height: 104),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .all
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            guard let image = representation?.nsImage else { return }
            DispatchQueue.main.async { thumbnail = image }
        }
    }
}

struct IntegratedAppsView: View {
    @ObservedObject var store: AppLauncherStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Quick Apps")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Text(store.apps.isEmpty ? "Add your favorite apps for quick access" : "\(store.apps.count) quick launch \(store.apps.count == 1 ? "app" : "apps")")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.42))
                }
                Spacer()
                if !store.apps.isEmpty {
                    Button {
                        store.pickAndAddApp()
                    } label: {
                        Label("Add App", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }
            }

            if store.apps.isEmpty {
                Button {
                    store.pickAndAddApp()
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(NotchModule.apps.tint)
                        Text("Add Application")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.7))
                        Text("Choose an app from /Applications")
                            .font(.system(size: 11, weight: .regular, design: .rounded))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(.white.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: [6, 4])))
                }
                .buttonStyle(.plain)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 12)], alignment: .leading, spacing: 12) {
                        ForEach(store.apps) { app in
                            QuickAppTile(app: app, store: store)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("apps-panel")
    }
}

struct QuickAppTile: View {
    let app: QuickLaunchApp
    @ObservedObject var store: AppLauncherStore
    @State private var hovered = false

    var body: some View {
        Button {
            store.launch(app)
        } label: {
            VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                        .resizable()
                        .scaledToFit()
                        .frame(width: 46, height: 46)
                        .shadow(color: .black.opacity(hovered ? 0.35 : 0.15), radius: 6, y: 3)
                        .scaleEffect(hovered ? 1.08 : 1.0)
                        .animation(.spring(response: 0.22, dampingFraction: 0.7), value: hovered)

                    if hovered {
                        Button {
                            store.remove(app)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white.opacity(0.85), .black.opacity(0.75))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 5, y: -5)
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(width: 48, height: 48)

                Text(app.name)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(hovered ? 0.95 : 0.65))
                    .lineLimit(1)
                    .frame(width: 72)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Open \(app.name)") { store.launch(app) }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)])
            }
            Divider()
            Button("Remove from Notch", role: .destructive) {
                store.remove(app)
            }
        }
        .help("Click to open \(app.name)")
    }
}

struct TactileButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.88 : 1)
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(reduceMotion ? nil : NotchMotion.press, value: configuration.isPressed)
    }
}

struct CompactHUDView: View {
    let state: HUDState
    let coreWidth: CGFloat
    let wingWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: state.symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white.opacity(0.86))
                .frame(width: wingWidth, alignment: .trailing)

            Color.clear.frame(width: coreWidth)

            VStack(spacing: 2) {
                Text("\(Int((state.value * 100).rounded()))%")
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.68))
                    .contentTransition(.numericText())
                ProgressView(value: state.value)
                    .tint(.white)
                    .controlSize(.mini)
                    .frame(width: max(24, wingWidth - 9))
            }
            .frame(width: wingWidth, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(state.title), \(Int((state.value * 100).rounded())) percent")
    }
}

struct ArtworkView: View {
    let image: NSImage?
    let fallbackSymbol: String
    var accent: Color = .purple
    var symbolSize: CGFloat = 30
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(
                    colors: [accent.opacity(0.95), .blue.opacity(0.78), .black],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: fallbackSymbol)
                    .font(.system(size: symbolSize, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.86))
                    .symbolEffect(.pulse, options: .repeating.speed(0.45), isActive: image == nil && !reduceMotion)
            }
        }
        .clipped()
    }
}

struct MiniVisualizer: View {
    let isPlaying: Bool
    @ObservedObject private var spectrum = SystemAudioSpectrumMonitor.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(0..<AudioSpectrumAnalyzer.bandCount, id: \.self) { index in
                let decibels = spectrum.bandsDB[index]
                let level = AudioSpectrumAnalyzer.normalizedLevel(decibels: decibels)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(isPlaying ? 0.92 : 0.46), .white.opacity(0.32)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 3, height: isPlaying ? max(4.5, 4.5 + CGFloat(pow(Double(level), 0.72)) * 16) : 4.5)
            }
        }
        .animation(reduceMotion ? nil : .linear(duration: 0.08), value: spectrum.bandsDB)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Eight-band audio visualizer")
        .accessibilityValue(spectrum.status.title)
        .accessibilityIdentifier("audio-visualizer")
    }
}

struct NotchPanelShape: Shape {
    var bottomRadius: CGFloat = 14

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let bR = min(max(0, bottomRadius), rect.height * 0.5, rect.width * 0.5)
        var path = Path()

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bR))

        if bR > 0.5 {
            path.addArc(
                center: CGPoint(x: rect.maxX - bR, y: rect.maxY - bR),
                radius: bR,
                startAngle: .degrees(0),
                endAngle: .degrees(90),
                clockwise: false
            )
        } else {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        }

        path.addLine(to: CGPoint(x: rect.minX + bR, y: rect.maxY))

        if bR > 0.5 {
            path.addArc(
                center: CGPoint(x: rect.minX + bR, y: rect.maxY - bR),
                radius: bR,
                startAngle: .degrees(90),
                endAngle: .degrees(180),
                clockwise: false
            )
        } else {
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }

        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

struct NotchSurface: View {
    let expansionState: NotchExpansionState
    let accent: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            Color.black

            if expansionState == .expanded && !reduceTransparency {
                LinearGradient(
                    colors: [.white.opacity(0.045), .clear, .black.opacity(0.35)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                RadialGradient(
                    colors: [accent.opacity(0.18), .clear],
                    center: .topLeading,
                    startRadius: 20,
                    endRadius: 500
                )
            } else if expansionState == .minimal && !reduceTransparency {
                LinearGradient(
                    colors: [.white.opacity(0.07), .clear, .black.opacity(0.2)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.32), value: accent)
    }
}

struct SpotifyLogoView: View {
    var size: CGFloat = 14

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(red: 0.12, green: 0.84, blue: 0.38))
                .frame(width: size, height: size)

            Canvas { context, sz in
                let w = sz.width
                let h = sz.height
                context.translateBy(x: w * 0.5, y: h * 0.5)
                context.rotate(by: .degrees(-16))
                context.translateBy(x: -w * 0.5, y: -h * 0.5)

                let center = CGPoint(x: w * 0.5, y: h * 0.65)
                let arcData: [(radius: CGFloat, stroke: CGFloat, angle: CGFloat)] = [
                    (w * 0.38, w * 0.10, 36),
                    (w * 0.28, w * 0.09, 32),
                    (w * 0.18, w * 0.08, 28)
                ]
                for arc in arcData {
                    var p = Path()
                    p.addArc(
                        center: center,
                        radius: arc.radius,
                        startAngle: .degrees(270 - Double(arc.angle)),
                        endAngle: .degrees(270 + Double(arc.angle)),
                        clockwise: false
                    )
                    context.stroke(p, with: .color(.black.opacity(0.85)), style: StrokeStyle(lineWidth: arc.stroke, lineCap: .round))
                }
            }
            .frame(width: size, height: size)
        }
        .frame(width: size, height: size)
    }
}

struct AppleMusicLogoView: View {
    var size: CGFloat = 14

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 0.98, green: 0.22, blue: 0.44), Color(red: 0.88, green: 0.12, blue: 0.35)],
                    startPoint: .top,
                    endPoint: .bottom
                ))
                .frame(width: size, height: size)
            Image(systemName: "music.note")
                .font(.system(size: size * 0.58, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

struct YouTubeMusicLogoView: View {
    var size: CGFloat = 14

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(red: 0.95, green: 0.12, blue: 0.12))
                .frame(width: size, height: size)
            Circle()
                .stroke(Color.white.opacity(0.9), lineWidth: size * 0.08)
                .frame(width: size * 0.72, height: size * 0.72)
            Image(systemName: "play.fill")
                .font(.system(size: size * 0.36, weight: .black))
                .foregroundStyle(.white)
                .offset(x: size * 0.03)
        }
        .frame(width: size, height: size)
    }
}

struct DynamicSourceAppIcon: View {
    let source: String
    let pid: pid_t?
    var size: CGFloat = 14

    var body: some View {
        let lower = source.lowercased()
        if lower.contains("spotify") {
            SpotifyLogoView(size: size)
        } else if lower.contains("music") || lower == "apple music" {
            AppleMusicLogoView(size: size)
        } else if lower.contains("youtube") {
            YouTubeMusicLogoView(size: size)
        } else if let nativeIcon = resolvedAppIcon {
            Image(nsImage: nativeIcon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        } else if lower.contains("chrome") {
            Image(systemName: "globe")
                .font(.system(size: size * 0.85, weight: .bold))
                .foregroundStyle(Color.blue)
        } else if lower.contains("safari") {
            Image(systemName: "safari.fill")
                .font(.system(size: size * 0.85, weight: .bold))
                .foregroundStyle(Color.blue)
        } else if lower.contains("podcast") {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: size * 0.85, weight: .bold))
                .foregroundStyle(Color.purple)
        } else if !source.isEmpty {
            Image(systemName: "waveform")
                .font(.system(size: size * 0.85, weight: .bold))
                .foregroundStyle(.white.opacity(0.85))
        } else {
            Image(systemName: "music.note")
                .font(.system(size: size * 0.85, weight: .bold))
                .foregroundStyle(.white.opacity(0.85))
        }
    }

    private var resolvedAppIcon: NSImage? {
        if let pid, let app = NSRunningApplication(processIdentifier: pid), let icon = app.icon {
            return icon
        }
        if !source.isEmpty, let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName?.localizedCaseInsensitiveContains(source) == true
        }), let icon = app.icon {
            return icon
        }
        return nil
    }
}

struct MinimalLiveActivityView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var nowPlaying: NowPlayingMonitor
    @ObservedObject var controls: SystemControlCenter
    let activityNamespace: Namespace.ID
    @ObservedObject private var focus = FocusTimerStore.shared

    private var playPauseTint: Color {
        let lower = nowPlaying.song.sourceApp.lowercased()
        if lower.contains("spotify") {
            return Color(red: 0.12, green: 0.84, blue: 0.38)
        } else if lower.contains("music") || lower.contains("apple") {
            return Color(red: 0.98, green: 0.22, blue: 0.44)
        } else if lower.contains("youtube") {
            return Color(red: 0.95, green: 0.15, blue: 0.15)
        } else if let accent = nowPlaying.dynamicAccentColor {
            return accent
        } else {
            return Color(red: 0.12, green: 0.84, blue: 0.38)
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    model.expandFull()
                }

            HStack(alignment: .center, spacing: 0) {
                // Left: Artwork thumbnail and playback controls
                HStack(spacing: 5) {
                    Button {
                        nowPlaying.activatePlayingApp()
                    } label: {
                        CollapsedMediaBadge(song: nowPlaying.song)
                            .matchedGeometryEffect(id: "activity-artwork", in: activityNamespace, isSource: true)
                            .frame(width: 22, height: 22)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    }
                    .buttonStyle(TactileButtonStyle())
                    .help("Open \(nowPlaying.song.sourceApp.isEmpty ? "player" : nowPlaying.song.sourceApp)")
                    .accessibilityLabel("Open playing app")

                    HStack(spacing: 4) {
                        Button {
                            nowPlaying.previousTrack()
                        } label: {
                            Image(systemName: "backward.fill")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.72))
                                .frame(width: 18, height: 18)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(TactileButtonStyle())
                        .help("Previous track")
                        .accessibilityIdentifier("minimal-previous")
                        .accessibilityLabel("Previous track")

                        Button {
                            nowPlaying.playPause()
                        } label: {
                            Image(systemName: nowPlaying.song.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(playPauseTint)
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(TactileButtonStyle())
                        .help(nowPlaying.song.isPlaying ? "Pause" : "Play")
                        .accessibilityIdentifier("minimal-playpause")
                        .accessibilityLabel(nowPlaying.song.isPlaying ? "Pause" : "Play")

                        Button {
                            nowPlaying.nextTrack()
                        } label: {
                            Image(systemName: "forward.fill")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.72))
                                .frame(width: 18, height: 18)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(TactileButtonStyle())
                        .help("Next track")
                        .accessibilityIdentifier("minimal-next")
                        .accessibilityLabel("Next track")
                    }
                }

                Spacer(minLength: 8)

                // Center: Dynamic Active Application Icon (no bulky gray capsule!)
                Button {
                    model.expandFull()
                } label: {
                    DynamicSourceAppIcon(
                        source: nowPlaying.song.sourceApp,
                        pid: nowPlaying.activePID,
                        size: 13
                    )
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
                }
                .buttonStyle(TactileButtonStyle())
                .help("Click to expand full dashboard")
                .accessibilityIdentifier("minimal-expand-dropdown")
                .accessibilityLabel("Expand full dashboard")

                Spacer(minLength: 8)

                // Right: Remaining Time countdown
                HStack(spacing: 3) {
                    if focus.isRunning || (focus.remainingSeconds > 0 && !focus.isFinished) {
                        Label(focus.formattedRemaining, systemImage: focus.isRunning ? "timer" : "pause.circle")
                            .font(.system(size: 10, weight: .semibold, design: .rounded)).monospacedDigit()
                            .foregroundStyle(.mint).contentTransition(.numericText())
                    } else if nowPlaying.song.hasTrack {
                        TimelineView(.animation(minimumInterval: 0.5, paused: !nowPlaying.song.isPlaying)) { timeline in
                            Text(nowPlaying.formattedRemainingTime(at: timeline.date))
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.88))
                                .contentTransition(.numericText())
                        }
                    } else if model.showBattery {
                        Label("\(controls.battery.percentage)%", systemImage: controls.battery.symbol)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(controls.battery.isCharging ? .green : .white.opacity(0.65))
                    } else {
                        Image(systemName: "waveform")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
        .frame(width: model.minimalSize.width, height: model.minimalSize.height)
        .accessibilityIdentifier("minimal-live-activity")
    }
}

struct ChromeButtonStyle: ButtonStyle {
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .bold))
            .frame(width: size, height: size)
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.55 : 0.76))
            .background(.white.opacity(configuration.isPressed ? 0.16 : 0.08), in: Circle())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.92 : 1)
            .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: configuration.isPressed)
    }
}

struct EmptyRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.white.opacity(0.45))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                Text(detail)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
            }
            Spacer()
        }
        .padding(12)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

struct SettingsView: View {
    @ObservedObject private var model = NotchModel.shared
    @ObservedObject private var calendar = CalendarProvider.shared
    @State private var launchAtLogin = LaunchAtLoginController.isEnabled
    @State private var loginError: String?
    @State private var selectedTab: SettingsTab = .general

    private enum SettingsTab: Hashable {
        case general
        case integrations
        case agents
        case about
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Form {
                Section("Behavior") {
                    Toggle("Show Notch", isOn: Binding(get: { model.isVisible }, set: { model.updateVisible($0) }))
                        .accessibilityIdentifier("settings-show-notch")
                    Picker("Open behavior", selection: Binding(get: { model.interaction }, set: { model.updateInteraction($0) })) {
                        ForEach(NotchInteraction.allCases) { interaction in
                            Text(interaction.title).tag(interaction)
                        }
                    }
                    .pickerStyle(.segmented)
                    if model.interaction.expandsOnHover {
                        LabeledContent("Hover response") {
                            HStack(spacing: 10) {
                                Slider(
                                    value: Binding(get: { model.hoverDelay }, set: { model.updateHoverDelay($0) }),
                                    in: 0...0.8,
                                    step: 0.05
                                )
                                .frame(width: 150)
                                Text(model.hoverDelay == 0 ? "Instant" : "\(Int((model.hoverDelay * 1_000).rounded())) ms")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .frame(width: 64, alignment: .trailing)
                            }
                        }
                    }
                    LabeledContent("Close grace period") {
                        HStack(spacing: 10) {
                            Slider(
                                value: Binding(get: { model.closeDelay }, set: { model.updateCloseDelay($0) }),
                                in: 0.15...2,
                                step: 0.05
                            )
                            .frame(width: 150)
                            Text("\(model.closeDelay, specifier: "%.2f") s")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 64, alignment: .trailing)
                        }
                    }
                    Picker("Notch size", selection: Binding(get: { model.sizePreset }, set: { model.updateSize($0) })) {
                        ForEach(NotchSizePreset.allCases) { size in
                            Text(size.title).tag(size)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("settings-notch-size")
                    Toggle("Keep expanded", isOn: Binding(get: { model.isPinned }, set: { model.updatePinned($0) }))
                        .accessibilityIdentifier("settings-keep-expanded")
                    Toggle("Auto-hide in full screen", isOn: Binding(get: { model.autoHideInFullScreen }, set: { model.updateAutoHideInFullScreen($0) }))
                        .accessibilityIdentifier("settings-autohide-fullscreen")
                    Toggle("Haptic feedback", isOn: Binding(get: { model.hapticsEnabled }, set: { model.updateHaptics($0) }))
                        .accessibilityIdentifier("settings-haptics")
                    Toggle("Follow pointer across displays", isOn: Binding(get: { model.followPointerDisplay }, set: { model.updateFollowPointerDisplay($0) }))
                        .accessibilityIdentifier("settings-follow-pointer")
                    Toggle("Launch at login", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, newValue in
                            do { try LaunchAtLoginController.setEnabled(newValue); loginError = nil }
                            catch { loginError = error.localizedDescription; launchAtLogin = LaunchAtLoginController.isEnabled }
                        }
                    if let loginError {
                        Text(loginError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section("At a glance") {
                    Toggle("Utilities", isOn: Binding(get: { model.showToolkit }, set: { model.updateToolkit($0) }))
                        .accessibilityIdentifier("settings-toolkit")
                    Text("Scratchpad and Keep Awake. Turning this off stops active utility services and keeps your saved note.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Audio-reactive visualizer", isOn: Binding(get: { model.showVisualizer }, set: { model.updateVisualizer($0) }))
                        .accessibilityIdentifier("settings-audio-visualizer")
                    Toggle("Battery activity", isOn: Binding(get: { model.showBattery }, set: { model.updateBattery($0) }))
                        .accessibilityIdentifier("settings-battery")
                    Toggle("Calendar accessory", isOn: Binding(get: { model.showCalendar }, set: { model.updateCalendar($0) }))
                        .accessibilityIdentifier("settings-calendar")
                    Toggle("Shelf drop target", isOn: Binding(get: { model.showShelf }, set: { model.updateShelf($0) }))
                        .accessibilityIdentifier("settings-shelf")
                }

                Section("Appearance") {
                    LabeledContent("Surface") { Text("Display-matched black").foregroundStyle(.secondary) }
                    Text("The shell stays black so it blends into the camera housing. Content uses restrained color and system materials for legibility.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                WorkspaceSettingsSection()
            }
            .formStyle(.grouped)
            .accessibilityIdentifier("settings-general")
            .tag(SettingsTab.general)
            .tabItem {
                Label("General", systemImage: "slider.horizontal.3")
                    .accessibilityIdentifier("settings-general-tab")
            }

            Form {
                Section("Calendar") {
                    HStack {
                        Label("Calendar access", systemImage: calendar.hasCalendarAccess ? "checkmark.circle.fill" : "calendar")
                        Spacer()
                        if calendar.hasCalendarAccess {
                            Text("On").foregroundStyle(.secondary)
                        } else {
                            Button("Allow") { calendar.requestCalendarAccess() }
                        }
                    }
                    HStack {
                        Label("Reminders access", systemImage: calendar.hasReminderAccess ? "checkmark.circle.fill" : "checklist")
                        Spacer()
                        if calendar.hasReminderAccess {
                            Text("On").foregroundStyle(.secondary)
                        } else {
                            Button("Allow") { calendar.requestReminderAccess() }
                        }
                    }
                }

                Section("Music") {
                    Text("Notch follows the active macOS Now Playing session, including Apple Music, Spotify, Safari, Chrome, and YouTube Music.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("The visualizer reads system output through Core Audio, divides it into eight logarithmic frequency bands, and maps each band to dB. It only reads playback audio.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    AudioSpectrumStatusRow()
                }

                Section("Shelf") {
                    Text("Drop files, links, or text. Drag items back out, double-click to open, or use Quick Look, Finder, and AirDrop from the shortcut menu.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Section("System controls") {
                    Text("Volume, mute, brightness, charging, and power-source changes appear as compact notch activity. Brightness is enabled when the current display exposes software control.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Section("Mirror") {
                    Text("Mirror keeps camera access off until you open the module and explicitly allow it. The preview stops when you leave the module.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .accessibilityIdentifier("settings-integrations")
            .tag(SettingsTab.integrations)
            .tabItem {
                Label("Integrations", systemImage: "rectangle.3.group")
                    .accessibilityIdentifier("settings-integrations-tab")
            }

            AgentSettingsView()
                .accessibilityIdentifier("settings-agents")
                .tag(SettingsTab.agents)
                .tabItem {
                    Label("Agents", systemImage: "sparkles")
                        .accessibilityIdentifier("settings-agents-tab")
                }

            VStack(spacing: 12) {
                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(.system(size: 42, weight: .medium))
                    .foregroundStyle(.purple, .blue)
                Text("Notch")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text("A calmer, more useful MacBook notch.")
                    .foregroundStyle(.secondary)
                Text("Inspired by the open-source Boring Notch project.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text("Utility portions adapted from Vorssaint under GPL-3.0-or-later.")
                    .font(.caption2).foregroundStyle(.tertiary)
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("settings-about")
            .tag(SettingsTab.about)
            .tabItem {
                Label("About", systemImage: "info.circle")
                    .accessibilityIdentifier("settings-about-tab")
            }
        }
        .frame(width: 540, height: 450)
        .padding(8)
    }
}

private struct AudioSpectrumStatusRow: View {
    @State private var status = SystemAudioSpectrumMonitor.shared.status

    var body: some View {
        HStack {
            Label("Audio spectrum", systemImage: status == .capturing ? "waveform" : "waveform.slash")
            Spacer()
            Text(status.title)
                .foregroundStyle(.secondary)
        }
        .onReceive(SystemAudioSpectrumMonitor.shared.$status.removeDuplicates()) { status = $0 }
    }
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0:00" }
    let total = Int(seconds.rounded())
    return "\(total / 60):\(String(format: "%02d", total % 60))"
}
