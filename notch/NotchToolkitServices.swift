// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint; Notch adaptations (C) 2026 Notch contributors.
// Adapted from vorssaint/vorssaint-utils, commit 3c10e1bd30101499135fa5d7591f2d3c5af4cd17:
// Sources/Vorssaint/Core/URLCleaning.swift (tracking tables and host matching),
// Sources/Vorssaint/Services/KeepAwakeManager.swift (idle-sleep assertion and end timer),
// Sources/Vorssaint/Services/QuickTools/ScratchpadService.swift (autosave on text edits).
// Notch retains raw query bytes, preserves signed URLs, and uses a single local notes preference.

import AppKit
import Combine
import Foundation
import IOKit.pwr_mgt

protocol NotchSleepAssertionBackend: AnyObject {
    func acquire(_ kind: NotchSleepAssertionKind) throws -> IOPMAssertionID
    func release(_ assertion: IOPMAssertionID)
}

enum NotchSleepAssertionKind: Hashable {
    case system
    case display
}

enum NotchKeepAwakeMode: String, CaseIterable, Identifiable {
    case mac
    case macAndDisplay

    var id: String { rawValue }
    var title: String {
        switch self {
        case .mac: "Keep Mac awake"
        case .macAndDisplay: "Keep Mac and display awake"
        }
    }
    var detail: String {
        switch self {
        case .mac: "The display may sleep."
        case .macAndDisplay: "Keeps the display from idle sleep too."
        }
    }
    fileprivate var assertions: [NotchSleepAssertionKind] {
        switch self {
        case .mac: [.system]
        case .macAndDisplay: [.system, .display]
        }
    }
}

private final class SystemSleepAssertionBackend: NotchSleepAssertionBackend {
    func acquire(_ kind: NotchSleepAssertionKind) throws -> IOPMAssertionID {
        var id = IOPMAssertionID(0)
        let assertionType: CFString
        let reason: CFString
        switch kind {
        case .system:
            assertionType = "PreventUserIdleSystemSleep" as CFString
            reason = "Notch: keep the Mac awake" as CFString
        case .display:
            assertionType = "PreventUserIdleDisplaySleep" as CFString
            reason = "Notch: keep the display awake" as CFString
        }
        let status = IOPMAssertionCreateWithName(
            assertionType,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason, &id)
        guard status == kIOReturnSuccess else {
            throw NSError(domain: "Notch.KeepAwake", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "macOS could not create the \(kind == .system ? "Mac sleep" : "display sleep") assertion (\(status))."])
        }
        return id
    }

    func release(_ assertion: IOPMAssertionID) {
        IOPMAssertionRelease(assertion)
    }
}

@MainActor
final class NotchToolkitStore: ObservableObject {
    static let shared = NotchToolkitStore()

    @Published var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: Self.enabledKey)
            if !enabled { stopKeepingAwake() }
        }
    }
    @Published var scratchpadText: String {
        didSet {
            guard scratchpadWritable else {
                lastError = "Saved notes could not be read. Their stored content has been preserved."
                return
            }
            if oldValue != scratchpadText { defaults.set(scratchpadText, forKey: Self.notesKey) }
        }
    }
    @Published private(set) var isKeepingAwake = false
    @Published private(set) var awakeUntil: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var keepAwakeError: String?
    @Published private(set) var keepAwakeMode: NotchKeepAwakeMode = .mac
    @Published private(set) var lastCleanedURL: String?
    var canSaveScratchpad: Bool { scratchpadWritable }

    private static let enabledKey = "notch.showToolkit"
    private static let notesKey = "toolkit.scratchpadText"
    private let defaults: UserDefaults
    private let pasteboard: NSPasteboard
    private let assertionBackend: NotchSleepAssertionBackend
    private let dateProvider: () -> Date
    private let disableTimers: Bool
    private let timerScheduler: (Date, @escaping () -> Void) -> Timer
    private let scratchpadWritable: Bool
    private var assertions: [NotchSleepAssertionKind: IOPMAssertionID] = [:]
    private var endTimer: Timer?
    private var terminationObserver: NSObjectProtocol?
    private var disableObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard, pasteboard: NSPasteboard = .general,
         assertionBackend: NotchSleepAssertionBackend? = nil,
         dateProvider: @escaping () -> Date = Date.init, disableTimers: Bool = false,
         timerScheduler: ((Date, @escaping () -> Void) -> Timer)? = nil) {
        self.defaults = defaults
        self.pasteboard = pasteboard
        self.assertionBackend = assertionBackend ?? SystemSleepAssertionBackend()
        self.dateProvider = dateProvider
        self.disableTimers = disableTimers
        self.timerScheduler = timerScheduler ?? { date, action in
            let timer = Timer(fire: date, interval: 0, repeats: false) { _ in action() }
            RunLoop.main.add(timer, forMode: .common)
            return timer
        }
        let storedNotes = defaults.object(forKey: Self.notesKey)
        scratchpadWritable = storedNotes == nil || storedNotes is String
        scratchpadText = storedNotes as? String ?? ""
        enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        if !scratchpadWritable {
            lastError = "Saved notes could not be read. Their stored content has been preserved."
        }
    }

    deinit {
        endTimer?.invalidate()
        assertions.values.forEach(assertionBackend.release)
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        if let disableObserver { NotificationCenter.default.removeObserver(disableObserver) }
    }

    /// Backwards-compatible timed keep-awake API. Nil stops the current session.
    func setKeepAwake(minutes: Int?) {
        guard let minutes else { stopKeepingAwake(); return }
        let previousKeepAwakeError = keepAwakeError
        startKeepingAwake(minutes: minutes, mode: .mac)
        if let keepAwakeError { lastError = keepAwakeError }
        else if let previousKeepAwakeError, lastError == previousKeepAwakeError { lastError = nil }
    }

    func startKeepingAwake(minutes: Int?, mode: NotchKeepAwakeMode = .mac) {
        applyKeepAwake(minutes: minutes, mode: mode, deadlineOverride: nil)
    }

    private func applyKeepAwake(minutes: Int?, mode: NotchKeepAwakeMode, deadlineOverride: Date?) {
        guard enabled else {
            reportKeepAwakeError("Enable Toolkit before keeping the Mac awake.")
            return
        }
        if let minutes, !(1...240).contains(minutes) {
            reportKeepAwakeError("Choose a duration from 1 to 240 minutes.")
            return
        }
        var acquired: [NotchSleepAssertionKind: IOPMAssertionID] = [:]
        do {
            for kind in mode.assertions where assertions[kind] == nil {
                acquired[kind] = try assertionBackend.acquire(kind)
            }
        } catch {
            acquired.values.forEach(assertionBackend.release)
            reportKeepAwakeError(error.localizedDescription)
            return
        }
        let retainedKinds = Set(mode.assertions)
        let obsolete = assertions.filter { !retainedKinds.contains($0.key) }
        assertions.merge(acquired) { _, new in new }
        obsolete.values.forEach(assertionBackend.release)
        for kind in obsolete.keys { assertions.removeValue(forKey: kind) }
        keepAwakeError = nil
        isKeepingAwake = true
        endTimer?.invalidate()
        endTimer = nil
        awakeUntil = deadlineOverride ?? minutes.map { dateProvider().addingTimeInterval(TimeInterval($0) * 60) }
        keepAwakeMode = mode
        if let deadline = awakeUntil, !disableTimers {
            endTimer = timerScheduler(deadline) { [weak self] in
                MainActor.assumeIsolated { self?.expireKeepAwakeIfNeeded() }
            }
        }
        if terminationObserver == nil {
            terminationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.stopKeepingAwake() }
            }
        }
        if disableObserver == nil {
            disableObserver = NotificationCenter.default.addObserver(
                forName: .notchToolkitDisabled, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.enabled = false }
            }
        }
    }

    func updateKeepAwakeMode(_ mode: NotchKeepAwakeMode) {
        guard isKeepingAwake else { keepAwakeMode = mode; return }
        applyKeepAwake(minutes: nil, mode: mode, deadlineOverride: awakeUntil)
    }

    func stopKeepingAwake() {
        endTimer?.invalidate()
        endTimer = nil
        assertions.values.forEach(assertionBackend.release)
        assertions.removeAll()
        isKeepingAwake = false
        awakeUntil = nil
        keepAwakeError = nil
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
            self.terminationObserver = nil
        }
        if let disableObserver {
            NotificationCenter.default.removeObserver(disableObserver)
            self.disableObserver = nil
        }
    }

    private func reportKeepAwakeError(_ message: String) {
        keepAwakeError = message
    }

    func expireKeepAwakeIfNeeded() {
        if let awakeUntil, dateProvider() >= awakeUntil { stopKeepingAwake() }
    }

    /// Manual only: never watches the clipboard or rewrites images, files, or concealed copies.
    func cleanClipboardURL() {
        guard enabled else { lastError = "Enable Toolkit before cleaning a link."; return }
        lastCleanedURL = nil
        let count = pasteboard.changeCount
        let allowed = Set([NSPasteboard.PasteboardType.string.rawValue, "public.url", "public.url-name",
                           "NSStringPboardType", "NSURLPboardType"])
        guard let items = pasteboard.pasteboardItems, items.count == 1,
              let types = pasteboard.types, !types.isEmpty,
              types.allSatisfy({ allowed.contains($0.rawValue) }) else {
            lastError = "Copy a plain web link first. Other clipboard content has been kept."
            return
        }
        guard let text = pasteboard.string(forType: .string) ?? pasteboard.string(forType: .URL),
              let cleaned = Self.cleanURL(text) else {
            lastError = "The clipboard does not contain a valid HTTP or HTTPS link."
            return
        }
        guard count == pasteboard.changeCount else {
            lastError = "The clipboard changed. Try cleaning the link again."
            return
        }
        lastError = nil
        lastCleanedURL = cleaned
        guard cleaned != text.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        let item = NSPasteboardItem()
        item.setString(cleaned, forType: .string)
        item.setString(cleaned, forType: .URL)
        pasteboard.clearContents()
        if !pasteboard.writeObjects([item]) {
            lastCleanedURL = nil
            lastError = "The cleaned link could not be copied."
        }
    }

    nonisolated static func cleanURL(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: { $0.isWhitespace || $0.isNewline }),
              let components = URLComponents(string: trimmed, encodingInvalidCharacters: false),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty, components.url != nil else { return nil }
        guard let queryStart = trimmed.firstIndex(of: "?"),
              trimmed.firstIndex(of: "#").map({ queryStart < $0 }) ?? true else { return trimmed }
        let queryEnd = trimmed[queryStart...].firstIndex(of: "#") ?? trimmed.endIndex
        let rawParts = trimmed[trimmed.index(after: queryStart)..<queryEnd]
            .split(separator: "&", omittingEmptySubsequences: false)
        let names = rawParts.map { part in
            String(part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)[0])
                .removingPercentEncoding?.lowercased() ?? ""
        }
        // Even unrelated query edits can invalidate signatures. Leave the complete original URL intact.
        let signatureNames: Set<String> = ["sig", "signature", "oauth_signature", "policy", "key-pair-id", "awsaccesskeyid"]
        if names.contains(where: { signatureNames.contains($0) || $0.hasPrefix("x-amz-") || $0.hasPrefix("x-goog-") }) {
            return trimmed
        }
        let normalizedHost = host.lowercased()
        var removable = trackedParameters
        for (site, parameters) in hostParameters where normalizedHost == site || normalizedHost.hasSuffix("." + site) {
            removable.formUnion(parameters)
        }
        let kept = zip(rawParts, names).filter { !removable.contains($0.1) && !$0.1.hasPrefix("utm_") }.map { String($0.0) }
        guard kept.count != rawParts.count else { return trimmed }
        let query = kept.isEmpty ? "" : "?" + kept.joined(separator: "&")
        return String(trimmed[..<queryStart]) + query + String(trimmed[queryEnd...])
    }

    nonisolated private static let trackedParameters: Set<String> = [
        "fbclid", "gclid", "dclid", "gbraid", "wbraid", "msclkid", "yclid", "mc_cid", "mc_eid",
        "igshid", "twclid", "ttclid", "li_fat_id", "mkt_tok", "_hsenc", "_hsmi", "__twitter_impression",
        "fb_action_ids", "fb_action_types", "fb_source", "mibextid"
    ]
    nonisolated private static let hostParameters: [String: Set<String>] = [
        "youtube.com": ["si", "pp", "feature", "kw"], "youtu.be": ["si", "pp", "feature", "kw"],
        "twitter.com": ["s", "t", "cn", "src", "refsrc", "ref_src", "ref_url"],
        "x.com": ["s", "t", "cn", "src", "refsrc", "ref_src", "ref_url"],
        "instagram.com": ["igsh"], "spotify.com": ["si"],
        "reddit.com": ["correlation_id", "ref_campaign", "ref_source", "rdt", "share_id", "_branch_match_id", "$deep_link", "$3p", "$original_url"],
        "tiktok.com": ["u_code", "preview_pb", "_d", "_t", "_r", "timestamp", "user_id", "share_app_name", "share_iid"],
        "bilibili.com": ["spm_id_from", "from_spmid", "from_source", "share_source", "share_from", "share_medium", "share_plat", "share_tag", "share_session_id", "msource", "refer_from", "seid", "unique_k", "vd_source", "plat_id", "buvid", "bbid", "up_id", "is_story_h5", "timestamp", "ts", "visit_id", "session_id", "broadcast_type", "is_room_feed"],
        "xiaohongshu.com": ["xhsshare", "author_share", "xsec_source", "share_from_user_hidden", "shareredid", "share_id", "exsource", "app_version", "app_platform", "apptime", "appuid"]
    ]
}
