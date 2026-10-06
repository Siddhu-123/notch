import Foundation
import Testing
@testable import notch

struct SystemReadingsTests {
    @Test func cpuUsesIntervalLoadAndDropsSleepGaps() {
        let baseline = NotchCPUTicks(busy: 600, total: 1_000, uptime: 10)
        #expect(NotchSystemReadingMath.cpuPercent(previous: nil, current: baseline) == nil)
        #expect(NotchSystemReadingMath.cpuPercent(previous: baseline,
            current: .init(busy: 650, total: 1_200, uptime: 12)) == 25)
        #expect(NotchSystemReadingMath.cpuPercent(previous: baseline,
            current: .init(busy: 700, total: 1_400, uptime: 30)) == nil)
    }

    @Test func cpuHandlesResetsInvalidCountersAndNoElapsedTicks() {
        let baseline = NotchCPUTicks(busy: 600, total: 1_000, uptime: 10)
        for next in [NotchCPUTicks(busy: 10, total: 100, uptime: 12),
                     .init(busy: 590, total: 1_100, uptime: 12),
                     .init(busy: 600, total: 1_000, uptime: 12),
                     .init(busy: 800, total: 1_100, uptime: 12),
                     .init(busy: 650, total: 1_200, uptime: 9)] {
            #expect(NotchSystemReadingMath.cpuPercent(previous: baseline, current: next) == nil)
        }
    }

    @Test func memoryExcludesPurgeableAndIncludesCompressor() {
        #expect(NotchSystemReadingMath.usedMemory(totalBytes: 100_000, pageSize: 1_000,
            internalPages: 50, purgeablePages: 10, wiredPages: 5, compressedPages: 3) == 48_000)
        #expect(NotchSystemReadingMath.usedMemory(totalBytes: 100_000, pageSize: 1_000,
            internalPages: 5, purgeablePages: 10, wiredPages: 5, compressedPages: 3) == 8_000)
    }

    @Test func memoryBoundsAndOverflowAreExplicit() {
        #expect(NotchSystemReadingMath.usedMemory(totalBytes: 10_000, pageSize: 1_000,
            internalPages: 50, purgeablePages: 0, wiredPages: 5, compressedPages: 3) == 10_000)
        #expect(NotchSystemReadingMath.usedMemory(totalBytes: 10_000, pageSize: 0,
            internalPages: 50, purgeablePages: 0, wiredPages: 5, compressedPages: 3) == nil)
        #expect(NotchSystemReadingMath.usedMemory(totalBytes: .max, pageSize: 1,
            internalPages: .max, purgeablePages: 0, wiredPages: 1, compressedPages: 0) == nil)
        #expect(NotchSystemReadingMath.usedMemory(totalBytes: .max, pageSize: 2,
            internalPages: .max, purgeablePages: 0, wiredPages: 0, compressedPages: 0) == nil)
    }

    @MainActor @Test func constructionAndStopDoNotStartSampling() {
        let readings = NotchSystemReadings()
        #expect(readings.cpuPercent == nil)
        #expect(readings.usedMemoryBytes == nil)
        #expect(readings.cpuHistory.isEmpty)
        #expect(readings.totalMemoryBytes > 0)
        readings.stop()
        readings.stop()
        #expect(readings.lastError == nil)
        #expect(readings.cpuPercent == nil)
    }
}
