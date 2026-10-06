import Foundation
import Testing
@testable import notch

struct IslandActivitiesTests {
    @Test(arguments: ["file.download", "file.crdownload", "file.part", "file.partial", "file.opdownload", "FILE.CRDOWNLOAD"])
    func identifiesInProgressDownloadSuffixes(name: String) {
        #expect(DownloadClassifier.isInProgress(URL(fileURLWithPath: "/tmp/\(name)")))
    }

    @Test(arguments: ["file.zip", "file.part.old", "partial.txt", "report.downloaded", "plain"])
    func rejectsCompletedOrUnrelatedFileNames(name: String) {
        #expect(!DownloadClassifier.isInProgress(URL(fileURLWithPath: "/tmp/\(name)")))
    }

    @Test func finalNameStripsOnlyKnownTemporarySuffixes() {
        #expect(DownloadClassifier.finalName(for: URL(fileURLWithPath: "/tmp/video.mp4.crdownload")) == "video.mp4")
        #expect(DownloadClassifier.finalName(for: URL(fileURLWithPath: "/tmp/report.PARTIAL")) == "report")
        #expect(DownloadClassifier.finalName(for: URL(fileURLWithPath: "/tmp/archive.zip")) == "archive.zip")
        #expect(DownloadClassifier.finalName(for: URL(fileURLWithPath: "/tmp/.part")) == ".part")
    }

    @Test func progressValuesStayWithinTheFiniteUnitInterval() {
        #expect(IslandActivityProgress.normalized(nil) == nil)
        #expect(IslandActivityProgress.normalized(.nan) == nil)
        #expect(IslandActivityProgress.normalized(.infinity) == nil)
        #expect(IslandActivityProgress.normalized(-.infinity) == nil)
        #expect(IslandActivityProgress.normalized(-0.01) == 0)
        #expect(IslandActivityProgress.normalized(0) == 0)
        #expect(IslandActivityProgress.normalized(0.45) == 0.45)
        #expect(IslandActivityProgress.normalized(1) == 1)
        #expect(IslandActivityProgress.normalized(1.01) == 1)
    }

    @Test func progressUpdatesAreLimitedToFourPerSecond() {
        let start = Date(timeIntervalSince1970: 1_000)
        var throttle = ProgressUpdateThrottle()
        do { let result = throttle.shouldPublish(at: start); #expect(result) }
        do { let result = throttle.shouldPublish(at: start.addingTimeInterval(0.249)); #expect(!result) }
        do { let result = throttle.shouldPublish(at: start.addingTimeInterval(0.25)); #expect(result) }
        do { let result = throttle.shouldPublish(at: start.addingTimeInterval(0.499)); #expect(!result) }
        do { let result = throttle.shouldPublish(at: start.addingTimeInterval(0.5)); #expect(result) }
    }

    @Test func activityQueueCapsLiveItemsAndKeepsNewestOnTop() {
        let start = Date(timeIntervalSince1970: 2_000)
        var queue = IslandActivityQueue()
        let items = (0..<5).map { index in
            IslandActivity(symbol: "arrow.down", title: "Item \(index)", startedAt: start.addingTimeInterval(Double(index)))
        }
        for item in items { queue.post(item) }

        #expect(queue.liveCount == IslandActivityQueue.maximumLiveActivities)
        #expect(queue.activity(id: items[0].id) == nil)
        #expect(queue.activity(id: items[1].id) != nil)
        #expect(queue.topActivity?.id == items[4].id)
    }

    @Test func finishedActivitiesLingerFourSecondsAndLiveItemsStayOnTop() {
        let start = Date(timeIntervalSince1970: 3_000)
        var queue = IslandActivityQueue()
        let completed = IslandActivity(symbol: "arrow.down", title: "Done", startedAt: start)
        let live = IslandActivity(symbol: "sparkles", title: "Working", startedAt: start.addingTimeInterval(1))
        queue.post(completed)
        queue.post(live)

        do { let result = queue.finish(id: completed.id, at: start.addingTimeInterval(2)); #expect(result) }
        #expect(queue.topActivity?.id == live.id)
        do { let result = queue.removeExpired(at: start.addingTimeInterval(5.999)); #expect(!result) }
        #expect(queue.activity(id: completed.id) != nil)
        do { let result = queue.removeExpired(at: start.addingTimeInterval(6)); #expect(result) }
        #expect(queue.activity(id: completed.id) == nil)
        #expect(queue.activity(id: live.id) != nil)
    }

    @Test func activityUpdatesOnlyReplaceLiveItemsAndFinishedHistoryStaysBounded() {
        let start = Date(timeIntervalSince1970: 3_500)
        var queue = IslandActivityQueue()
        let live = IslandActivity(symbol: "arrow.down", title: "Before", startedAt: start)
        queue.post(live)
        queue.update(IslandActivity(id: live.id, symbol: "arrow.down", title: "After", detail: "2 MB", startedAt: start))
        #expect(queue.activity(id: live.id)?.title == "After")

        var finishedIDs: [UUID] = []
        for index in 0..<5 {
            let activity = IslandActivity(symbol: "checkmark", title: "Done \(index)", startedAt: start.addingTimeInterval(Double(index + 1)))
            queue.post(activity)
            finishedIDs.append(activity.id)
            do { let result = queue.finish(id: activity.id, at: start.addingTimeInterval(Double(index + 1))); #expect(result) }
        }
        #expect(queue.activities.filter(\.isFinished).count == IslandActivityQueue.maximumFinishedActivities)
        #expect(queue.activity(id: finishedIDs[0]) == nil)
        #expect(queue.activity(id: live.id)?.title == "After")
    }

    @Test func optimisticToggleShowsTheRequestedStateAndRevertsAtTheBoundary() {
        let start = Date(timeIntervalSince1970: 4_000)
        var toggle = OptimisticToggle()
        do { let result = toggle.requestToggle(currentValue: false, at: start); #expect(result) }
        #expect(toggle.displayedValue(for: false))
        do { let result = toggle.expire(at: start.addingTimeInterval(1.499)); #expect(!result) }
        #expect(toggle.displayedValue(for: false))
        do { let result = toggle.expire(at: start.addingTimeInterval(1.5)); #expect(result) }
        #expect(!toggle.displayedValue(for: false))
        do { let result = toggle.expire(at: start.addingTimeInterval(2)); #expect(!result) }
    }

    @Test func confirmedToggleClearsOptimisticStateAndRepeatedTapReversesIt() {
        let start = Date(timeIntervalSince1970: 5_000)
        var toggle = OptimisticToggle()
        do { let result = toggle.requestToggle(currentValue: false, at: start); #expect(result) }
        toggle.observe(true)
        #expect(toggle.optimisticValue == nil)
        #expect(toggle.displayedValue(for: true))

        do { let result = toggle.requestToggle(currentValue: true, at: start.addingTimeInterval(2)); #expect(!result) }
        do { let result = toggle.requestToggle(currentValue: true, at: start.addingTimeInterval(2.1)); #expect(result) }
        #expect(toggle.displayedValue(for: true))
    }
}
