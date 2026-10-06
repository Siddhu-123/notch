import AppKit
import Foundation
import IOKit.pwr_mgt
import Testing
@testable import notch

private final class FakeNotchSleepBackend: NotchSleepAssertionBackend {
    var acquired: [IOPMAssertionID] = []
    var acquiredKinds: [NotchSleepAssertionKind] = []
    var released: [IOPMAssertionID] = []
    var shouldFail = false
    var failingKind: NotchSleepAssertionKind?
    func acquire(_ kind: NotchSleepAssertionKind) throws -> IOPMAssertionID {
        if shouldFail || failingKind == kind { throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Test acquisition failed"]) }
        let id = IOPMAssertionID(acquired.count + 1)
        acquired.append(id)
        acquiredKinds.append(kind)
        return id
    }
    func release(_ assertion: IOPMAssertionID) { released.append(assertion) }
}

@MainActor
private final class ToolkitFixture {
    let suite = "Notch.ToolkitTests." + UUID().uuidString
    let defaults: UserDefaults
    let pasteboard = NSPasteboard(name: .init("Notch.ToolkitTests." + UUID().uuidString))
    let backend = FakeNotchSleepBackend()
    init() { defaults = UserDefaults(suiteName: suite)! }
    func makeStore(disableTimers: Bool = true,
                   dateProvider: @escaping () -> Date = Date.init,
                   timerScheduler: ((Date, @escaping () -> Void) -> Timer)? = nil) -> NotchToolkitStore {
        NotchToolkitStore(defaults: defaults, pasteboard: pasteboard, assertionBackend: backend,
                          dateProvider: dateProvider, disableTimers: disableTimers, timerScheduler: timerScheduler)
    }
    func cleanup() {
        defaults.removePersistentDomain(forName: suite)
        pasteboard.releaseGlobally()
    }
}

struct ToolkitServicesTests {
    @Test func cleanerKeepsNecessaryQueryBytesAndFragment() {
        let input = "https://example.com/a%2fb?utm_source=mail&q=a+b&q=a%20b&redirect=%2fnext%3Fx%3D1&flag#anchor"
        #expect(NotchToolkitStore.cleanURL(input) == "https://example.com/a%2fb?q=a+b&q=a%20b&redirect=%2fnext%3Fx%3D1&flag#anchor")
        #expect(NotchToolkitStore.cleanURL("https://example.com/?UTM_new=value&fbclid=1#next") == "https://example.com/#next")
        #expect(NotchToolkitStore.cleanURL("https://example.com/?%75tm_source=mail&x=%2520") == "https://example.com/?x=%2520")
        #expect(NotchToolkitStore.cleanURL("https://example.com/#?utm_source=fragment") == "https://example.com/#?utm_source=fragment")
    }

    @Test func cleanerUsesHostRulesWithoutBreakingPlaybackPositions() {
        #expect(NotchToolkitStore.cleanURL("https://www.youtube.com/watch?v=video&t=42&si=share&feature=shared") == "https://www.youtube.com/watch?v=video&t=42")
        #expect(NotchToolkitStore.cleanURL("https://x.com/person/status/1?t=share&s=20") == "https://x.com/person/status/1")
        #expect(NotchToolkitStore.cleanURL("https://youtube.com.evil.test/watch?t=42&si=needed&feature=needed") == "https://youtube.com.evil.test/watch?t=42&si=needed&feature=needed")
        #expect(NotchToolkitStore.cleanURL("https://example.com/?si=necessary&t=42") == "https://example.com/?si=necessary&t=42")
    }

    @Test func cleanerLeavesSignedLinksByteForByte() {
        for parameter in ["X-Amz-Signature=ABC%2fdef", "X-Goog-Credential=key", "sig=a+b", "Signature=abc", "oauth_signature=abc", "Policy=base64", "Key-Pair-Id=id", "AWSAccessKeyId=key"] {
            let url = "https://example.com/private?utm_source=mail&\(parameter)&name=a%20b#end"
            #expect(NotchToolkitStore.cleanURL(url) == url)
        }
    }

    @Test func cleanerRejectsNonWebInput() {
        for text in ["hello", "", "file:///tmp/test", "javascript:alert(1)", "mailto:a@example.com", "https://", "https://example.com/has space", "https://example.com/%GG", "https://example.com/\nmore"] {
            #expect(NotchToolkitStore.cleanURL(text) == nil)
        }
        #expect(NotchToolkitStore.cleanURL(" \nhttps://example.com/path\t ") == "https://example.com/path")
    }

    @MainActor @Test func notesPersistImmediatelyAndDisableRetainsThem() {
        let fixture = ToolkitFixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        #expect(store.enabled)
        #expect(fixture.backend.acquired.isEmpty)
        #expect(store.awakeUntil == nil)
        store.scratchpadText = "Meeting notes\nరామ\nKeep this whitespace  "
        store.enabled = false
        let restored = fixture.makeStore()
        #expect(restored.scratchpadText == store.scratchpadText)
        #expect(!restored.enabled)
        #expect(!restored.isKeepingAwake)
        #expect(fixture.backend.acquired.isEmpty)
    }

    @MainActor @Test func unreadableStoredNotesArePreserved() {
        let fixture = ToolkitFixture()
        defer { fixture.cleanup() }
        let original = Data([0xff, 0x00])
        fixture.defaults.set(original, forKey: "toolkit.scratchpadText")
        let store = fixture.makeStore()
        #expect(store.lastError != nil)
        store.scratchpadText = "new text"
        #expect(fixture.defaults.data(forKey: "toolkit.scratchpadText") == original)
    }

    @MainActor @Test func assertionReplacementDisableAndDeinitBalanceOwnership() {
        let fixture = ToolkitFixture()
        defer { fixture.cleanup() }
        let now = Date(timeIntervalSince1970: 1000)
        var store: NotchToolkitStore? = fixture.makeStore(dateProvider: { now })
        store?.setKeepAwake(minutes: 30)
        #expect(store?.isKeepingAwake == true)
        #expect(store?.awakeUntil == now.addingTimeInterval(1800))
        store?.setKeepAwake(minutes: 60)
        #expect(store?.awakeUntil == now.addingTimeInterval(3600))
        #expect(fixture.backend.acquired == [1])
        #expect(fixture.backend.released.isEmpty)
        store?.enabled = false
        #expect(store?.isKeepingAwake == false)
        #expect(store?.awakeUntil == nil)
        #expect(fixture.backend.released == [1])
        store?.stopKeepingAwake()
        #expect(fixture.backend.released == [1])
        store?.setKeepAwake(minutes: 30)
        #expect(fixture.backend.acquired == [1])
        store?.enabled = true
        store?.setKeepAwake(minutes: 30)
        store = nil
        #expect(fixture.backend.acquired == [1, 2])
        #expect(fixture.backend.released.sorted() == [1, 2])
    }

    @MainActor @Test func displayModeAcquiresAndReleasesAssertionsTransactionally() {
        let fixture = ToolkitFixture()
        defer { fixture.cleanup() }
        let now = Date(timeIntervalSince1970: 1000)
        let store = fixture.makeStore(dateProvider: { now })
        store.startKeepingAwake(minutes: 30, mode: .mac)
        let originalDeadline = store.awakeUntil

        fixture.backend.failingKind = .display
        store.updateKeepAwakeMode(.macAndDisplay)
        #expect(store.isKeepingAwake)
        #expect(store.keepAwakeMode == .mac)
        #expect(store.awakeUntil == originalDeadline)
        #expect(fixture.backend.acquiredKinds == [.system])
        #expect(fixture.backend.released.isEmpty)
        #expect(store.keepAwakeError == "Test acquisition failed")

        fixture.backend.failingKind = nil
        store.updateKeepAwakeMode(.macAndDisplay)
        #expect(store.keepAwakeMode == .macAndDisplay)
        #expect(store.awakeUntil == originalDeadline)
        #expect(fixture.backend.acquiredKinds == [.system, .display])
        #expect(fixture.backend.released.isEmpty)

        store.updateKeepAwakeMode(.mac)
        #expect(fixture.backend.released == [2])
        store.stopKeepingAwake()
        #expect(fixture.backend.released == [2, 1])
        store.stopKeepingAwake()
        #expect(fixture.backend.released == [2, 1])
    }

    @MainActor @Test func partialDisplayAcquisitionRollsBackAndIndefiniteSwitchClearsTimer() {
        let fixture = ToolkitFixture()
        defer { fixture.cleanup() }
        var now = Date(timeIntervalSince1970: 1000)
        var timers: [Timer] = []
        let store = fixture.makeStore(disableTimers: false, dateProvider: { now }, timerScheduler: { deadline, action in
            let timer = Timer(fire: deadline, interval: 100_000, repeats: false) { _ in action() }
            timers.append(timer)
            return timer
        })
        fixture.backend.failingKind = .display
        store.startKeepingAwake(minutes: 30, mode: .macAndDisplay)
        #expect(!store.isKeepingAwake)
        #expect(store.awakeUntil == nil)
        #expect(fixture.backend.acquiredKinds == [.system])
        #expect(fixture.backend.released == [1])

        fixture.backend.failingKind = nil
        store.startKeepingAwake(minutes: 30, mode: .mac)
        store.startKeepingAwake(minutes: nil, mode: .mac)
        #expect(timers[0].isValid == false)
        #expect(store.isKeepingAwake)
        #expect(store.awakeUntil == nil)
        #expect(fixture.backend.acquiredKinds == [.system, .system])
        #expect(fixture.backend.released == [1])
        store.startKeepingAwake(minutes: 15, mode: .mac)
        #expect(store.awakeUntil == now.addingTimeInterval(900))
        #expect(fixture.backend.acquired.count == 2)
        store.stopKeepingAwake()
        #expect(fixture.backend.released.sorted() == [1, 2])
    }

    @MainActor @Test func displayAssertionsReleaseOnTimeoutTerminationDisableAndDeinit() {
        let fixture = ToolkitFixture()
        defer { fixture.cleanup() }
        var now = Date(timeIntervalSince1970: 1000)
        var store: NotchToolkitStore? = fixture.makeStore(disableTimers: false, dateProvider: { now }, timerScheduler: { deadline, action in
            Timer(fire: deadline, interval: 100_000, repeats: false) { _ in action() }
        })
        store?.startKeepingAwake(minutes: 15, mode: .macAndDisplay)
        now = now.addingTimeInterval(901)
        store?.expireKeepAwakeIfNeeded()
        #expect(fixture.backend.released.sorted() == [1, 2])

        store?.startKeepingAwake(minutes: 15, mode: .macAndDisplay)
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        #expect(fixture.backend.released.sorted() == [1, 2, 3, 4])

        store?.enabled = true
        store?.startKeepingAwake(minutes: nil, mode: .macAndDisplay)
        store?.enabled = false
        #expect(fixture.backend.released.sorted() == [1, 2, 3, 4, 5, 6])

        store?.enabled = true
        store?.startKeepingAwake(minutes: nil, mode: .macAndDisplay)
        store = nil
        #expect(fixture.backend.released.sorted() == [1, 2, 3, 4, 5, 6, 7, 8])
    }

    @MainActor @Test func acquisitionFailureAndInvalidDurationsDoNotClaimAwake() {
        let fixture = ToolkitFixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        fixture.backend.shouldFail = true
        store.setKeepAwake(minutes: 30)
        #expect(!store.isKeepingAwake)
        #expect(store.awakeUntil == nil)
        #expect(store.lastError == "Test acquisition failed")
        #expect(fixture.backend.released.isEmpty)
        fixture.backend.shouldFail = false
        for minutes in [0, -1, 241, Int.max] { store.setKeepAwake(minutes: minutes) }
        #expect(fixture.backend.acquired.isEmpty)
        store.setKeepAwake(minutes: 30)
        let deadline = store.awakeUntil
        store.setKeepAwake(minutes: Int.max)
        #expect(store.awakeUntil == deadline)
        store.setKeepAwake(minutes: nil)
        #expect(fixture.backend.released == [1])
    }

    @MainActor @Test func timerReplacesDeadlineAndExpiresOnce() {
        let fixture = ToolkitFixture()
        defer { fixture.cleanup() }
        var now = Date(timeIntervalSince1970: 1000)
        var timers: [Timer] = []
        var dates: [Date] = []
        let store = fixture.makeStore(disableTimers: false, dateProvider: { now }, timerScheduler: { deadline, action in
            dates.append(deadline)
            let timer = Timer(timeInterval: 100_000, repeats: false) { _ in action() }
            timers.append(timer)
            return timer
        })
        store.setKeepAwake(minutes: 30)
        store.setKeepAwake(minutes: 60)
        #expect(!timers[0].isValid)
        #expect(dates == [now.addingTimeInterval(1800), now.addingTimeInterval(3600)])
        now = now.addingTimeInterval(3601)
        timers[1].fire()
        #expect(!store.isKeepingAwake)
        #expect(!timers[1].isValid)
        #expect(fixture.backend.released == [1])
        store.expireKeepAwakeIfNeeded()
        #expect(fixture.backend.released == [1])
    }

    @MainActor @Test func terminationAndFeatureDisableStopAwake() {
        let fixture = ToolkitFixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        store.setKeepAwake(minutes: 30)
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        #expect(!store.isKeepingAwake)
        #expect(fixture.backend.released == [1])
        store.setKeepAwake(minutes: 30)
        NotificationCenter.default.post(name: .notchToolkitDisabled, object: nil)
        #expect(!store.enabled)
        #expect(!store.isKeepingAwake)
        #expect(fixture.backend.released == [1, 2])
    }

    @MainActor @Test func explicitClipboardCleanPreservesRichAndConcealedCopies() {
        let fixture = ToolkitFixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        let original = "https://example.com/path?utm_source=mail&next=a%2Fb"
        fixture.pasteboard.clearContents()
        fixture.pasteboard.setString(original, forType: .string)
        store.cleanClipboardURL()
        #expect(store.lastCleanedURL == "https://example.com/path?next=a%2Fb")
        #expect(fixture.pasteboard.string(forType: .string) == store.lastCleanedURL)
        let cleanedCount = fixture.pasteboard.changeCount
        store.cleanClipboardURL()
        #expect(fixture.pasteboard.changeCount == cleanedCount)
        for type in [NSPasteboard.PasteboardType.png, .fileURL, .rtf, .init("org.nspasteboard.ConcealedType")] {
            fixture.pasteboard.clearContents()
            fixture.pasteboard.setString(original, forType: .string)
            fixture.pasteboard.setData(Data([1, 2, 3]), forType: type)
            let count = fixture.pasteboard.changeCount
            store.cleanClipboardURL()
            #expect(fixture.pasteboard.changeCount == count)
            #expect(fixture.pasteboard.string(forType: .string) == original)
            #expect(store.lastCleanedURL == nil)
        }
    }
}
