import AppKit
import CoreServices
import SwiftUI

struct IslandActivity: Identifiable, Equatable {
    enum Kind: Equatable {
        case download
        case event
    }

    let id: UUID
    var symbol: String
    var title: String
    var detail: String
    var progress: Double?
    var tint: Color
    var kind: Kind
    let startedAt: Date
    fileprivate(set) var finishedAt: Date?

    var isFinished: Bool { finishedAt != nil }

    init(
        id: UUID = UUID(),
        symbol: String,
        title: String,
        detail: String = "",
        progress: Double? = nil,
        tint: Color = .white,
        kind: Kind = .event,
        startedAt: Date = .now
    ) {
        self.id = id
        self.symbol = symbol
        self.title = title
        self.detail = detail
        self.progress = IslandActivityProgress.normalized(progress)
        self.tint = tint
        self.kind = kind
        self.startedAt = startedAt
        self.finishedAt = nil
    }

    static func == (lhs: IslandActivity, rhs: IslandActivity) -> Bool {
        lhs.id == rhs.id && lhs.symbol == rhs.symbol && lhs.title == rhs.title &&
            lhs.detail == rhs.detail && lhs.progress == rhs.progress && lhs.kind == rhs.kind &&
            lhs.startedAt == rhs.startedAt && lhs.finishedAt == rhs.finishedAt
    }
}

enum IslandActivityProgress {
    static func normalized(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(max(value, 0), 1)
    }
}

struct ProgressUpdateThrottle {
    static let minimumInterval: TimeInterval = 0.25
    private(set) var lastPublishedAt: Date?

    init(lastPublishedAt: Date? = nil) {
        self.lastPublishedAt = lastPublishedAt
    }

    mutating func shouldPublish(at now: Date) -> Bool {
        guard let lastPublishedAt else {
            self.lastPublishedAt = now
            return true
        }
        guard now.timeIntervalSince(lastPublishedAt) >= Self.minimumInterval else { return false }
        self.lastPublishedAt = now
        return true
    }
}

struct OptimisticToggle: Equatable {
    static let confirmationTimeout: TimeInterval = 1.5
    private(set) var optimisticValue: Bool?
    private(set) var requestedAt: Date?

    func displayedValue(for confirmedValue: Bool) -> Bool {
        optimisticValue ?? confirmedValue
    }

    @discardableResult
    mutating func requestToggle(currentValue: Bool, at date: Date = .now) -> Bool {
        let next = !(optimisticValue ?? currentValue)
        optimisticValue = next
        requestedAt = date
        return next
    }

    mutating func observe(_ confirmedValue: Bool) {
        guard optimisticValue == confirmedValue else { return }
        optimisticValue = nil
        requestedAt = nil
    }

    @discardableResult
    mutating func expire(at date: Date = .now) -> Bool {
        guard let requestedAt, date.timeIntervalSince(requestedAt) >= Self.confirmationTimeout else { return false }
        optimisticValue = nil
        self.requestedAt = nil
        return true
    }
}

struct IslandActivityQueue {
    static let maximumLiveActivities = 4
    static let maximumFinishedActivities = 4
    static let finishedLinger: TimeInterval = 4
    private(set) var activities: [IslandActivity] = []

    var liveCount: Int { activities.filter { !$0.isFinished }.count }

    var topActivity: IslandActivity? {
        activities.filter { !$0.isFinished }.max { $0.startedAt < $1.startedAt }
            ?? activities.filter(\.isFinished).max { ($0.finishedAt ?? .distantPast) < ($1.finishedAt ?? .distantPast) }
    }

    func activity(id: UUID) -> IslandActivity? { activities.first { $0.id == id } }

    mutating func post(_ activity: IslandActivity) {
        activities.removeAll { $0.id == activity.id }
        activities.append(activity)
        let live = activities.filter { !$0.isFinished }.sorted { $0.startedAt < $1.startedAt }
        if live.count > Self.maximumLiveActivities {
            let evicted = Set(live.prefix(live.count - Self.maximumLiveActivities).map(\.id))
            activities.removeAll { evicted.contains($0.id) }
        }
        trimFinishedActivities()
    }

    mutating func update(_ activity: IslandActivity) {
        guard let index = activities.firstIndex(where: { $0.id == activity.id }), !activities[index].isFinished else { return }
        activities[index] = activity
    }

    @discardableResult
    mutating func finish(id: UUID, at date: Date) -> Bool {
        guard let index = activities.firstIndex(where: { $0.id == id }), !activities[index].isFinished else { return false }
        activities[index].finishedAt = date
        trimFinishedActivities()
        return true
    }

    @discardableResult
    mutating func removeExpired(at date: Date) -> Bool {
        let originalCount = activities.count
        activities.removeAll { activity in
            guard let finishedAt = activity.finishedAt else { return false }
            return date.timeIntervalSince(finishedAt) >= Self.finishedLinger
        }
        return activities.count != originalCount
    }

    mutating func clear() { activities.removeAll() }

    private mutating func trimFinishedActivities() {
        let finished = activities.filter(\.isFinished).sorted {
            ($0.finishedAt ?? .distantPast) < ($1.finishedAt ?? .distantPast)
        }
        if finished.count > Self.maximumFinishedActivities {
            let evicted = Set(finished.prefix(finished.count - Self.maximumFinishedActivities).map(\.id))
            activities.removeAll { evicted.contains($0.id) }
        }
    }
}

@MainActor
final class IslandActivityCenter: ObservableObject {
    static let shared = IslandActivityCenter()

    @Published private(set) var activities: [IslandActivity] = []
    private var queue = IslandActivityQueue()
    private var updateThrottles: [UUID: ProgressUpdateThrottle] = [:]
    private var expirationTask: Task<Void, Never>?
    private var isEnabled: Bool

    private init() {
        isEnabled = NotchFeatureRegistry.isEnabled(.islandActivities)
    }

    var topActivity: IslandActivity? { queue.topActivity }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        if !enabled {
            expirationTask?.cancel()
            expirationTask = nil
            updateThrottles.removeAll()
            queue.clear()
            publishIfChanged()
        }
    }

    @discardableResult
    func post(_ activity: IslandActivity, at date: Date = .now) -> UUID? {
        guard isEnabled else { return nil }
        queue.post(activity)
        updateThrottles[activity.id] = ProgressUpdateThrottle(lastPublishedAt: date)
        trimThrottlesToCurrentActivities()
        publishIfChanged()
        scheduleExpiration()
        return activity.id
    }

    @discardableResult
    func post(
        symbol: String,
        title: String,
        detail: String = "",
        progress: Double? = nil,
        tint: Color = .white,
        kind: IslandActivity.Kind = .event,
        at date: Date = .now
    ) -> UUID? {
        post(IslandActivity(symbol: symbol, title: title, detail: detail, progress: progress, tint: tint,
                            kind: kind, startedAt: date), at: date)
    }

    func update(_ activity: IslandActivity, at date: Date = .now) {
        guard isEnabled, let existing = queue.activity(id: activity.id), !existing.isFinished,
              existing != activity else { return }
        var throttle = updateThrottles[activity.id] ?? ProgressUpdateThrottle()
        guard throttle.shouldPublish(at: date) else { return }
        updateThrottles[activity.id] = throttle
        queue.update(activity)
        publishIfChanged()
    }

    func update(id: UUID, title: String? = nil, detail: String? = nil, at date: Date = .now) {
        guard let existing = queue.activity(id: id), !existing.isFinished else { return }
        var updated = existing
        if let title { updated.title = title }
        if let detail { updated.detail = detail }
        update(updated, at: date)
    }

    func update(id: UUID, title: String? = nil, detail: String? = nil, progress: Double?, at date: Date = .now) {
        guard let existing = queue.activity(id: id), !existing.isFinished else { return }
        var updated = existing
        if let title { updated.title = title }
        if let detail { updated.detail = detail }
        updated.progress = IslandActivityProgress.normalized(progress)
        update(updated, at: date)
    }

    func finish(id: UUID, at date: Date = .now) {
        guard queue.finish(id: id, at: date) else { return }
        updateThrottles.removeValue(forKey: id)
        publishIfChanged()
        scheduleExpiration()
    }

    private func publishIfChanged() {
        guard activities != queue.activities else { return }
        activities = queue.activities
    }

    private func trimThrottlesToCurrentActivities() {
        let activityIDs = Set(queue.activities.filter { !$0.isFinished }.map(\.id))
        updateThrottles = updateThrottles.filter { activityIDs.contains($0.key) }
    }

    private func scheduleExpiration() {
        expirationTask?.cancel()
        guard isEnabled,
              let nextExpiry = queue.activities.compactMap(\.finishedAt).map({ $0.addingTimeInterval(IslandActivityQueue.finishedLinger) }).min()
        else {
            expirationTask = nil
            return
        }
        let delay = max(0, nextExpiry.timeIntervalSinceNow)
        expirationTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { return }
            guard let self, self.isEnabled else { return }
            self.queue.removeExpired(at: .now)
            self.publishIfChanged()
            self.scheduleExpiration()
        }
    }
}

enum DownloadClassifier {
    private static let inProgressExtensions: Set<String> = ["download", "crdownload", "part", "partial", "opdownload"]

    static func isInProgress(_ url: URL) -> Bool {
        inProgressExtensions.contains(url.pathExtension.lowercased())
    }

    static func finalName(for url: URL) -> String {
        let name = url.lastPathComponent
        let suffix = url.pathExtension.lowercased()
        guard inProgressExtensions.contains(suffix), name.count > suffix.count + 1 else { return name }
        return String(name.dropLast(suffix.count + 1))
    }
}

struct DownloadFile: Identifiable, Equatable {
    let url: URL
    let size: Int64
    let modifiedAt: Date

    var id: String { url.lastPathComponent }
    var name: String { url.lastPathComponent }
}

@MainActor
final class DownloadsFolderStore: ObservableObject {
    static let shared = DownloadsFolderStore()
    static let bookmarkDefaultsKey = "notch.downloads.folderBookmark"
    private static let maximumVisibleFiles = 12
    private static let maximumTrackedDownloads = 4

    @Published private(set) var files: [DownloadFile] = []
    @Published private(set) var selectedFolderPath: String?
    @Published private(set) var isWatching = false
    @Published private(set) var message: String?

    private struct TrackedDownload {
        var activityID: UUID
        var lastSize: Int64
    }

    private let defaults: UserDefaults
    private var featureEnabled = false
    private var stream: FSEventStreamRef?
    private var scopedFolderURL: URL?
    private var ownsSecurityScope = false
    private var trackedDownloads: [String: TrackedDownload] = [:]

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedFolderPath = Self.resolveBookmark(defaults.data(forKey: Self.bookmarkDefaultsKey))?.path
    }

    func setFeatureEnabled(_ enabled: Bool) {
        guard featureEnabled != enabled else { return }
        featureEnabled = enabled
        if enabled { startWatching() } else { stopWatching() }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Folder"
        panel.message = "Choose a folder to watch for downloads."
        let suggestion = selectedFolderPath.map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        panel.directoryURL = suggestion
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            defaults.set(bookmark, forKey: Self.bookmarkDefaultsKey)
            selectedFolderPath = url.path
            message = nil
            if featureEnabled {
                stopWatching()
                startWatching()
            }
        } catch {
            message = "Could not save access to that folder. Choose it again."
        }
    }

    func open(_ file: DownloadFile) {
        guard isWatching else { return }
        NSWorkspace.shared.open(file.url)
    }

    func reveal(_ file: DownloadFile) {
        guard isWatching else { return }
        NSWorkspace.shared.activateFileViewerSelecting([file.url])
    }

    func addToShelf(_ file: DownloadFile) {
        guard isWatching else { return }
        ShelfStore.shared.add(urls: [file.url])
    }

    func moveToTrash(_ file: DownloadFile) {
        guard isWatching else { return }
        do {
            try FileManager.default.trashItem(at: file.url, resultingItemURL: nil)
            refreshFromDisk()
        } catch {
            message = "Could not move \(file.name) to Trash."
        }
    }

    private func startWatching() {
        guard featureEnabled, stream == nil else { return }
        guard let bookmark = defaults.data(forKey: Self.bookmarkDefaultsKey) else {
            selectedFolderPath = nil
            message = "Choose a folder to watch for downloads."
            return
        }
        var isStale = false
        guard let folder = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &isStale) else {
            selectedFolderPath = nil
            message = "Folder access expired. Choose the folder again."
            return
        }
        selectedFolderPath = folder.path
        guard folder.startAccessingSecurityScopedResource() else {
            message = "Folder access is unavailable. Choose the folder again."
            return
        }
        scopedFolderURL = folder
        ownsSecurityScope = true
        if isStale, let renewed = try? folder.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(renewed, forKey: Self.bookmarkDefaultsKey)
        }
        guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            message = "The selected location is no longer a folder. Choose another folder."
            releaseScopedFolder()
            return
        }

        let callback: FSEventStreamCallback = { _, clientInfo, _, _, _, _ in
            guard let clientInfo else { return }
            let store = Unmanaged<DownloadsFolderStore>.fromOpaque(clientInfo).takeUnretainedValue()
            Task { @MainActor [weak store] in store?.refreshFromDisk() }
        }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let newStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [folder.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.25,
            flags
        ) else {
            message = "Folder monitoring could not start."
            releaseScopedFolder()
            return
        }
        stream = newStream
        FSEventStreamSetDispatchQueue(newStream, DispatchQueue.main)
        guard FSEventStreamStart(newStream) else {
            message = "Folder monitoring could not start."
            stopWatching()
            return
        }
        message = nil
        isWatching = true
        refreshFromDisk()
    }

    private func stopWatching() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        isWatching = false
        for tracked in trackedDownloads.values {
            IslandActivityCenter.shared.finish(id: tracked.activityID)
        }
        trackedDownloads.removeAll()
        files = []
        releaseScopedFolder()
    }

    private func releaseScopedFolder() {
        if ownsSecurityScope { scopedFolderURL?.stopAccessingSecurityScopedResource() }
        scopedFolderURL = nil
        ownsSecurityScope = false
    }

    private func refreshFromDisk() {
        guard featureEnabled, isWatching, let folder = scopedFolderURL else { return }
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            let entries = urls.compactMap { url -> (URL, URLResourceValues)? in
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]),
                      values.isSymbolicLink != true else { return nil }
                return (url, values)
            }
            updateDownloadActivities(entries)
            let nextFiles = entries.compactMap { url, values -> DownloadFile? in
                guard values.isRegularFile == true, !DownloadClassifier.isInProgress(url) else { return nil }
                return DownloadFile(url: url, size: Int64(values.fileSize ?? 0), modifiedAt: values.contentModificationDate ?? .distantPast)
            }
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(Self.maximumVisibleFiles)
            .map { $0 }
            if files != nextFiles { files = nextFiles }
            message = nil
        } catch {
            message = "Could not read the selected folder."
        }
    }

    private func updateDownloadActivities(_ entries: [(URL, URLResourceValues)]) {
        let activeEntries = entries
            .filter { DownloadClassifier.isInProgress($0.0) && $0.1.isRegularFile == true }
            .sorted { ($0.1.contentModificationDate ?? .distantPast) > ($1.1.contentModificationDate ?? .distantPast) }
            .prefix(Self.maximumTrackedDownloads)
        var next: [String: TrackedDownload] = [:]
        for (url, values) in activeEntries {
            let path = url.path
            let size = Int64(values.fileSize ?? 0)
            if var tracked = trackedDownloads[path] {
                if tracked.lastSize != size {
                    IslandActivityCenter.shared.update(
                        id: tracked.activityID,
                        title: DownloadClassifier.finalName(for: url),
                        detail: Self.sizeDescription(size),
                        progress: nil
                    )
                    tracked.lastSize = size
                }
                next[path] = tracked
            } else if let activityID = IslandActivityCenter.shared.post(
                symbol: "arrow.down.circle.fill",
                title: DownloadClassifier.finalName(for: url),
                detail: Self.sizeDescription(size),
                tint: .cyan,
                kind: .download
            ) {
                next[path] = TrackedDownload(activityID: activityID, lastSize: size)
            }
        }
        for (path, tracked) in trackedDownloads where next[path] == nil {
            IslandActivityCenter.shared.finish(id: tracked.activityID)
        }
        trackedDownloads = next
    }

    private static func sizeDescription(_ size: Int64) -> String {
        "\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) downloaded"
    }

    private static func resolveBookmark(_ data: Data?) -> URL? {
        guard let data else { return nil }
        var isStale = false
        return try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &isStale)
    }
}

enum IslandFeature {
    static func apply(_ feature: NotchFeature, enabled: Bool) {
        switch feature {
        case .islandActivities:
            Task { @MainActor in IslandActivityCenter.shared.setEnabled(enabled) }
        case .downloadsPage:
            Task { @MainActor in DownloadsFolderStore.shared.setFeatureEnabled(enabled) }
        default:
            break
        }
    }
}

@MainActor
struct DownloadsToolView: View {
    @StateObject private var store = DownloadsFolderStore.shared
    @AppStorage(NotchFeature.downloadsPage.defaultsKey) private var downloadsEnabled = NotchFeature.downloadsPage.defaultEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button("Choose Folder…") { store.chooseFolder() }
                    .frame(minHeight: 28)
                    .contentShape(Rectangle())
                    .help("Choose the folder to watch for downloads")
                    .accessibilityIdentifier("downloads-choose-folder")
                Text(store.selectedFolderPath ?? "No folder selected")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.white.opacity(0.56))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("downloads-folder-path")
            }
            if let message = store.message {
                Text(message).font(.system(size: 10)).foregroundStyle(.white.opacity(0.58)).lineLimit(1)
            }
            if !downloadsEnabled {
                Text("Turn on Downloads in Island settings to watch this folder.")
                    .font(.system(size: 11, design: .rounded)).foregroundStyle(.white.opacity(0.58))
            } else if !store.isWatching {
                Text(store.selectedFolderPath == nil ? "Choose a folder to start watching downloads." : "Folder monitoring is unavailable.")
                    .font(.system(size: 11, design: .rounded)).foregroundStyle(.white.opacity(0.58))
            } else if store.files.isEmpty {
                Text("No files in this folder yet.")
                    .font(.system(size: 11, design: .rounded)).foregroundStyle(.white.opacity(0.58))
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(store.files) { file in
                            DownloadFileRow(file: file, store: store)
                        }
                    }
                }
                .accessibilityIdentifier("downloads-file-list")
            }
        }
        .foregroundStyle(.white)
    }
}

@MainActor
private struct DownloadFileRow: View {
    let file: DownloadFile
    let store: DownloadsFolderStore

    private var token: String {
        file.name.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "-" }.joined()
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.fill")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 19)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name).font(.system(size: 10, weight: .medium, design: .rounded)).lineLimit(1)
                Text("\(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)) · \(RelativeDateTimeFormatter().localizedString(for: file.modifiedAt, relativeTo: .now))")
                    .font(.system(size: 9, design: .rounded)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            }
            Spacer(minLength: 4)
            action("arrow.up.right", title: "Open", id: "open") { store.open(file) }
            action("magnifyingglass", title: "Reveal in Finder", id: "reveal") { store.reveal(file) }
            action("tray.and.arrow.down", title: "Add to Shelf", id: "shelf") { store.addToShelf(file) }
            action("trash", title: "Delete to Trash", id: "trash") { store.moveToTrash(file) }
        }
        .padding(.horizontal, 6)
        .frame(minHeight: 34)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    private func action(_ symbol: String, title: String, id: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(minWidth: 28, minHeight: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!store.isWatching)
        .help("\(title) \(file.name)")
        .accessibilityLabel("\(title) \(file.name)")
        .accessibilityIdentifier("downloads-\(id)-\(token)")
    }
}

@MainActor
struct IslandSettingsSection: View {
    @ObservedObject private var downloads = DownloadsFolderStore.shared

    var body: some View {
        Section("Island Activities") {
            NotchFeatureToggle(.islandActivities, "Live activities", detail: "Show downloads and event progress in the closed notch.")
            NotchFeatureToggle(.downloadsPage, "Downloads", detail: "Watch a chosen folder for in-progress and recent downloads.")
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Watched folder")
                    Text(downloads.selectedFolderPath ?? "No folder selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityIdentifier("island-watched-folder-path")
                }
                Spacer(minLength: 4)
                Button("Change…") { downloads.chooseFolder() }
                    .frame(minHeight: 28)
                    .contentShape(Rectangle())
                    .help("Choose the folder to watch for downloads")
                    .accessibilityIdentifier("island-change-folder")
            }
        }
    }
}
