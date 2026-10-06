import AppKit
import AVFoundation
import Combine
import SwiftUI

/// Height maths for the Mirror module (pure, unit-tested).
enum MirrorLayout {
    static let fallbackAspect: CGFloat = 16.0 / 10.0
    /// Pane title row plus its spacing, above the preview.
    static let paneHeaderHeight: CGFloat = 34
    /// Horizontal inset of the content area inside the expanded panel (rails + padding).
    static func previewWidth(destinationWidth: CGFloat, railThickness: CGFloat) -> CGFloat {
        max(0, destinationWidth - railThickness * 2 - 24)
    }

    /// Expanded height so the preview area has the camera aspect. Never shrinks below `base.height`.
    static func expandedHeight(base: CGSize, contentHeight: CGFloat, railThickness: CGFloat, aspect: CGFloat?, maxHeight: CGFloat) -> CGFloat {
        let ratio = (aspect.map { $0.isFinite && $0 > 0 } ?? false) ? aspect! : fallbackAspect
        let previewHeight = previewWidth(destinationWidth: base.width, railThickness: railThickness) / ratio
        let growth = max(0, previewHeight + paneHeaderHeight - contentHeight)
        return max(base.height, min(base.height + growth, maxHeight))
    }
}

/// Camera aspect (width / height), published once per device change.
final class MirrorAspectStore: ObservableObject {
    static let shared = MirrorAspectStore()
    @Published private(set) var aspect: CGFloat?

    func update(from session: AVCaptureSession) {
        let device = session.inputs.compactMap { ($0 as? AVCaptureDeviceInput)?.device }.first
        guard let dims = device.map({ CMVideoFormatDescriptionGetDimensions($0.activeFormat.formatDescription) }),
              dims.width > 0, dims.height > 0 else { return }
        let value = CGFloat(dims.width) / CGFloat(dims.height)
        if aspect != value { aspect = value }
    }
}

struct CompactMirrorPane: View {
    @StateObject private var camera = CameraPreviewController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Mirror")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                    Text(camera.isRunning ? "Live, private preview" : "Camera stays off until requested")
                        .font(.system(size: 8, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.42))
                }
                Spacer()
                if camera.authorizationStatus == .authorized && camera.isAvailable && camera.isRunning {
                    Button {
                        camera.stop()
                    } label: {
                        Image(systemName: "stop.fill")
                    }
                        .buttonStyle(ChromeButtonStyle(size: 22))
                        .help("Stop camera")
                        .accessibilityLabel("Stop")
                }
            }

            Group {
                switch camera.authorizationStatus {
                case .authorized where camera.isAvailable:
                    ZStack(alignment: .bottomLeading) {
                        CameraPreview(session: camera.session)
                            .background(.black)
                            .opacity(camera.isRunning ? 1 : 0.22)
                        if !camera.isRunning {
                            Button("Start camera") { camera.start() }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.mini)
                                .tint(NotchModule.mirror.tint)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        Label(camera.isRunning ? "Live" : "Paused", systemImage: "circle.fill")
                            .font(.system(size: 8, weight: .semibold, design: .rounded))
                            .foregroundStyle(camera.isRunning ? .green : .white.opacity(0.5))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.58), in: Capsule())
                            .padding(6)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                case .notDetermined:
                    VStack(spacing: 7) {
                        Image(systemName: "camera.badge.ellipsis")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(NotchModule.mirror.tint)
                        Text("A private mirror for your Mac")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                        Button("Allow Camera") { camera.requestAccess() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.mini)
                            .tint(NotchModule.mirror.tint)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                case .denied, .restricted:
                    VStack(spacing: 7) {
                        Image(systemName: "camera.slash").foregroundStyle(.secondary)
                        Text("Camera access is off").font(.system(size: 10, weight: .semibold, design: .rounded))
                        Button("Open Settings") { camera.openSettings() }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                default:
                    EmptyRow(symbol: "camera.slash", title: "No camera available", detail: "Connect a camera and try again.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: camera.isRunning) { _, running in
            if running { MirrorAspectStore.shared.update(from: camera.session) }
        }
        .onDisappear { camera.stop() }
        .accessibilityIdentifier("mirror-panel")
    }
}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> CameraPreviewView {
        CameraPreviewView(session: session)
    }

    func updateNSView(_ nsView: CameraPreviewView, context: Context) {
        nsView.session = session
    }
}

final class CameraPreviewView: NSView {
    private let previewLayer = AVCaptureVideoPreviewLayer()

    var session: AVCaptureSession? {
        didSet { previewLayer.session = session }
    }

    init(session: AVCaptureSession) {
        self.session = session
        super.init(frame: .zero)
        wantsLayer = true
        previewLayer.videoGravity = .resizeAspect
        previewLayer.session = session
        layer?.addSublayer(previewLayer)
        if let connection = previewLayer.connection, connection.isVideoMirroringSupported {
            // Setting isVideoMirrored while automatic adjustment is on throws.
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }
}

