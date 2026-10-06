import AppKit
import Foundation

struct MediaRemoteTrackSnapshot {
    let title: String
    let artist: String
    let album: String
    let sourceApp: String
    let sourceBundleIdentifier: String
    let processIdentifier: pid_t?
    let isPlaying: Bool
    let duration: Double
    let elapsed: Double
    let artworkData: Data?
}

/// Reads the helper's cached macOS Now Playing stream. Private MediaRemote
/// access stays outside the sandboxed UI process.
final class MediaRemoteAdapter {
    enum Command: Int {
        case play = 0
        case pause = 1
        case togglePlayPause = 2
        case next = 4
        case previous = 5
    }

    private struct Payload: Decodable {
        var title: String?
        var artist: String?
        var album: String?
        var duration: Double?
        var elapsedTime: Double?
        var elapsedTimeNow: Double?
        var timestamp: String?
        var bundleIdentifier: String?
        var processIdentifier: Int32?
        var artworkData: Data?
        var playing: Bool?
        var playbackRate: Double?
    }

    private let queue = DispatchQueue(label: "sidco.notch.mediaremote", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var lastPayloadData: Data?
    private var isPollInFlight = false
    private var onUpdate: ((MediaRemoteTrackSnapshot?) -> Void)?
    private(set) var isRunning = false

    var isAvailable: Bool { true }

    func start(onUpdate: @escaping (MediaRemoteTrackSnapshot?) -> Void) {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            self.onUpdate = onUpdate
            self.isRunning = true

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(750), leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.poll() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.timer?.cancel()
            self.timer = nil
            self.lastPayloadData = nil
            self.isPollInFlight = false
            self.isRunning = false
            self.onUpdate = nil
        }
    }

    func send(_ command: Command) {
        NotchSystemHelperClient.shared.sendMediaCommand(command.rawValue)
    }

    func seek(to seconds: Double) {
        NotchSystemHelperClient.shared.seekMedia(to: max(0, seconds))
    }

    private func poll() {
        guard !isPollInFlight else { return }
        isPollInFlight = true
        NotchSystemHelperClient.shared.currentNowPlaying { [weak self] data in
            guard let self else { return }
            self.queue.async {
                self.isPollInFlight = false
                let payloadChanged = data != self.lastPayloadData
                if payloadChanged { self.lastPayloadData = data }

                let snapshot: MediaRemoteTrackSnapshot?
                if let data {
                    do {
                        snapshot = self.makeSnapshot(from: try JSONDecoder().decode(Payload.self, from: data))
                    } catch {
                        snapshot = nil
                    }
                } else {
                    snapshot = nil
                }
                // Keep the monitor's liveness clock warm even when a paused
                // track's metadata has not changed.
                guard payloadChanged || data != nil else { return }
                let update = self.onUpdate
                DispatchQueue.main.async { update?(snapshot) }
            }
        }
    }

    private func makeSnapshot(from payload: Payload) -> MediaRemoteTrackSnapshot? {
        guard let title = payload.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return nil }

        let bundleID = payload.bundleIdentifier ?? ""
        let isPlaying = payload.playing ?? ((payload.playbackRate ?? 0) > 0)
        var elapsed = max(payload.elapsedTimeNow ?? payload.elapsedTime ?? 0, 0)
        if payload.elapsedTimeNow == nil,
           isPlaying,
           let timestamp = payload.timestamp,
           let date = ISO8601DateFormatter().date(from: timestamp) {
            elapsed += max(0, Date().timeIntervalSince(date))
        }

        return MediaRemoteTrackSnapshot(
            title: title,
            artist: payload.artist?.isEmpty == false ? payload.artist! : "Unknown artist",
            album: payload.album ?? "",
            sourceApp: Self.displayName(for: bundleID),
            sourceBundleIdentifier: bundleID,
            processIdentifier: payload.processIdentifier,
            isPlaying: isPlaying,
            duration: max(payload.duration ?? 0, 0),
            elapsed: elapsed,
            artworkData: payload.artworkData
        )
    }

    private static func displayName(for bundleID: String) -> String {
        let id = bundleID.lowercased()
        if id.contains("google.chrome") { return "Chrome" }
        if id.contains("safari") { return "Safari" }
        if id.contains("spotify") { return "Spotify" }
        if id.contains("music") { return "Music" }
        return "Now Playing"
    }
}
