import CoreGraphics
import Foundation
import Testing
@testable import notch

@Suite("Capture feature pure logic")
struct CaptureFeatureTests {
    @Test func fileFormatParsingAcceptsSupportedFormatsOnly() {
        #expect(CaptureFormat(rawValue: "PNG") == .png)
        #expect(CaptureFormat(rawValue: "JPEG") == .jpeg)
        #expect(CaptureFormat(rawValue: "GIF") == nil)
    }

    @Test func scrollOverlapFindsPartialAndFullMatches() {
        let previous = syntheticImage(rows: [10, 20, 30, 40, 50])
        let next = syntheticImage(rows: [40, 50, 60, 70])
        let identical = syntheticImage(rows: [10, 20, 30, 40, 50])

        #expect(ScrollStitcher.overlap(previous: previous, next: next) == 2)
        #expect(ScrollStitcher.overlap(previous: previous, next: identical) == 5)
    }

    @Test func scrollOverlapRejectsDifferentWidthsAndUnmatchedRows() {
        let previous = syntheticImage(rows: [10, 20, 30, 40])
        let differentRows = syntheticImage(rows: [80, 90, 100, 110])
        let differentWidth = syntheticImage(rows: [30, 40], width: 3)

        #expect(ScrollStitcher.overlap(previous: previous, next: differentRows) == 0)
        #expect(ScrollStitcher.overlap(previous: previous, next: differentWidth) == 0)
    }

    @Test func scrollCaptureLimitsAllowTheLastFrameAndLastPixel() {
        #expect(ScrollStitcher.canAppend(frameCount: 19, currentHeight: 100, nextHeight: 100))
        #expect(!ScrollStitcher.canAppend(frameCount: 20, currentHeight: 100, nextHeight: 100))
        #expect(ScrollStitcher.canAppend(frameCount: 1, currentHeight: 19_999, nextHeight: 1))
        #expect(!ScrollStitcher.canAppend(frameCount: 1, currentHeight: 20_000, nextHeight: 1))
        #expect(ScrollStitcher.canAppend(frameCount: 1, currentHeight: 20_000, nextHeight: 1, overlap: 1))
    }

    @Test func regionDiffCountsMeaningfulPixelChanges() {
        #expect(RegionDiff.changedFraction(a: [10, 20, 30, 40], b: [10, 20, 30, 40]) == 0)
        #expect(RegionDiff.changedFraction(a: [10, 20, 30, 40], b: [21, 31, 41, 51]) == 0)
        #expect(RegionDiff.changedFraction(a: [10, 20, 30, 40], b: [22, 20, 60, 40]) == 0.5)
    }

    @Test func regionDiffHandlesEmptyAndMismatchedBuffers() {
        #expect(RegionDiff.changedFraction(a: [], b: []) == 0)
        #expect(RegionDiff.changedFraction(a: [1], b: []) == 1)
        #expect(RegionDiff.changedFraction(a: [1, 2], b: [1]) == 1)
    }

    @Test func watchThresholdIsStrictAtTheBoundary() {
        #expect(!RegionDiff.exceedsThreshold(0.02, threshold: 0.02))
        #expect(RegionDiff.exceedsThreshold(0.0201, threshold: 0.02))
        #expect(!RegionDiff.exceedsThreshold(0.01, threshold: 0.02))
        #expect(!RegionDiff.exceedsThreshold(.nan, threshold: 0.02))
    }

    private func syntheticImage(rows: [UInt8], width: Int = 2) -> CGImage {
        var pixels = [UInt8](repeating: 255, count: rows.count * width * 4)
        for (row, value) in rows.enumerated() {
            for column in 0..<width {
                let offset = (row * width + column) * 4
                pixels[offset] = value
                pixels[offset + 1] = value
                pixels[offset + 2] = value
                pixels[offset + 3] = 255
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(width: width, height: rows.count, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
}
