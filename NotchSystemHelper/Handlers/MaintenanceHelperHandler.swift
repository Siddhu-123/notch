import AppKit
import CryptoKit
import Darwin
import Foundation
import ServiceManagement

/// J12 maintenance operations. All filesystem and process work stays in the unsandboxed helper.
enum MaintenanceHelperHandler: HelperHandler {
    private static let scanLock = NSLock()
    private static var scans: [String: MaintenanceScanCancellation] = [:]
    private static let processLock = NSLock()
    private static var recentMemoryPIDs: Set<Int32> = []
    private static var recentMemoryDate = Date.distantPast

    static func handle(action: String, args: HelperArgs, reply: @escaping (HelperArgs?) -> Void) {
        switch action {
        case "scan":
            guard let kind = args["kind"] as? String,
                  let id = args["requestID"] as? String, !id.isEmpty, id.count <= 80 else {
                reply(["error": "A scan kind and request ID are required."])
                return
            }
            let cancellation = MaintenanceScanCancellation()
            scanLock.lock()
            scans[id]?.cancel()
            scans[id] = cancellation
            scanLock.unlock()
            DispatchQueue.global(qos: .utility).async {
                var result = scan(kind: kind, args: args, cancellation: cancellation)
                scanLock.lock()
                if scans[id] === cancellation { scans.removeValue(forKey: id) }
                scanLock.unlock()
                result["requestID"] = id
                reply(result)
            }
        case "cancel":
            guard let id = args["requestID"] as? String else { reply(["cancelled": false]); return }
            scanLock.lock()
            let scan = scans[id]
            scanLock.unlock()
            scan?.cancel()
            reply(["cancelled": scan != nil])
        case "trash":
            reply(trash(paths: args["paths"] as? [String] ?? []))
        case "quit":
            guard let pid = args["pid"] as? Int32 else { reply(["error": "Invalid process ID."]); return }
            reply(quit(pid: pid))
        case "ping": reply(["ok": true])
        default: reply(HelperRouter.unknown(action))
        }
    }

    private static func scan(kind: String, args: HelperArgs, cancellation: MaintenanceScanCancellation) -> HelperArgs {
        let deadline: Date
        switch kind {
        case "disk": deadline = Date().addingTimeInterval(20)
        case "clean", "uninstall": deadline = Date().addingTimeInterval(30)
        case "duplicates": deadline = Date().addingTimeInterval(120)
        default: deadline = Date().addingTimeInterval(10)
        }

        let items: [[String: Any]]
        var limitReached = false
        switch kind {
        case "disk": items = diskUsage(cancellation: cancellation, deadline: deadline)
        case "clean": items = cleanupSizes(cancellation: cancellation, deadline: deadline)
        case "uninstall":
            guard let app = validatedApplication(at: URL(fileURLWithPath: args["appPath"] as? String ?? "")),
                  let info = appBundleInfo(at: app), let bundleID = info.bundleID else {
                return ["error": "Choose a supported app from /Applications. System apps and Notch are protected."]
            }
            items = uninstallLeftovers(app: app, name: info.name, bundleID: bundleID, cancellation: cancellation, deadline: deadline)
        case "duplicates":
            let result = duplicates(rootPath: args["root"] as? String ?? "", cancellation: cancellation, deadline: deadline)
            items = result.items
            limitReached = result.limitReached
        case "startup": items = startupItems(cancellation: cancellation)
        case "memory": items = memorySnapshot(cancellation: cancellation)
        default: return ["error": "Unknown scan kind."]
        }
        return ["items": items, "cancelled": cancellation.isCancelled, "truncated": Date() >= deadline || limitReached]
    }

    private static func diskUsage(cancellation: MaintenanceScanCancellation, deadline: Date) -> [[String: Any]] {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let rootPath = home.path
        var folderBytes: [String: Int64] = [:]
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: home, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true }) else { return [] }
        for case let url as URL in enumerator {
            if cancellation.isCancelled || Date() >= deadline { break }
            guard url.standardizedFileURL.path.hasPrefix(rootPath + "/"),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isSymbolicLink != true,
                  values.isRegularFile == true else { continue }
            let relative = url.standardizedFileURL.path
                .replacingOccurrences(of: rootPath + "/", with: "")
                .split(separator: "/")
            guard relative.count >= 2 else { continue }
            let size = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
            for depth in 1...min(2, relative.count - 1) {
                let candidate = home.appendingPathComponent(relative.prefix(depth).joined(separator: "/"), isDirectory: true).path
                folderBytes[candidate, default: 0] += max(0, size)
            }
        }
        return folderBytes
            .map { ["path": $0.key, "size": $0.value] }
            .sorted { ($0["size"] as? Int64 ?? 0) > ($1["size"] as? Int64 ?? 0) }
            .prefix(10)
            .map { $0 }
    }

    private static func cleanupSizes(cancellation: MaintenanceScanCancellation, deadline: Date) -> [[String: Any]] {
        var items: [[String: Any]] = []
        for (category, root) in CleanupScope.cleanupRoots() {
            guard !cancellation.isCancelled, Date() < deadline,
                  let children = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []) else { continue }
            for child in children {
                if cancellation.isCancelled || Date() >= deadline { break }
                guard CleanupScope.isAllowed(path: child.path),
                      let values = try? child.resourceValues(forKeys: [.isSymbolicLinkKey]),
                      values.isSymbolicLink != true else { continue }
                let bytes = allocatedSize(at: child, cancellation: cancellation, deadline: deadline)
                items.append(["path": child.path, "size": bytes, "category": category])
            }
        }
        return items
    }

    private static func uninstallLeftovers(app: URL, name: String, bundleID: String, cancellation: MaintenanceScanCancellation, deadline: Date) -> [[String: Any]] {
        var items: [[String: Any]] = [["path": app.path, "size": allocatedSize(at: app, cancellation: cancellation, deadline: deadline), "isApp": true]]
        for (category, root) in CleanupScope.uninstallRoots() {
            guard !cancellation.isCancelled, Date() < deadline,
                  let children = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []) else { continue }
            for child in children {
                if cancellation.isCancelled || Date() >= deadline { break }
                guard CleanupScope.isAllowed(path: child.path),
                      let values = try? child.resourceValues(forKeys: [.isSymbolicLinkKey]),
                      values.isSymbolicLink != true,
                      LeftoverMatcher.matches(bundleID: bundleID, name: name, candidate: child.lastPathComponent) else { continue }
                items.append(["path": child.path, "size": allocatedSize(at: child, cancellation: cancellation, deadline: deadline), "category": category])
            }
        }
        return items
    }

    private static func startupItems(cancellation: MaintenanceScanCancellation) -> [[String: Any]] {
        let homeAgents = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let systemAgents = URL(fileURLWithPath: "/Library/LaunchAgents", isDirectory: true)
        var items: [[String: Any]] = []
        for (root, readOnly) in [(homeAgents, false), (systemAgents, true)] {
            guard !cancellation.isCancelled,
                  let children = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey], options: []) else { continue }
            for file in children where file.pathExtension.lowercased() == "plist" {
                if cancellation.isCancelled { break }
                guard let data = try? Data(contentsOf: file),
                      let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { continue }
                let label = plist["Label"] as? String ?? file.deletingPathExtension().lastPathComponent
                let status = SMAppService.agent(plistName: file.lastPathComponent).status
                items.append([
                    "path": file.path,
                    "size": Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0),
                    "label": label,
                    "status": serviceStatus(status),
                    "readOnly": readOnly
                ])
            }
        }
        return items.sorted { ($0["label"] as? String ?? "") < ($1["label"] as? String ?? "") }
    }

    private static func duplicates(rootPath: String, cancellation: MaintenanceScanCancellation, deadline: Date) -> (items: [[String: Any]], limitReached: Bool) {
        guard CleanupScope.isAllowed(path: rootPath) else { return ([], false) }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
        guard let values = try? root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true else { return ([], false) }
        var files: [DuplicateFile] = []
        var limitReached = false
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsPackageDescendants], errorHandler: { _, _ in true }) else { return ([], false) }
        for case let file as URL in enumerator {
            if cancellation.isCancelled || Date() >= deadline { break }
            if files.count >= 50_000 { limitReached = true; break }
            guard CleanupScope.isAllowed(path: file.path),
                  let metadata = try? file.resourceValues(forKeys: keys),
                  metadata.isRegularFile == true, metadata.isSymbolicLink != true,
                  let fileSize = metadata.fileSize, fileSize >= 0 else { continue }
            files.append(DuplicateFile(url: file, size: Int64(fileSize), modified: metadata.contentModificationDate ?? .distantPast))
        }

        var bySize: [Int64: [DuplicateFile]] = [:]
        for file in files { bySize[file.size, default: []].append(file) }
        var results: [[String: Any]] = []
        for (size, sameSize) in bySize where sameSize.count > 1 {
            if cancellation.isCancelled || Date() >= deadline { break }
            var byPrefixHash: [String: [DuplicateFile]] = [:]
            for file in sameSize {
                if cancellation.isCancelled || Date() >= deadline { break }
                if let hash = hashPrefix(file.url) { byPrefixHash[hash, default: []].append(file) }
            }
            for (prefixHash, prefixMatches) in byPrefixHash where prefixMatches.count > 1 {
                if cancellation.isCancelled || Date() >= deadline { break }
                var byFullHash: [String: [DuplicateFile]] = [:]
                for file in prefixMatches {
                    if cancellation.isCancelled || Date() >= deadline { break }
                    if let hash = hashFile(file.url, cancellation: cancellation, deadline: deadline) {
                        byFullHash[hash, default: []].append(file)
                    }
                }
                for (fullHash, matches) in byFullHash where matches.count > 1 {
                    let group = "\(size)-\(prefixHash)-\(fullHash)"
                    for file in matches.sorted(by: { $0.modified > $1.modified }) {
                        results.append(["path": file.url.path, "size": file.size, "modified": file.modified.timeIntervalSince1970, "group": group])
                    }
                }
            }
        }
        let sortedResults = results.sorted {
            let leftGroup = $0["group"] as? String ?? ""
            let rightGroup = $1["group"] as? String ?? ""
            if leftGroup != rightGroup { return leftGroup < rightGroup }
            return ($0["modified"] as? Double ?? 0) > ($1["modified"] as? Double ?? 0)
        }
        return (sortedResults, limitReached)
    }

    private static func memorySnapshot(cancellation: MaintenanceScanCancellation) -> [[String: Any]] {
        guard !cancellation.isCancelled else { return [] }
        let initialCount = max(64, Int(proc_listallpids(nil, 0)) + 16)
        var pids = [pid_t](repeating: 0, count: initialCount)
        let count = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count * MemoryLayout<pid_t>.stride))
        }
        guard count > 0 else { return [] }
        var records: [[String: Any]] = []
        var seen: Set<Int32> = []
        for pid in pids.prefix(Int(count)) where pid > 0 && pid != getpid() {
            if cancellation.isCancelled { break }
            var usage = rusage_info_v4()
            let rusageStatus = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard rusageStatus == 0 else { continue }
            var nameBuffer = [CChar](repeating: 0, count: 256)
            let nameLength = nameBuffer.withUnsafeMutableBufferPointer { proc_name(pid, $0.baseAddress, UInt32($0.count)) }
            let name = nameLength > 0 ? nameBuffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) } : "Process \(pid)"
            let application = NSRunningApplication(processIdentifier: pid)
            let isNotch = application?.bundleIdentifier == "sidco.notch" || application?.bundleIdentifier == "sidco.notch.SystemHelper"
            records.append(["pid": Int(pid), "name": name, "memory": Int64(usage.ri_phys_footprint), "canQuit": application != nil && !isNotch])
            if application != nil && !isNotch { seen.insert(pid) }
        }
        let top = records.sorted { ($0["memory"] as? Int64 ?? 0) > ($1["memory"] as? Int64 ?? 0) }.prefix(8)
        processLock.lock()
        recentMemoryPIDs = Set(top.compactMap { ($0["pid"] as? Int).map { Int32($0) } }.filter { seen.contains($0) })
        recentMemoryDate = Date()
        processLock.unlock()
        return Array(top)
    }

    private static func quit(pid: Int32) -> HelperArgs {
        processLock.lock()
        let permitted = recentMemoryPIDs.contains(pid) && Date().timeIntervalSince(recentMemoryDate) <= 10
        processLock.unlock()
        guard permitted, pid > 0, pid != getpid(),
              let app = NSRunningApplication(processIdentifier: pid),
              app.bundleIdentifier != "sidco.notch", app.bundleIdentifier != "sidco.notch.SystemHelper" else {
            return ["ok": false, "error": "That process is no longer available to quit."]
        }
        return ["ok": app.terminate()]
    }

    private static func trash(paths: [String]) -> HelperArgs {
        guard !paths.isEmpty, paths.count <= 50_000 else { return ["freed": 0, "moved": 0, "errors": ["No valid items were selected."]] }
        var movedBytes: Int64 = 0
        var moved = 0
        var errors: [String] = []
        var seen: Set<String> = []
        for rawPath in paths {
            guard seen.insert(rawPath).inserted,
                  CleanupScope.isAllowed(path: rawPath),
                  !CleanupScope.isProtectedRoot(rawPath),
                  let url = CleanupScope.resolvedURL(rawPath),
                  FileManager.default.fileExists(atPath: url.path) else {
                errors.append("Skipped an unsafe or missing path.")
                continue
            }
            if let app = validatedApplication(at: url), let info = appBundleInfo(at: app), isProtectedApplication(info) {
                errors.append("Refused to move a system app or Notch.")
                continue
            }
            let bytes = allocatedSize(at: url, cancellation: MaintenanceScanCancellation(), deadline: Date().addingTimeInterval(20))
            do {
                var resultingURL: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
                moved += 1
                movedBytes += bytes
            } catch {
                errors.append("Could not move \(url.lastPathComponent) to Trash.")
            }
        }
        return ["freed": movedBytes, "moved": moved, "errors": errors]
    }

    private static func allocatedSize(at url: URL, cancellation: MaintenanceScanCancellation, deadline: Date) -> Int64 {
        let manager = FileManager.default
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]), values.isSymbolicLink != true else { return 0 }
        if values.isRegularFile == true {
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
        }
        guard values.isDirectory == true,
              let enumerator = manager.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey], options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        let packageRoot = url.pathExtension.lowercased() == "app" && url.deletingLastPathComponent().path == "/Applications"
        for case let child as URL in enumerator {
            if cancellation.isCancelled || Date() >= deadline { break }
            let canonicalChild = child.resolvingSymlinksInPath().standardizedFileURL.path
            let insideApp = packageRoot && canonicalChild.hasPrefix(url.path + "/")
            guard CleanupScope.isAllowed(path: child.path) || insideApp,
                  let childValues = try? child.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]),
                  childValues.isRegularFile == true, childValues.isSymbolicLink != true else { continue }
            total += Int64(childValues.totalFileAllocatedSize ?? childValues.fileAllocatedSize ?? childValues.fileSize ?? 0)
        }
        return max(0, total)
    }

    private static func hashPrefix(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 * 1024) else { return nil }
        var digest = SHA256()
        digest.update(data: data)
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func hashFile(_ url: URL, cancellation: MaintenanceScanCancellation, deadline: Date) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var digest = SHA256()
        while !cancellation.isCancelled, Date() < deadline {
            guard let chunk = try? handle.read(upToCount: 1024 * 1024), !chunk.isEmpty else { break }
            digest.update(data: chunk)
        }
        guard !cancellation.isCancelled, Date() < deadline else { return nil }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func validatedApplication(at url: URL) -> URL? {
        let candidate = url.standardizedFileURL
        guard candidate.pathExtension.lowercased() == "app",
              CleanupScope.isAllowed(path: candidate.path),
              candidate.deletingLastPathComponent().path == "/Applications" else { return nil }
        guard let info = appBundleInfo(at: candidate), !isProtectedApplication(info) else { return nil }
        return CleanupScope.resolvedURL(candidate.path)
    }

    private static func appBundleInfo(at url: URL) -> (bundleID: String?, name: String)? {
        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let info = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { return nil }
        let bundleID = info["CFBundleIdentifier"] as? String
        let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? url.deletingPathExtension().lastPathComponent
        return (bundleID, name)
    }

    private static func isProtectedApplication(_ info: (bundleID: String?, name: String)) -> Bool {
        let bundleID = info.bundleID?.lowercased() ?? ""
        let name = info.name.lowercased()
        return bundleID == "sidco.notch" || bundleID == "sidco.notch.systemhelper" || bundleID.hasPrefix("com.apple.") || name == "notch"
    }

    private static func serviceStatus(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: return "Enabled"
        case .requiresApproval: return "Needs approval"
        case .notRegistered: return "Not registered"
        case .notFound: return "Not found"
        @unknown default: return "Unknown"
        }
    }
}

private final class MaintenanceScanCancellation {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

private struct DuplicateFile {
    let url: URL
    let size: Int64
    let modified: Date
}

/// Restricts destructive paths to known user folders. Optional inputs keep its boundary
/// rules deterministic to test without touching a user's real files.
enum CleanupScope {
    static func allowedRoots(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        let library = home.appendingPathComponent("Library", isDirectory: true)
        let roots = [
            library.appendingPathComponent("Caches", isDirectory: true),
            library.appendingPathComponent("Logs", isDirectory: true),
            library.appendingPathComponent("Developer/Xcode/DerivedData", isDirectory: true),
            library.appendingPathComponent("Developer/CoreSimulator/Caches", isDirectory: true),
            library.appendingPathComponent("Application Support", isDirectory: true),
            library.appendingPathComponent("Preferences", isDirectory: true),
            library.appendingPathComponent("Containers", isDirectory: true),
            library.appendingPathComponent("Group Containers", isDirectory: true),
            library.appendingPathComponent("Saved Application State", isDirectory: true),
            library.appendingPathComponent("HTTPStorages", isDirectory: true),
            library.appendingPathComponent("WebKit", isDirectory: true),
            library.appendingPathComponent("LaunchAgents", isDirectory: true),
            home.appendingPathComponent("Desktop", isDirectory: true),
            home.appendingPathComponent("Documents", isDirectory: true),
            home.appendingPathComponent("Downloads", isDirectory: true),
            home.appendingPathComponent("Movies", isDirectory: true),
            home.appendingPathComponent("Music", isDirectory: true),
            home.appendingPathComponent("Pictures", isDirectory: true),
            home.appendingPathComponent("Public", isDirectory: true)
        ].map { $0.standardizedFileURL.path }
        return roots + ["/Applications"]
    }

    static func cleanupRoots(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [(String, URL)] {
        let library = home.appendingPathComponent("Library", isDirectory: true)
        return [
            ("Caches", library.appendingPathComponent("Caches", isDirectory: true)),
            ("Logs", library.appendingPathComponent("Logs", isDirectory: true)),
            ("Xcode DerivedData", library.appendingPathComponent("Developer/Xcode/DerivedData", isDirectory: true)),
            ("Simulator caches", library.appendingPathComponent("Developer/CoreSimulator/Caches", isDirectory: true))
        ]
    }

    static func uninstallRoots(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [(String, URL)] {
        let library = home.appendingPathComponent("Library", isDirectory: true)
        return [
            ("Application Support", library.appendingPathComponent("Application Support", isDirectory: true)),
            ("Caches", library.appendingPathComponent("Caches", isDirectory: true)),
            ("Preferences", library.appendingPathComponent("Preferences", isDirectory: true)),
            ("Containers", library.appendingPathComponent("Containers", isDirectory: true)),
            ("Group Containers", library.appendingPathComponent("Group Containers", isDirectory: true)),
            ("Saved Application State", library.appendingPathComponent("Saved Application State", isDirectory: true)),
            ("Logs", library.appendingPathComponent("Logs", isDirectory: true)),
            ("HTTPStorages", library.appendingPathComponent("HTTPStorages", isDirectory: true)),
            ("WebKit", library.appendingPathComponent("WebKit", isDirectory: true))
        ]
    }

    static func isAllowed(path: String, home: String = NSHomeDirectory(), roots: [String]? = nil, resolvedPath: String? = nil) -> Bool {
        guard path.hasPrefix("/"), !path.split(separator: "/", omittingEmptySubsequences: false).contains("..") else { return false }
        let lexical = URL(fileURLWithPath: path).standardizedFileURL.path
        let homePath = URL(fileURLWithPath: home).standardizedFileURL.path
        guard lexical != "/", lexical != homePath else { return false }
        let rootPaths = (roots ?? allowedRoots(home: URL(fileURLWithPath: home))).map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        guard let matchedRoot = rootPaths.first(where: { contains(lexical, root: $0) }) else { return false }
        let resolved = resolvedPath ?? URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        let canonical = URL(fileURLWithPath: resolved).standardizedFileURL.path
        guard contains(canonical, root: matchedRoot), canonical != homePath else { return false }
        if matchedRoot == "/Applications" {
            return URL(fileURLWithPath: canonical).pathExtension.lowercased() == "app"
                && URL(fileURLWithPath: canonical).deletingLastPathComponent().path == "/Applications"
        }
        return true
    }

    static func isProtectedRoot(_ path: String) -> Bool {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        let roots = allowedRoots().filter { $0 != "/Applications" }
        return roots.contains { URL(fileURLWithPath: $0).standardizedFileURL.path == resolved } || resolved == "/Applications"
    }

    static func resolvedURL(_ path: String) -> URL? {
        guard isAllowed(path: path) else { return nil }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
    }

    private static func contains(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}

enum LeftoverMatcher {
    static func matches(bundleID: String, name: String, candidate: String) -> Bool {
        let nameKey = compact(name)
        guard !candidate.isEmpty else { return false }
        if !bundleID.isEmpty {
            let text = candidate.lowercased() as NSString
            let identifier = bundleID.lowercased()
            let range = text.range(of: identifier)
            if range.location != NSNotFound {
                let beforeIsBoundary = range.location == 0 || !isASCIIAlphaNumeric(text.character(at: range.location - 1))
                let end = NSMaxRange(range)
                let afterIsBoundary = end == text.length || !isASCIIAlphaNumeric(text.character(at: end))
                if beforeIsBoundary && afterIsBoundary { return true }
            }
        }
        return !nameKey.isEmpty && compact(candidate) == nameKey
    }

    private static func isASCIIAlphaNumeric(_ value: unichar) -> Bool {
        (value >= 48 && value <= 57) || (value >= 65 && value <= 90) || (value >= 97 && value <= 122)
    }

    private static func compact(_ value: String) -> String {
        value.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }
}
