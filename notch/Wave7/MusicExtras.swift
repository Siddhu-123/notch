import AppKit
import ApplicationServices
import Combine
import Foundation
import ImageIO
import SwiftUI

struct LyricLine: Equatable, Identifiable {
    let time: TimeInterval
    let text: String

    var id: String { "\(time):\(text)" }
}

enum LyricsParser {
    private static let timestampPattern = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{2})(?:\.(\d{1,3}))?\]"#)

    static func parse(_ text: String) -> [LyricLine] {
        var parsed: [(offset: Int, line: LyricLine)] = []
        var order = 0

        for rawLine in text.components(separatedBy: .newlines) {
            let range = NSRange(rawLine.startIndex..<rawLine.endIndex, in: rawLine)
            let matches = timestampPattern.matches(in: rawLine, range: range)
            guard !matches.isEmpty else { continue }

            let lyricText = timestampPattern.stringByReplacingMatches(in: rawLine, range: range, withTemplate: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !lyricText.isEmpty else { continue }

            for match in matches {
                guard let minuteRange = Range(match.range(at: 1), in: rawLine),
                      let secondRange = Range(match.range(at: 2), in: rawLine),
                      let minutes = Int(rawLine[minuteRange]),
                      let seconds = Int(rawLine[secondRange]), seconds < 60 else { continue }

                var fraction: TimeInterval = 0
                if match.range(at: 3).location != NSNotFound,
                   let fractionRange = Range(match.range(at: 3), in: rawLine) {
                    let digits = String(rawLine[fractionRange])
                    if let value = Int(digits) {
                        fraction = TimeInterval(value) / pow(10, Double(digits.count))
                    }
                }
                parsed.append((order, LyricLine(time: TimeInterval(minutes * 60 + seconds) + fraction, text: lyricText)))
                order += 1
            }
        }

        return parsed.sorted {
            $0.line.time == $1.line.time ? $0.offset < $1.offset : $0.line.time < $1.line.time
        }.map(\.line)
    }

    static func currentLineIndex(in lines: [LyricLine], at elapsed: TimeInterval) -> Int? {
        guard elapsed >= 0, !lines.isEmpty else { return nil }
        return lines.lastIndex { $0.time <= elapsed }
    }
}

enum MusicKeyGuard {
    static let playKeyCode = 16

    static func shouldSwallow(keyCode: Int, isKeyDown: Bool, hasPlayer: Bool, musicRunning: Bool) -> Bool {
        keyCode == playKeyCode && isKeyDown && !hasPlayer && !musicRunning
    }
}

struct MusicUpcomingTrack: Identifiable {
    let index: Int
    let title: String
    let artist: String
    let coverCacheKey: String

    var id: String { "\(index)|\(title)|\(artist)" }
}

struct MusicLyrics: Equatable {
    let timedLines: [LyricLine]
    let plainText: String

    init(_ text: String) {
        timedLines = LyricsParser.parse(text)
        plainText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isEmpty: Bool { plainText.isEmpty && timedLines.isEmpty }
}

private final class CachedLyrics: NSObject {
    let value: MusicLyrics?

    init(_ value: MusicLyrics?) { self.value = value }
}

enum MusicExtrasCache {
    private static let covers: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 20
        return cache
    }()
    private static let lyricsCache: NSCache<NSString, CachedLyrics> = {
        let cache = NSCache<NSString, CachedLyrics>()
        cache.countLimit = 10
        return cache
    }()

    static func cover(for key: String) -> NSImage? { covers.object(forKey: key as NSString) }
    static func storeCover(_ image: NSImage, for key: String) { covers.setObject(image, forKey: key as NSString) }
    static func storeCoverData(_ data: Data, for key: String) {
        guard data.count <= 12_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 144,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return }
        let thumbnail = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        covers.setObject(thumbnail, forKey: key as NSString, cost: image.width * image.height * 4)
    }
    static func lyrics(for key: String) -> MusicLyrics?? {
        guard let cached = lyricsCache.object(forKey: key as NSString) else { return nil }
        return cached.value
    }
    static func storeLyrics(_ value: MusicLyrics?, for key: String) {
        lyricsCache.setObject(CachedLyrics(value), forKey: key as NSString)
    }
}

enum MusicExtrasService {
    static let musicBundleID = "com.apple.Music"

    static func isMusicRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: musicBundleID).isEmpty
    }

    static func hasMusicAutomationAccess() -> Bool {
        guard isMusicRunning() else { return false }
        let target = NSAppleEventDescriptor(bundleIdentifier: musicBundleID)
        return AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, false) == noErr
    }

    static func lyricsCacheKey(artist: String, title: String, duration: Double) -> String {
        "\(artist.lowercased())\u{0}\(title.lowercased())\u{0}\(Int(duration.rounded()))"
    }

    static func readUpcoming(currentTitle: String, currentArtist: String) -> [MusicUpcomingTrack] {
        guard isMusicRunning(), hasMusicAutomationAccess() else { return [] }
        let script = #"""
        tell application "Music"
            if not it is running then return {}
            try
                set currentName to name of current track as text
                set currentArtist to artist of current track as text
                set sourcePlaylist to current playlist
                set currentIndex to index of current track
                set totalTracks to count of tracks of sourcePlaylist
                set firstIndex to currentIndex + 1
                set lastIndex to currentIndex + 5
                if lastIndex > totalTracks then set lastIndex to totalTracks
                set rows to {}
                if firstIndex ≤ lastIndex then
                    repeat with trackIndex from firstIndex to lastIndex
                        set trackRef to track trackIndex of sourcePlaylist
                        set trackTitle to name of trackRef as text
                        set trackArtist to artist of trackRef as text
                        set coverData to ""
                        try
                            if (count of artworks of trackRef) > 0 then set coverData to raw data of artwork 1 of trackRef
                        end try
                        set end of rows to {trackIndex as integer, trackTitle, trackArtist, coverData}
                    end repeat
                end if
                return {currentName, currentArtist, rows}
            on error
                return {}
            end try
        end tell
        """#

        guard let result = runMusicScript(script), result.numberOfItems == 3,
              result.atIndex(1)?.stringValue == currentTitle,
              result.atIndex(2)?.stringValue == currentArtist,
              let rows = result.atIndex(3) else { return [] }

        var tracks: [MusicUpcomingTrack] = []
        guard rows.numberOfItems > 0 else { return tracks }
        for item in 1...min(rows.numberOfItems, 5) {
            guard let row = rows.atIndex(item), row.numberOfItems == 4,
                  let indexValue = row.atIndex(1)?.int32Value, indexValue > 0,
                  let title = row.atIndex(2)?.stringValue, !title.isEmpty else { continue }
            let artist = row.atIndex(3)?.stringValue ?? ""
            let key = "\(currentTitle)|\(currentArtist)|\(indexValue)|\(title)|\(artist)"
            if let artworkData = row.atIndex(4)?.data, !artworkData.isEmpty {
                MusicExtrasCache.storeCoverData(artworkData, for: key)
            }
            tracks.append(MusicUpcomingTrack(index: Int(indexValue), title: title, artist: artist, coverCacheKey: key))
        }
        return tracks
    }

    static func playUpcoming(trackIndex: Int) {
        guard trackIndex > 0, isMusicRunning(), hasMusicAutomationAccess() else { return }
        _ = runMusicScript(#"tell application "Music" to play track \#(trackIndex) of current playlist"#)
    }

    static func loadLyrics(artist: String, title: String, duration: Double) async -> MusicLyrics? {
        let key = lyricsCacheKey(artist: artist, title: title, duration: duration)
        if let cached = MusicExtrasCache.lyrics(for: key) { return cached }

        let embedded = await Task.detached(priority: .utility) {
            readEmbeddedLyrics(expectedTitle: title, expectedArtist: artist)
        }.value
        if let embedded, embedded.utf8.count <= 256_000,
           !embedded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let value = MusicLyrics(embedded)
            MusicExtrasCache.storeLyrics(value, for: key)
            return value
        }

        let fetched = await fetchLRCLyrics(artist: artist, title: title, duration: duration)
        MusicExtrasCache.storeLyrics(fetched, for: key)
        return fetched
    }

    private static func readEmbeddedLyrics(expectedTitle: String, expectedArtist: String) -> String? {
        guard isMusicRunning(), hasMusicAutomationAccess() else { return nil }
        let script = #"""
        tell application "Music"
            if not it is running then return {}
            try
                return {name of current track as text, artist of current track as text, lyrics of current track}
            on error
                return {}
            end try
        end tell
        """#
        guard let result = runMusicScript(script), result.numberOfItems == 3,
              result.atIndex(1)?.stringValue == expectedTitle,
              result.atIndex(2)?.stringValue == expectedArtist else { return nil }
        return result.atIndex(3)?.stringValue
    }

    private static func fetchLRCLyrics(artist: String, title: String, duration: Double) async -> MusicLyrics? {
        guard !artist.isEmpty, !title.isEmpty, duration > 0,
              var components = URLComponents(string: "https://lrclib.net/api/get") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "duration", value: String(Int(duration.rounded())))
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse,
                  response.statusCode == 200, data.count <= 256_000,
                  let payload = try? JSONDecoder().decode(LRCLyricsResponse.self, from: data) else { return nil }
            if let synced = payload.syncedLyrics, !synced.isEmpty { return MusicLyrics(synced) }
            if let plain = payload.plainLyrics, !plain.isEmpty { return MusicLyrics(plain) }
        } catch {
            return nil
        }
        return nil
    }

    private static func runMusicScript(_ source: String) -> NSAppleEventDescriptor? {
        guard isMusicRunning(), hasMusicAutomationAccess() else { return nil }
        var error: NSDictionary?
        let script = NSAppleScript(source: "with timeout of 2 seconds\n\(source)\nend timeout")
        let result = script?.executeAndReturnError(&error)
        return error == nil ? result : nil
    }

}

private struct LRCLyricsResponse: Decodable {
    let syncedLyrics: String?
    let plainLyrics: String?
}

enum MusicExtrasFeature {
    private static var keyGuardCancellable: AnyCancellable?
    private static var keyGuardEnabled = false

    static func apply(_ feature: NotchFeature, enabled: Bool) {
        guard feature == .musicKeyGuard else { return }
        if enabled {
            if !keyGuardEnabled {
                keyGuardEnabled = true
                keyGuardCancellable = NowPlayingMonitor.shared.$song
                    .map { ($0.id + "|" + $0.sourceApp + "|" + String($0.hasTrack) + "|" + String($0.isPlaying), $0.hasTrack) }
                    .removeDuplicates { $0.0 == $1.0 }
                    .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
                    .dropFirst()
                    .sink { state in sendKeyGuard(enabled: true, hasPlayer: state.1) }
            }
            sendKeyGuard(enabled: true, hasPlayer: NowPlayingMonitor.shared.song.hasTrack)
        } else {
            keyGuardCancellable?.cancel()
            keyGuardCancellable = nil
            keyGuardEnabled = false
            sendKeyGuard(enabled: false, hasPlayer: false)
        }
    }

    private static func sendKeyGuard(enabled: Bool, hasPlayer: Bool) {
        NotchSystemHelperClient.shared.perform(
            "media",
            "setKeyGuard",
            args: ["enabled": enabled, "hasPlayer": hasPlayer],
            timeout: 2
        ) { _ in }
    }
}

struct MusicSettingsSection: View {
    @AppStorage(NotchFeature.upNext.defaultsKey) private var upNextEnabled = NotchFeature.upNext.defaultEnabled
    @AppStorage(NotchFeature.lyrics.defaultsKey) private var lyricsEnabled = NotchFeature.lyrics.defaultEnabled
    @AppStorage(NotchFeature.musicKeyGuard.defaultsKey) private var keyGuardEnabled = NotchFeature.musicKeyGuard.defaultEnabled
    @State private var helperHasAccessibility: Bool?
    @State private var appHasAccessibility = AXIsProcessTrusted()
    @State private var musicRunning = false
    @State private var musicAutomationAllowed: Bool?

    private var accessibilityMissing: Bool {
        helperHasAccessibility == false || (helperHasAccessibility == nil && !appHasAccessibility)
    }

    var body: some View {
        Section("Music") {
            NotchFeatureToggle(.upNext, "Up Next", detail: "Show the next five tracks in the current Apple Music playlist.")
            NotchFeatureToggle(.lyrics, "Lyrics", detail: "Show track lyrics with synced highlighting when available.")
            NotchFeatureToggle(.musicKeyGuard, "Music launch guard", detail: "Keep the Play key from launching Music when no player is active.")

            if keyGuardEnabled && accessibilityMissing {
                permissionRow(
                    "Accessibility is needed to filter the Play key before Music launches.",
                    identifier: "music-open-accessibility-settings",
                    permission: .accessibility
                )
            }

            if (upNextEnabled || lyricsEnabled), musicRunning, musicAutomationAllowed == false {
                permissionRow(
                    "Allow Notch to control Music for playlist details and embedded lyrics.",
                    identifier: "music-open-automation-settings",
                    permission: .automation
                )
            }
        }
        .onAppear(perform: refreshPermissions)
        .onChange(of: keyGuardEnabled) { _, _ in refreshPermissions() }
        .onChange(of: upNextEnabled) { _, _ in refreshPermissions() }
        .onChange(of: lyricsEnabled) { _, _ in refreshPermissions() }
    }

    private func permissionRow(_ message: String, identifier: String, permission: NotchPermission) -> some View {
        HStack(spacing: 8) {
            Text(message).font(.caption).foregroundStyle(.secondary)
            Button("Open Settings") {
                if let url = permission.settingsURL { NSWorkspace.shared.open(url) }
            }
            .frame(minHeight: 28)
            .contentShape(Rectangle())
            .help("Open \(permission.title) privacy settings.")
            .accessibilityIdentifier(identifier)
            Button("Check Again", action: refreshPermissions)
                .frame(minHeight: 28)
                .contentShape(Rectangle())
                .help("Check \(permission.title) permission again.")
                .accessibilityIdentifier("\(identifier)-check")
        }
    }

    private func refreshPermissions() {
        appHasAccessibility = AXIsProcessTrusted()
        musicRunning = MusicExtrasService.isMusicRunning()
        musicAutomationAllowed = musicRunning ? MusicExtrasService.hasMusicAutomationAccess() : nil

        guard keyGuardEnabled else {
            helperHasAccessibility = nil
            return
        }
        NotchSystemHelperClient.shared.perform("media", "keyGuardStatus", timeout: 2) { result in
            DispatchQueue.main.async {
                helperHasAccessibility = result?["accessibilityTrusted"] as? Bool
            }
        }
    }
}
