import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import CoreImage
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
import Vision

/// Capture and watch-region logic shared by the toolkit page and the settings switch.
enum CaptureFeature {
    static func apply(_ feature: NotchFeature, enabled: Bool) {
        let update = {
            switch feature {
            case .capture:
                CaptureRuntime.captureEnabled = enabled
                if !enabled { CaptureRuntime.stopEverything() }
            case .watchRegion:
                CaptureRuntime.watchEnabled = enabled
                if !enabled { CaptureRuntime.stopWatch() }
            default:
                break
            }
            if enabled && feature == .capture && CaptureRuntime.scrollMonitoring {
                CaptureRuntime.startScrollHelper()
            }
        }
        if Thread.isMainThread { update() } else { DispatchQueue.main.async(execute: update) }
    }
}

// MARK: Pure capture maths

enum ScrollStitcher {
    static let maximumFrames = 20
    static let maximumHeight = 20_000

    /// Returns the matching row count at the join between consecutive frames.
    static func overlap(previous: CGImage, next: CGImage) -> Int {
        guard previous.width == next.width,
              let oldRows = rowHashes(previous), let newRows = rowHashes(next),
              !oldRows.isEmpty, !newRows.isEmpty else { return 0 }

        return max(suffixPrefixOverlap(oldRows, newRows), suffixPrefixOverlap(oldRows.reversed(), newRows.reversed()))
    }

    private static func suffixPrefixOverlap<S: Sequence, T: Sequence>(_ previous: S, _ next: T) -> Int
    where S.Element == UInt64, T.Element == UInt64 {
        let previousRows = Array(previous)
        let nextRows = Array(next)
        guard !previousRows.isEmpty, !nextRows.isEmpty else { return 0 }

        // KMP finds the longest suffix of the previous frame matching the next prefix.
        var prefix = [Int](repeating: 0, count: nextRows.count)
        if nextRows.count > 1 {
            var matched = 0
            for index in 1..<nextRows.count {
                while matched > 0 && nextRows[index] != nextRows[matched] {
                    matched = prefix[matched - 1]
                }
                if nextRows[index] == nextRows[matched] { matched += 1 }
                prefix[index] = matched
            }
        }
        var matched = 0
        for row in previousRows {
            while matched > 0 && (matched == nextRows.count || nextRows[matched] != row) {
                matched = prefix[matched - 1]
            }
            if matched < nextRows.count && nextRows[matched] == row { matched += 1 }
        }
        return matched
    }

    static func canAppend(frameCount: Int, currentHeight: Int, nextHeight: Int, overlap: Int = 0) -> Bool {
        guard frameCount < maximumFrames, nextHeight > 0, currentHeight >= 0 else { return false }
        let safeOverlap = min(max(overlap, 0), nextHeight)
        return currentHeight + nextHeight - safeOverlap <= maximumHeight
    }

    static func stitch(_ frames: [CGImage]) -> CGImage? {
        guard let first = frames.first, frames.count <= maximumFrames,
              frames.allSatisfy({ $0.width == first.width }) else { return nil }
        var joins: [Int] = []
        var height = first.height
        for index in 1..<frames.count {
            let join = overlap(previous: frames[index - 1], next: frames[index])
            guard canAppend(frameCount: index, currentHeight: height, nextHeight: frames[index].height, overlap: join) else { return nil }
            joins.append(join)
            height += frames[index].height - min(join, frames[index].height)
        }
        guard height > 0, height <= maximumHeight,
              let context = CGContext(data: nil, width: first.width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: first.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        var top = 0
        context.draw(first, in: CGRect(x: 0, y: CGFloat(height - first.height), width: CGFloat(first.width), height: CGFloat(first.height)))
        top += first.height
        for index in 1..<frames.count {
            let image = frames[index]
            let join = min(joins[index - 1], image.height)
            let keptHeight = image.height - join
            guard keptHeight > 0 else { continue }
            let crop = CGRect(x: 0, y: CGFloat(join), width: CGFloat(image.width), height: CGFloat(keptHeight))
            guard let piece = image.cropping(to: crop) else { continue }
            context.draw(piece, in: CGRect(x: 0, y: CGFloat(height - top - keptHeight), width: CGFloat(first.width), height: CGFloat(keptHeight)))
            top += keptHeight
        }
        return context.makeImage()
    }

    private static func rowHashes(_ image: CGImage) -> [UInt64]? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        let rowBytes = width * 4
        var pixels = [UInt8](repeating: 0, count: rowBytes * height)
        let bitmap = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                     bytesPerRow: rowBytes, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmap) else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        return (0..<height).map { row in
            var hash: UInt64 = 14_695_981_039_346_656_037
            let start = row * rowBytes
            for byte in pixels[start..<(start + rowBytes)] {
                hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
            }
            return hash
        }
    }
}

enum RegionDiff {
    /// Mismatched sample buffers represent a completely changed region.
    static func changedFraction(a: [UInt8], b: [UInt8]) -> Double {
        guard !a.isEmpty || !b.isEmpty else { return 0 }
        guard a.count == b.count, !a.isEmpty else { return 1 }
        let changed = zip(a, b).reduce(into: 0) { count, pair in
            if abs(Int(pair.0) - Int(pair.1)) >= 12 { count += 1 }
        }
        return Double(changed) / Double(a.count)
    }

    static func exceedsThreshold(_ fraction: Double, threshold: Double) -> Bool {
        fraction.isFinite && threshold.isFinite && fraction > threshold
    }
}

// MARK: Permission, display, and persistence helpers

private enum CapturePermission {
    static func isGranted() -> Bool { CGPreflightScreenCaptureAccess() }

    static func openSettings() {
        if let url = NotchPermission.screenRecording.settingsURL { NSWorkspace.shared.open(url) }
    }
}

enum CaptureFormat: String, CaseIterable, Identifiable {
    case png = "PNG"
    case jpeg = "JPEG"
    var id: String { rawValue }
    var fileExtension: String { self == .png ? "png" : "jpg" }
    var bitmapFormat: NSBitmapImageRep.FileType { self == .png ? .png : .jpeg }
    var contentType: UTType { self == .png ? .png : .jpeg }
}

private enum CaptureFiles {
    private static let bookmarkKey = "capture.saveFolderBookmark"

    static func saveFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    static func chooseSaveFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Capture Folder"
        panel.prompt = "Use Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = saveFolder() ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        UserDefaults.standard.set(data, forKey: bookmarkKey)
    }

    static func save(_ image: CGImage, format: CaptureFormat, name: String = "Screenshot") -> Bool {
        let panel = NSSavePanel()
        panel.title = "Save Capture"
        panel.prompt = "Save"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = "\(name)-\(timestamp()).\(format.fileExtension)"
        panel.directoryURL = saveFolder() ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        let folder = url.deletingLastPathComponent()
        if let bookmark = try? folder.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
        }
        let didStart = folder.startAccessingSecurityScopedResource()
        defer { if didStart { folder.stopAccessingSecurityScopedResource() } }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: format.bitmapFormat, properties: [:]) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter.string(from: Date())
    }
}

private struct CaptureWindowInfo: Identifiable {
    let id: CGWindowID
    let title: String
    let owner: String
}

private enum ScreenCaptureService {
    static func display(for screen: NSScreen) async throws -> SCDisplay {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else {
            throw CaptureError.displayUnavailable
        }
        return display
    }

    static func screens() async throws -> [CaptureWindowInfo] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return content.windows
            .filter { $0.isOnScreen && $0.windowLayer == 0 && $0.frame.width >= 80 && $0.frame.height >= 50 }
            .compactMap { window in
                let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let owner = window.owningApplication?.applicationName ?? "Application"
                guard !title.isEmpty else { return nil }
                return CaptureWindowInfo(id: window.windowID, title: title, owner: owner)
            }
            .sorted { $0.owner.localizedCaseInsensitiveCompare($1.owner) == .orderedAscending }
    }

    static func capture(screen: NSScreen, area: CGRect? = nil, showsCursor: Bool) async throws -> CGImage {
        let display = try await display(for: screen)
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.showsCursor = showsCursor
        config.capturesAudio = false
        if let area {
            let local = CGRect(x: area.minX - screen.frame.minX,
                               y: screen.frame.maxY - area.maxY,
                               width: area.width, height: area.height).integral
            let scaleX = CGFloat(display.width) / max(screen.frame.width, 1)
            let scaleY = CGFloat(display.height) / max(screen.frame.height, 1)
            config.sourceRect = local
            config.width = max(1, Int((local.width * scaleX).rounded()))
            config.height = max(1, Int((local.height * scaleY).rounded()))
        } else {
            config.width = display.width
            config.height = display.height
        }
        guard let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) as CGImage? else {
            throw CaptureError.noImage
        }
        return image
    }

    static func capture(windowID: CGWindowID, showsCursor: Bool) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else { throw CaptureError.windowUnavailable }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.showsCursor = showsCursor
        config.capturesAudio = false
        config.width = max(1, Int(window.frame.width * 2))
        config.height = max(1, Int(window.frame.height * 2))
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    static func grayQuarter(_ image: CGImage) -> [UInt8] {
        let width = max(1, image.width / 4)
        let height = max(1, image.height / 4)
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let bitmap = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(data: &rgba, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmap) else { return [] }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        var gray = [UInt8](repeating: 0, count: width * height)
        for pixel in 0..<gray.count {
            let offset = pixel * 4
            gray[pixel] = UInt8((Double(rgba[offset]) * 0.2126 + Double(rgba[offset + 1]) * 0.7152 + Double(rgba[offset + 2]) * 0.0722).rounded())
        }
        return gray
    }
}

private enum CaptureError: LocalizedError {
    case displayUnavailable, windowUnavailable, noImage, permission, recording
    var errorDescription: String? {
        switch self {
        case .displayUnavailable: return "The selected display is no longer available."
        case .windowUnavailable: return "That window is no longer available."
        case .noImage: return "The screen capture returned no image."
        case .permission: return "Allow Screen Recording in System Settings, then try again."
        case .recording: return "Screen recording could not be started."
        }
    }
}

// MARK: Area selector

private final class AreaSelectionWindow: NSWindow {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }
}

private final class AreaSelectionView: NSView {
    var onSelection: ((CGRect) -> Void)?
    private var startPoint: CGPoint?
    private var currentPoint: CGPoint?

    override var isFlipped: Bool { false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.24).setFill()
        bounds.fill()
        guard let rect = selectionRect else { return }
        NSGraphicsContext.current?.cgContext.clear(rect)
        NSColor.white.setStroke()
        let outline = NSBezierPath(rect: rect)
        outline.lineWidth = 2
        outline.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentPoint = startPoint
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        guard let selectionRect, selectionRect.width >= 4, selectionRect.height >= 4 else { return }
        onSelection?(window?.convertToScreen(selectionRect) ?? selectionRect)
    }

    private var selectionRect: CGRect? {
        guard let startPoint, let currentPoint else { return nil }
        return CGRect(x: min(startPoint.x, currentPoint.x), y: min(startPoint.y, currentPoint.y),
                      width: abs(startPoint.x - currentPoint.x), height: abs(startPoint.y - currentPoint.y))
    }
}

private enum AreaSelector {
    private static var window: AreaSelectionWindow?
    private static var selectedScreen: NSScreen?

    static func present(on screen: NSScreen, completion: @escaping (CGRect?, NSScreen?) -> Void) {
        cancel()
        selectedScreen = screen
        let panel = AreaSelectionWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.onCancel = { completion(nil, nil); cancel() }
        let view = AreaSelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.onSelection = { rect in
            completion(rect, screen)
            cancel()
        }
        panel.contentView = view
        window = panel
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
    }

    static func cancel() {
        window?.onCancel = nil
        window?.close()
        window = nil
        selectedScreen = nil
    }
}

private enum CaptureImageStore {
    static var last: CGImage?
}

// MARK: Feature runtime

private enum CaptureRuntime {
    static var captureEnabled = false
    static var watchEnabled = false
    static var watchTimer: Timer?
    static var watchTask: Task<Void, Never>?
    static var watchArea: CGRect?
    static var watchScreen: NSScreen?
    static var previousWatchSamples: [UInt8]?
    static var scrollMonitoring = false
    static var scrollFrames: [CGImage] = []
    static var scrollHeight = 0
    static var scrollArea: CGRect?
    static var scrollScreen: NSScreen?
    static var scrollBusy = false
    static var scrollDebounce: Timer?
    static var scrollObserver: CaptureScrollObserver?
    static var recorder: CaptureRecorder?
    static var recordingHUDTimer: Timer?

    static func stopWatch() {
        watchTimer?.invalidate()
        watchTimer = nil
        watchTask?.cancel()
        watchTask = nil
        watchArea = nil
        watchScreen = nil
        previousWatchSamples = nil
    }

    static func stopScrollWatcher() {
        scrollDebounce?.invalidate()
        scrollDebounce = nil
        if let scrollObserver { DistributedNotificationCenter.default().removeObserver(scrollObserver) }
        scrollObserver = nil
        scrollMonitoring = false
        NotchSystemHelperClient.shared.perform("capture", "stopScrollWatch")
    }

    static func startScrollHelper() {
        guard captureEnabled, scrollMonitoring else { return }
        NotchSystemHelperClient.shared.perform("capture", "startScrollWatch", args: ["enabled": true]) { _ in }
    }

    static func stopEverything() {
        AreaSelector.cancel()
        stopWatch()
        stopScrollWatcher()
        scrollFrames.removeAll(keepingCapacity: false)
        scrollHeight = 0
        scrollArea = nil
        scrollScreen = nil
        recorder?.stop()
        recorder = nil
        recordingHUDTimer?.invalidate()
        recordingHUDTimer = nil
        RecordingStopPanel.hide()
    }

    static func addScrollObserver(onScroll: @escaping (Int) -> Void) {
        guard scrollObserver == nil else { return }
        let observer = CaptureScrollObserver(onScroll: onScroll)
        DistributedNotificationCenter.default().addObserver(observer, selector: #selector(CaptureScrollObserver.didScroll(_:)),
                                                             name: Notification.Name("sidco.notch.capture.scroll"), object: nil,
                                                             suspensionBehavior: .deliverImmediately)
        scrollObserver = observer
    }

    static func showRecordingStatus(startedAt: Date, screen: NSScreen, stop: @escaping () -> Void) {
        RecordingStopPanel.show(on: screen, stop: stop)
        recordingHUDTimer?.invalidate()
        func updateHUD() {
            let seconds = max(0, Int(Date().timeIntervalSince(startedAt)))
            NotchModel.shared.presentHUD(HUDState(symbol: "record.circle.fill",
                                                  title: String(format: "Recording %02d:%02d", seconds / 60, seconds % 60), value: 1))
        }
        updateHUD()
        recordingHUDTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in updateHUD() }
    }
}

private final class CaptureScrollObserver: NSObject {
    private let onScroll: (Int) -> Void

    init(onScroll: @escaping (Int) -> Void) { self.onScroll = onScroll }

    @objc func didScroll(_ notification: Notification) {
        guard let delta = (notification.userInfo?["dy"] as? NSNumber)?.intValue else { return }
        onScroll(delta)
    }
}

// MARK: Capture page

struct CaptureToolView: View {
    @AppStorage("capture.fileFormat") private var fileFormat = CaptureFormat.png.rawValue
    @AppStorage("capture.includeCursor") private var includeCursor = true
    @AppStorage("capture.watchInterval") private var watchInterval = 15
    @AppStorage("capture.watchThreshold") private var watchThreshold = 0.02
    @AppStorage("capture.recordSystemAudio") private var recordSystemAudio = false
    @State private var tab = 0
    @State private var message = "Choose a capture action."
    @State private var permissionMissing = false
    @State private var windowChoices: [CaptureWindowInfo] = []
    @State private var showingWindows = false
    @State private var scrollActive = false
    @State private var watchActive = false
    @State private var recording = false
    @State private var recordingStartedAt: Date?
    @State private var lastOCRLineCount = 0

    private let tabs = ["Screenshot", "Scroll", "Annotate", "OCR", "Record", "Watch"]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Picker("Capture tool", selection: $tab) {
                ForEach(Array(tabs.enumerated()), id: \.offset) { index, title in Text(title).tag(index) }
            }
            .pickerStyle(.segmented)
            .frame(minHeight: 28)
            .accessibilityIdentifier("capture-tool-tabs")

            Group {
                switch tab {
                case 0: screenshotControls
                case 1: scrollControls
                case 2: annotateControls
                case 3: ocrControls
                case 4: recordingControls
                default: watchControls
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if permissionMissing {
                HStack(spacing: 7) {
                    Text("Screen Recording access is needed to capture this display.")
                        .font(.system(size: 10, weight: .medium, design: .rounded)).lineLimit(1)
                    Button("Open Settings", action: CapturePermission.openSettings)
                        .buttonStyle(CaptureSmallButtonStyle())
                        .frame(minHeight: 28)
                        .contentShape(Rectangle())
                        .help("Open Screen Recording privacy settings")
                        .accessibilityIdentifier("capture-open-screen-settings")
                }
            }
            Text(message)
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(.white.opacity(0.62))
                .lineLimit(1)
                .accessibilityIdentifier("capture-status")
        }
        .foregroundStyle(.white)
        .onChange(of: tab) { _, _ in message = "Choose a capture action." }
        .sheet(isPresented: $showingWindows) { windowPicker }
        .accessibilityIdentifier("capture-tool-view")
    }

    private var screenshotControls: some View {
        HStack(spacing: 6) {
            actionButton("Area", symbol: "selection.pin.in.out") { captureArea() }
            actionButton("Window", symbol: "macwindow") { loadWindows() }
            actionButton("Full screen", symbol: "rectangle.inset.filled") { captureFullScreen() }
            Spacer(minLength: 2)
            Text(fileFormat).font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
        }
    }

    private var scrollControls: some View {
        HStack(spacing: 6) {
            if scrollActive {
                actionButton("Add frame", symbol: "plus.viewfinder") { captureScrollFrame() }
                actionButton("Done", symbol: "checkmark") { finishScrollCapture() }
                actionButton("Stop", symbol: "stop.fill") { stopScrollCapture() }
                Text("\(CaptureRuntime.scrollFrames.count)/\(ScrollStitcher.maximumFrames) frames")
                    .font(.system(size: 10, design: .rounded)).foregroundStyle(.secondary)
            } else {
                actionButton("Select area", symbol: "selection.pin.in.out") { beginScrollCapture() }
                Text(AXIsProcessTrusted() ? "Scroll to add frames, or use Add frame." : "Scroll manually, then add frames.")
                    .font(.system(size: 10, design: .rounded)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private var annotateControls: some View {
        HStack(spacing: 6) {
            actionButton("Open editor", symbol: "pencil.tip.crop.circle") {
                guard let image = CaptureImageStore.last else { message = "Take a screenshot first."; return }
                CaptureAnnotationWindowController.present(image: image)
            }
            .disabled(CaptureImageStore.last == nil)
            Text(CaptureImageStore.last == nil ? "The last capture is kept for annotation." : "Arrow · rectangle · text · highlight · pixelate")
                .font(.system(size: 10, design: .rounded)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var ocrControls: some View {
        HStack(spacing: 6) {
            actionButton("Text from area", symbol: "text.viewfinder") { captureOCR() }
            if lastOCRLineCount > 0 {
                Text("Copied \(lastOCRLineCount) lines").font(.system(size: 10, design: .rounded)).foregroundStyle(.secondary)
            }
        }
    }

    private var recordingControls: some View {
        HStack(spacing: 6) {
            if recording {
                actionButton("Stop recording", symbol: "stop.fill") { stopRecording() }
                Text(recordingDuration).font(.system(size: 10, weight: .semibold, design: .rounded)).monospacedDigit()
            } else {
                actionButton("Record area", symbol: "record.circle") { startRecording(areaOnly: true) }
                actionButton("Full screen", symbol: "record.circle.fill") { startRecording(areaOnly: false) }
                Toggle("System audio", isOn: $recordSystemAudio)
                    .toggleStyle(.checkbox).font(.system(size: 10, design: .rounded))
                    .help("Include system audio in the recording; microphone capture stays off")
                    .accessibilityIdentifier("capture-record-system-audio")
            }
        }
    }

    private var watchControls: some View {
        HStack(spacing: 6) {
            if watchActive {
                actionButton("Stop watch", symbol: "stop.fill") { CaptureRuntime.stopWatch(); watchActive = false; message = "Region watch stopped." }
                Text("Every \(watchInterval)s · >\(Int(watchThreshold * 100))% change")
                    .font(.system(size: 10, design: .rounded)).foregroundStyle(.secondary)
            } else {
                actionButton("Pick region", symbol: "eye") { beginRegionWatch() }
                Text(NotchFeatureRegistry.isEnabled(.watchRegion) ? "Checks a quarter-scale image while active." : "Enable Watch Region in Settings first.")
                    .font(.system(size: 10, design: .rounded)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private var windowPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Choose a window").font(.system(size: 14, weight: .semibold, design: .rounded))
            if windowChoices.isEmpty {
                Text("No on-screen windows found.").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(windowChoices) { item in
                            Button {
                                showingWindows = false
                                captureWindow(item.id)
                            } label: {
                                HStack { Text(item.title).lineLimit(1); Spacer(); Text(item.owner).foregroundStyle(.secondary).lineLimit(1) }
                                    .frame(minHeight: 28).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).help("Capture \(item.title)")
                            .accessibilityIdentifier("capture-window-\(item.id)")
                        }
                    }
                }
            }
            Button("Cancel") { showingWindows = false }
                .frame(minHeight: 28).help("Close window picker").accessibilityIdentifier("capture-window-cancel")
        }
        .padding(14).frame(width: 420, height: 320)
        .foregroundStyle(.white).background(Color.black)
    }

    private func actionButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .frame(minHeight: 28).padding(.horizontal, 8).contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(CaptureSmallButtonStyle())
        .help(title)
        .accessibilityIdentifier("capture-\(title.lowercased().replacingOccurrences(of: " ", with: "-"))")
    }

    private func requirePermission() -> Bool {
        guard CapturePermission.isGranted() else {
            permissionMissing = true
            message = "Allow Screen Recording in System Settings, then try again."
            return false
        }
        permissionMissing = false
        return true
    }

    private func pointerScreen() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main
    }

    private func captureArea() {
        guard requirePermission(), let screen = pointerScreen() else { return }
        message = "Drag an area. Press Esc to cancel."
        AreaSelector.present(on: screen) { area, selectedScreen in
            guard let area, let selectedScreen else { message = "Area capture canceled."; return }
            Task { await captureSelectedArea(area, screen: selectedScreen) }
        }
    }

    private func captureFullScreen() {
        guard requirePermission(), let screen = pointerScreen() else { return }
        message = "Capturing full screen…"
        Task {
            do { completeCapture(try await ScreenCaptureService.capture(screen: screen, showsCursor: includeCursor), name: "Screenshot") }
            catch { message = error.localizedDescription }
        }
    }

    private func captureSelectedArea(_ area: CGRect, screen: NSScreen) async {
        do { completeCapture(try await ScreenCaptureService.capture(screen: screen, area: area, showsCursor: includeCursor), name: "Screenshot") }
        catch { message = error.localizedDescription }
    }

    private func loadWindows() {
        guard requirePermission() else { return }
        message = "Loading on-screen windows…"
        Task {
            do { windowChoices = try await ScreenCaptureService.screens(); showingWindows = true; message = "Choose a window to capture." }
            catch { message = error.localizedDescription }
        }
    }

    private func captureWindow(_ id: CGWindowID) {
        guard requirePermission() else { return }
        Task {
            do { completeCapture(try await ScreenCaptureService.capture(windowID: id, showsCursor: includeCursor), name: "Window") }
            catch { message = error.localizedDescription }
        }
    }

    private func completeCapture(_ image: CGImage, name: String) {
        CaptureImageStore.last = image
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width), height: CGFloat(image.height)))])
        let format = CaptureFormat(rawValue: fileFormat) ?? .png
        if CaptureFiles.save(image, format: format, name: name) {
            message = "Copied and saved \(image.width) × \(image.height)."
            NotchModel.shared.presentHUD(HUDState(symbol: "camera.fill", title: "Screenshot saved", value: 1))
        } else {
            message = "Copied to clipboard. Save canceled."
            NotchModel.shared.presentHUD(HUDState(symbol: "camera.fill", title: "Screenshot copied", value: 1))
        }
    }

    private func captureOCR() {
        guard requirePermission(), let screen = pointerScreen() else { return }
        message = "Drag an area to read. Press Esc to cancel."
        AreaSelector.present(on: screen) { area, selectedScreen in
            guard let area, let selectedScreen else { message = "Text capture canceled."; return }
            Task {
                do {
                    let image = try await ScreenCaptureService.capture(screen: selectedScreen, area: area, showsCursor: false)
                    let lines = try await Task.detached(priority: .userInitiated) { try OCRService.lines(in: image) }.value
                    guard !lines.isEmpty else { message = "No text found in that area."; return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
                    lastOCRLineCount = lines.count
                    message = "Copied \(lines.count) lines of text."
                    NotchModel.shared.presentHUD(HUDState(symbol: "text.viewfinder", title: "Copied \(lines.count) lines", value: 1))
                } catch { message = error.localizedDescription }
            }
        }
    }

    private func beginScrollCapture() {
        guard requirePermission(), CaptureRuntime.captureEnabled, let screen = pointerScreen() else { return }
        message = "Drag the area to capture. Press Esc to cancel."
        AreaSelector.present(on: screen) { area, selectedScreen in
            guard let area, let selectedScreen else { message = "Scroll capture canceled."; return }
            CaptureRuntime.scrollFrames.removeAll(keepingCapacity: false)
            CaptureRuntime.scrollHeight = 0
            CaptureRuntime.scrollArea = area
            CaptureRuntime.scrollScreen = selectedScreen
            CaptureRuntime.scrollMonitoring = true
            scrollActive = true
            message = AXIsProcessTrusted() ? "Scroll in the selected area; frames are captured as you move." : "Accessibility is off. Scroll manually, then Add frame."
            CaptureRuntime.addScrollObserver { dy in
                guard dy != 0, scrollActive else { return }
                CaptureRuntime.scrollDebounce?.invalidate()
                CaptureRuntime.scrollDebounce = Timer.scheduledTimer(withTimeInterval: 0.32, repeats: false) { _ in captureScrollFrame() }
            }
            if AXIsProcessTrusted() { CaptureRuntime.startScrollHelper() }
            captureScrollFrame()
        }
    }

    private func captureScrollFrame() {
        guard requirePermission(), CaptureRuntime.scrollMonitoring,
              !CaptureRuntime.scrollBusy,
              let area = CaptureRuntime.scrollArea, let screen = CaptureRuntime.scrollScreen else { return }
        CaptureRuntime.scrollBusy = true
        Task {
            defer { CaptureRuntime.scrollBusy = false }
            do {
                let image = try await ScreenCaptureService.capture(screen: screen, area: area, showsCursor: false)
                let overlap = CaptureRuntime.scrollFrames.last.map { ScrollStitcher.overlap(previous: $0, next: image) } ?? 0
                guard ScrollStitcher.canAppend(frameCount: CaptureRuntime.scrollFrames.count,
                                               currentHeight: CaptureRuntime.scrollHeight,
                                               nextHeight: image.height, overlap: overlap) else {
                    message = "Scroll capture reached 20 frames or 20,000 pixels. Press Done."
                    return
                }
                CaptureRuntime.scrollFrames.append(image)
                CaptureRuntime.scrollHeight += image.height - min(overlap, image.height)
                message = "Captured frame \(CaptureRuntime.scrollFrames.count)/\(ScrollStitcher.maximumFrames)."
            } catch { message = error.localizedDescription }
        }
    }

    private func finishScrollCapture() {
        guard !CaptureRuntime.scrollFrames.isEmpty else { message = "Capture at least one frame first."; return }
        CaptureRuntime.stopScrollWatcher()
        guard let image = ScrollStitcher.stitch(CaptureRuntime.scrollFrames) else {
            stopScrollCapture()
            message = "Could not stitch these frames."
            return
        }
        stopScrollCapture()
        scrollActive = false
        completeCapture(image, name: "Scroll-Capture")
    }

    private func stopScrollCapture() {
        CaptureRuntime.stopScrollWatcher()
        CaptureRuntime.scrollFrames.removeAll(keepingCapacity: false)
        CaptureRuntime.scrollHeight = 0
        CaptureRuntime.scrollArea = nil
        CaptureRuntime.scrollScreen = nil
        scrollActive = false
        message = "Scroll capture stopped."
    }

    private func beginRegionWatch() {
        guard NotchFeatureRegistry.isEnabled(.watchRegion) else { message = "Enable Watch Region in Settings first."; return }
        guard requirePermission(), let screen = pointerScreen() else { return }
        message = "Drag the region to watch. Press Esc to cancel."
        AreaSelector.present(on: screen) { area, selectedScreen in
            guard let area, let selectedScreen else { message = "Region watch canceled."; return }
            CaptureRuntime.stopWatch()
            CaptureRuntime.watchArea = area
            CaptureRuntime.watchScreen = selectedScreen
            CaptureRuntime.previousWatchSamples = nil
            CaptureRuntime.watchTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(watchInterval), repeats: true) { _ in
                sampleWatchedRegion()
            }
            watchActive = true
            message = "Watching every \(watchInterval) seconds."
            sampleWatchedRegion()
        }
    }

    private func sampleWatchedRegion() {
        guard CaptureRuntime.watchEnabled, CaptureRuntime.captureEnabled,
              let area = CaptureRuntime.watchArea, let screen = CaptureRuntime.watchScreen else { return }
        CaptureRuntime.watchTask?.cancel()
        CaptureRuntime.watchTask = Task {
            do {
                let image = try await ScreenCaptureService.capture(screen: screen, area: area, showsCursor: false)
                guard !Task.isCancelled else { return }
                let samples = ScreenCaptureService.grayQuarter(image)
                if let previous = CaptureRuntime.previousWatchSamples {
                    let fraction = RegionDiff.changedFraction(a: previous, b: samples)
                    if RegionDiff.exceedsThreshold(fraction, threshold: watchThreshold) {
                        NotchModel.shared.presentHUD(HUDState(symbol: "eye", title: "Region changed", value: min(fraction, 1)))
                        notifyRegionChange(fraction)
                        message = "Region changed by \(Int((fraction * 100).rounded()))%."
                    }
                }
                CaptureRuntime.previousWatchSamples = samples
            } catch { message = error.localizedDescription }
        }
    }

    private func notifyRegionChange(_ fraction: Double) {
        let content = UNMutableNotificationContent()
        content.title = "Region changed"
        content.body = "The watched area changed by about \(Int((fraction * 100).rounded()))%."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private func startRecording(areaOnly: Bool) {
        guard requirePermission(), CaptureRuntime.captureEnabled else { return }
        if areaOnly {
            guard let screen = pointerScreen() else { return }
            message = "Drag the area to record. Press Esc to cancel."
            AreaSelector.present(on: screen) { area, selectedScreen in
                guard let area, let selectedScreen else { message = "Recording canceled."; return }
                beginRecorder(screen: selectedScreen, area: area)
            }
        } else if let screen = pointerScreen() {
            beginRecorder(screen: screen, area: nil)
        }
    }

    private func beginRecorder(screen: NSScreen, area: CGRect?) {
        let format = CaptureFormat(rawValue: fileFormat) ?? .png
        let panel = NSSavePanel()
        panel.title = "Save Screen Recording"
        panel.prompt = "Start Recording"
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.nameFieldStringValue = "Screen-Recording-\(CaptureFiles.timestamp()).mov"
        panel.directoryURL = CaptureFiles.saveFolder() ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { message = "Recording canceled."; return }
        let folder = url.deletingLastPathComponent()
        if let bookmark = try? folder.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(bookmark, forKey: "capture.saveFolderBookmark")
        }
        _ = format
        Task {
            do {
                let recorder = try await CaptureRecorder.start(screen: screen, area: area, destination: url,
                                                               showsCursor: includeCursor, systemAudio: recordSystemAudio)
                CaptureRuntime.recorder = recorder
                recording = true
                recordingStartedAt = Date()
                message = recordSystemAudio ? "Recording screen and system audio. Microphone is off." : "Recording screen."
                if let recordingStartedAt {
                    CaptureRuntime.showRecordingStatus(startedAt: recordingStartedAt, screen: screen) { stopRecording() }
                }
                recorder.onFinish = { error in
                    recording = false
                    recordingStartedAt = nil
                    CaptureRuntime.recorder = nil
                    CaptureRuntime.recordingHUDTimer?.invalidate()
                    CaptureRuntime.recordingHUDTimer = nil
                    RecordingStopPanel.hide()
                    message = error.map { $0.localizedDescription } ?? "Recording saved."
                    NotchModel.shared.presentHUD(HUDState(symbol: "record.circle", title: "Recording saved", value: 1))
                }
                recorder.startLimitTimer()
            } catch { message = error.localizedDescription }
        }
    }

    private func stopRecording() {
        CaptureRuntime.recorder?.stop()
        recording = false
        recordingStartedAt = nil
    }

    private var recordingDuration: String {
        guard let recordingStartedAt else { return "00:00" }
        let seconds = Int(Date().timeIntervalSince(recordingStartedAt))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private struct CaptureSmallButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(.white.opacity(configuration.isPressed ? 0.13 : 0.05), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

private enum OCRService {
    static func lines(in image: CGImage) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? [])
            .sorted { first, second in
                if abs(first.boundingBox.midY - second.boundingBox.midY) > 0.012 {
                    return first.boundingBox.midY > second.boundingBox.midY
                }
                return first.boundingBox.minX < second.boundingBox.minX
            }
            .compactMap { $0.topCandidates(1).first?.string }
    }
}

// MARK: Screen recording

private final class CaptureRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private let stream: SCStream
    private let queue = DispatchQueue(label: "sidco.notch.capture.recording", qos: .userInitiated)
    private var startedSession = false
    private var stopped = false
    private var limitTimer: Timer?
    var onFinish: ((Error?) -> Void)?

    private init(writer: AVAssetWriter, videoInput: AVAssetWriterInput, audioInput: AVAssetWriterInput?, stream: SCStream) {
        self.writer = writer
        self.videoInput = videoInput
        self.audioInput = audioInput
        self.stream = stream
        super.init()
    }

    static func start(screen: NSScreen, area: CGRect?, destination: URL, showsCursor: Bool, systemAudio: Bool) async throws -> CaptureRecorder {
        let display = try await ScreenCaptureService.display(for: screen)
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.showsCursor = showsCursor
        config.capturesAudio = systemAudio
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 8
        if let area {
            let local = CGRect(x: area.minX - screen.frame.minX,
                               y: screen.frame.maxY - area.maxY,
                               width: area.width, height: area.height).integral
            let scaleX = CGFloat(display.width) / max(screen.frame.width, 1)
            let scaleY = CGFloat(display.height) / max(screen.frame.height, 1)
            config.sourceRect = local
            config.width = max(1, Int((local.width * scaleX).rounded()))
            config.height = max(1, Int((local.height * scaleY).rounded()))
        } else {
            config.width = display.width
            config.height = display.height
        }
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: config.width,
            AVVideoHeightKey: config.height
        ])
        video.expectsMediaDataInRealTime = true
        guard writer.canAdd(video) else { throw CaptureError.recording }
        writer.add(video)
        var audio: AVAssetWriterInput?
        if systemAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000
            ])
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) { writer.add(input); audio = input }
        }
        guard writer.startWriting() else { throw writer.error ?? CaptureError.recording }
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        let recorder = CaptureRecorder(writer: writer, videoInput: video, audioInput: audio, stream: stream)
        try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: recorder.queue)
        if systemAudio, audio != nil { try stream.addStreamOutput(recorder, type: .audio, sampleHandlerQueue: recorder.queue) }
        do { try await stream.startCapture() }
        catch { writer.cancelWriting(); throw error }
        return recorder
    }

    func startLimitTimer() {
        limitTimer?.invalidate()
        limitTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: false) { [weak self] _ in self?.stop() }
    }

    func stop() {
        queue.async {
            guard !self.stopped else { return }
            self.stopped = true
            self.limitTimer?.invalidate()
            self.limitTimer = nil
            self.stream.stopCapture { _ in
                self.queue.async {
                    self.videoInput.markAsFinished()
                    self.audioInput?.markAsFinished()
                    self.writer.finishWriting { self.onFinish?(self.writer.error) }
                }
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !stopped, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        if type == .screen {
            guard videoInput.isReadyForMoreMediaData else { return }
            let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if !startedSession { writer.startSession(atSourceTime: time); startedSession = true }
            _ = videoInput.append(sampleBuffer)
        } else if type == .audio, startedSession, let audioInput, audioInput.isReadyForMoreMediaData {
            _ = audioInput.append(sampleBuffer)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { stop() }
}

// MARK: Scroll completion / helper notifications

private extension CaptureToolView {
    func onHelperScroll(_ dy: Int) {
        guard dy != 0, scrollActive else { return }
        CaptureRuntime.scrollDebounce?.invalidate()
        CaptureRuntime.scrollDebounce = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in captureScrollFrame() }
    }
}

// MARK: Annotation editor

private enum CaptureAnnotationTool: String, CaseIterable, Identifiable {
    case arrow, rectangle, text, highlighter, blur
    var id: String { rawValue }
    var title: String {
        switch self { case .arrow: "Arrow"; case .rectangle: "Rectangle"; case .text: "Text"; case .highlighter: "Highlighter"; case .blur: "Pixelate" }
    }
    var symbol: String {
        switch self { case .arrow: "arrow.up.right"; case .rectangle: "rectangle"; case .text: "textformat"; case .highlighter: "highlighter"; case .blur: "square.grid.3x3.square" }
    }
}

private struct CaptureAnnotation: Identifiable {
    let id = UUID()
    let tool: CaptureAnnotationTool
    let rect: CGRect
    let text: String
}

private struct CaptureAnnotationCanvas: View {
    let image: CGImage
    let annotations: [CaptureAnnotation]

    var body: some View {
        Canvas { context, size in
            let imageRect = CGRect(origin: .zero, size: size)
            context.draw(Image(decorative: image, scale: 1), in: imageRect)
            let scaleX = size.width / CGFloat(image.width)
            let scaleY = size.height / CGFloat(image.height)
            let lineScale = min(scaleX, scaleY)
            for annotation in annotations {
                let rect = annotation.rect.applying(CGAffineTransform(scaleX: scaleX, y: scaleY))
                switch annotation.tool {
                case .rectangle:
                    context.stroke(Path(rect), with: .color(.red), lineWidth: 4 * lineScale)
                case .highlighter:
                    context.fill(Path(rect), with: .color(.yellow.opacity(0.35)))
                case .text:
                    context.draw(Text(annotation.text).font(.system(size: max(9, 24 * lineScale), weight: .bold, design: .rounded)).foregroundColor(.red),
                                 at: rect.origin, anchor: .topLeading)
                case .arrow:
                    var path = Path()
                    let start = CGPoint(x: rect.minX, y: rect.minY)
                    let end = CGPoint(x: rect.maxX, y: rect.maxY)
                    path.move(to: start); path.addLine(to: end)
                    let angle = atan2(end.y - start.y, end.x - start.x)
                    let wing: CGFloat = 18 * lineScale
                    path.move(to: end)
                    path.addLine(to: CGPoint(x: end.x - wing * cos(angle - .pi / 6), y: end.y - wing * sin(angle - .pi / 6)))
                    path.move(to: end)
                    path.addLine(to: CGPoint(x: end.x - wing * cos(angle + .pi / 6), y: end.y - wing * sin(angle + .pi / 6)))
                    context.stroke(path, with: .color(.red), style: StrokeStyle(lineWidth: 5 * lineScale, lineCap: .round, lineJoin: .round))
                case .blur:
                    context.fill(Path(rect), with: .color(.white.opacity(0.2)))
                    context.stroke(Path(rect), with: .color(.white), lineWidth: 2 * lineScale)
                }
            }
        }
    }
}

private struct CaptureAnnotationEditor: View {
    @State private var image: CGImage
    @State private var annotations: [CaptureAnnotation] = []
    @State private var previousAnnotations: [CaptureAnnotation]?
    @State private var previousImage: CGImage?
    @State private var tool: CaptureAnnotationTool = .arrow
    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    @State private var message = "Choose a tool and draw on the image."

    init(image: CGImage) { _image = State(initialValue: image) }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 5) {
                ForEach(CaptureAnnotationTool.allCases) { item in
                    Button { tool = item } label: {
                        Label(item.title, systemImage: item.symbol).font(.system(size: 11, weight: .medium, design: .rounded))
                            .frame(minHeight: 28).padding(.horizontal, 7).contentShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(CaptureSmallButtonStyle())
                    .help(item.title)
                    .accessibilityIdentifier("capture-annotation-tool-\(item.id)")
                }
                Button("Undo", systemImage: "arrow.uturn.backward") { undo() }
                    .frame(minHeight: 28).help("Undo the last edit").accessibilityIdentifier("capture-annotation-undo")
                Spacer()
                Button("Copy", systemImage: "doc.on.doc") { copyMarkup() }
                    .frame(minHeight: 28).help("Copy annotated image").accessibilityIdentifier("capture-annotation-copy")
                Button("Save", systemImage: "square.and.arrow.down") { saveMarkup() }
                    .frame(minHeight: 28).help("Save annotated image").accessibilityIdentifier("capture-annotation-save")
            }
            GeometryReader { geometry in
                let fit = fittedRect(image: image, in: geometry.size)
                CaptureAnnotationCanvas(image: image, annotations: annotations)
                    .frame(width: fit.width, height: fit.height)
                    .position(x: fit.midX, y: fit.midY)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if dragStart == nil { dragStart = imagePoint(value.startLocation, fit: fit) }
                            dragCurrent = imagePoint(value.location, fit: fit)
                        }
                        .onEnded { value in
                            guard let start = dragStart else { return }
                            let end = imagePoint(value.location, fit: fit)
                            applyTool(from: start, to: end)
                            dragStart = nil; dragCurrent = nil
                        })
            }
            .background(.black)
            Text(message).font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(10).frame(minWidth: 760, minHeight: 500)
        .foregroundStyle(.white).background(Color.black)
    }

    private func fittedRect(image: CGImage, in size: CGSize) -> CGRect {
        let scale = min(size.width / CGFloat(image.width), size.height / CGFloat(image.height))
        let width = CGFloat(image.width) * scale
        let height = CGFloat(image.height) * scale
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    private func imagePoint(_ point: CGPoint, fit: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x / max(fit.width, 1) * CGFloat(image.width), 0), CGFloat(image.width)),
                y: min(max(point.y / max(fit.height, 1) * CGFloat(image.height), 0), CGFloat(image.height)))
    }

    private func applyTool(from start: CGPoint, to end: CGPoint) {
        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: max(1, abs(start.x - end.x)), height: max(1, abs(start.y - end.y)))
        if tool == .text {
            let alert = NSAlert()
            alert.messageText = "Add Text"
            let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 260, height: 24))
            alert.accessoryView = field
            alert.addButton(withTitle: "Add")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return }
            rememberUndo()
            annotations.append(CaptureAnnotation(tool: .text, rect: CGRect(origin: start, size: .zero), text: field.stringValue))
            return
        }
        if tool == .blur {
            rememberUndo()
            if let blurred = pixelate(image: image, selection: rect) { image = blurred; message = "Selected area pixelated." }
            return
        }
        rememberUndo()
        annotations.append(CaptureAnnotation(tool: tool, rect: rect, text: ""))
        message = "\(tool.title) added."
    }

    private func rememberUndo() { previousAnnotations = annotations; previousImage = image }

    private func undo() {
        guard let previousAnnotations else { message = "Nothing to undo."; return }
        annotations = previousAnnotations
        if let previousImage { image = previousImage }
        self.previousAnnotations = nil
        self.previousImage = nil
        message = "Last edit undone."
    }

    private func copyMarkup() {
        guard let output = renderedImage() else { message = "Could not render annotations."; return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([NSImage(cgImage: output, size: NSSize(width: output.width, height: output.height))])
        message = "Annotated image copied."
    }

    private func saveMarkup() {
        guard let output = renderedImage() else { message = "Could not render annotations."; return }
        let format = CaptureFormat(rawValue: UserDefaults.standard.string(forKey: "capture.fileFormat") ?? "PNG") ?? .png
        message = CaptureFiles.save(output, format: format, name: "Annotated-Capture") ? "Annotated image saved." : "Save canceled."
    }

    private func renderedImage() -> CGImage? {
        let renderer = ImageRenderer(content: CaptureAnnotationCanvas(image: image, annotations: annotations)
            .frame(width: CGFloat(image.width), height: CGFloat(image.height)))
        renderer.scale = 1
        return renderer.cgImage
    }

    private func pixelate(image: CGImage, selection: CGRect) -> CGImage? {
        let x = max(0, Int(selection.minX.rounded(.down)))
        let y = max(0, Int(selection.minY.rounded(.down)))
        let width = min(image.width - x, max(1, Int(selection.width.rounded(.up))))
        let height = min(image.height - y, max(1, Int(selection.height.rounded(.up))))
        guard width > 0, height > 0,
              let filter = CIFilter(name: "CIPixellate") else { return nil }
        let source = CIImage(cgImage: image)
        let rect = CGRect(x: CGFloat(x), y: CGFloat(image.height - y - height), width: CGFloat(width), height: CGFloat(height))
        filter.setValue(source, forKey: kCIInputImageKey)
        filter.setValue(NSNumber(value: 14), forKey: kCIInputScaleKey)
        filter.setValue(CIVector(x: rect.midX, y: rect.midY), forKey: kCIInputCenterKey)
        guard let output = filter.outputImage?.cropped(to: rect),
              let patch = CIContext().createCGImage(output, from: rect),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
        context.draw(patch, in: rect)
        return context.makeImage()
    }
}

private struct RecordingStopPill: View {
    let stop: () -> Void

    var body: some View {
        Button(action: stop) {
            Label("Stop", systemImage: "stop.fill")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 28)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background(.white.opacity(0.07), in: Capsule())
        .help("Stop screen recording")
        .accessibilityIdentifier("capture-recording-stop-notch")
    }
}

private final class CaptureRecordingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private enum RecordingStopPanel {
    private static var panel: CaptureRecordingPanel?

    static func show(on screen: NSScreen, stop: @escaping () -> Void) {
        hide()
        let geometry = NotchModel.shared.displayGeometry
        let width = min(max(geometry.coreWidth, 148), 260)
        let height = max(28, min(geometry.height, 42))
        let frame = CGRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height,
                           width: width, height: height)
        let next = CaptureRecordingPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        next.isOpaque = false
        next.backgroundColor = .clear
        next.hasShadow = false
        next.level = .statusBar
        next.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        next.contentView = NSHostingView(rootView: RecordingStopPill(stop: stop).padding(.horizontal, 6).padding(.vertical, 2))
        panel = next
        next.orderFrontRegardless()
    }

    static func hide() {
        panel?.close()
        panel = nil
    }
}

private final class CaptureAnnotationWindowController: NSWindowController, NSWindowDelegate {
    private static var current: CaptureAnnotationWindowController?

    static func present(image: CGImage) {
        if let current { current.showWindow(nil); current.window?.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 650),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Annotate Capture"
        window.backgroundColor = .black
        let controller = CaptureAnnotationWindowController(window: window)
        controller.window?.contentView = NSHostingView(rootView: CaptureAnnotationEditor(image: image))
        controller.window?.delegate = controller
        current = controller
        controller.showWindow(nil)
        controller.window?.center()
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentView = nil
        CaptureImageStore.last = nil
        Self.current = nil
    }
}

// MARK: Settings

struct CaptureSettingsSection: View {
    @AppStorage("capture.fileFormat") private var fileFormat = CaptureFormat.png.rawValue
    @AppStorage("capture.includeCursor") private var includeCursor = true
    @AppStorage("capture.watchInterval") private var watchInterval = 15
    @AppStorage("capture.watchThreshold") private var watchThreshold = 0.02
    @State private var permissionMissing = false
    @State private var folderName = CaptureFiles.saveFolder()?.lastPathComponent ?? "Desktop (first save)"

    var body: some View {
        Section("Capture") {
            NotchFeatureToggle(.capture, "Capture", detail: "Screenshots, annotation, OCR, and screen recording")
            NotchFeatureToggle(.watchRegion, "Watch Region", detail: "Compare a selected area while its watch is active")
            if permissionMissing {
                HStack {
                    Text("Screen Recording access is needed for screenshots, OCR, and recording.")
                    Button("Open Settings", action: CapturePermission.openSettings)
                        .help("Open Screen Recording privacy settings")
                        .accessibilityIdentifier("capture-settings-open-screen-settings")
                }
            }
            HStack {
                Text("Save folder: \(folderName)")
                Spacer()
                Button("Choose…") {
                    CaptureFiles.chooseSaveFolder()
                    folderName = CaptureFiles.saveFolder()?.lastPathComponent ?? "Desktop (first save)"
                }
                .frame(minHeight: 28).help("Choose where captures are saved")
                .accessibilityIdentifier("capture-settings-save-folder")
            }
            Picker("File format", selection: $fileFormat) {
                ForEach(CaptureFormat.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            .accessibilityIdentifier("capture-settings-format")
            Toggle("Include cursor", isOn: $includeCursor)
                .accessibilityIdentifier("capture-settings-cursor")
        }
        Section("Watch Region") {
            Picker("Interval", selection: $watchInterval) {
                Text("5 seconds").tag(5); Text("15 seconds").tag(15); Text("60 seconds").tag(60)
            }
            .accessibilityIdentifier("capture-watch-interval")
            HStack {
                Text("Change threshold")
                Slider(value: $watchThreshold, in: 0.005...0.25, step: 0.005)
                    .accessibilityIdentifier("capture-watch-threshold")
                Text("\(Int(watchThreshold * 100))%")
                    .monospacedDigit().frame(width: 38, alignment: .trailing)
            }
        }
        .onAppear { permissionMissing = !CGPreflightScreenCaptureAccess() }
    }
}
