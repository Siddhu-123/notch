import CoreGraphics
import ImageIO
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import notch

struct MediaToolsTests {
    @Test func plannerOffersImageActionsAndRespectsImageIODestinations() {
        let actions = ConvertPlanner.actions(for: .png)
        let destinations = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])

        #expect(actions.contains(.png) == destinations.contains(UTType.png.identifier))
        #expect(actions.contains(.jpeg) == destinations.contains(UTType.jpeg.identifier))
        #expect(actions.contains(.heic) == destinations.contains(UTType.heic.identifier))
        #expect(actions.contains(.webp) == destinations.contains(UTType.webP.identifier))
        #expect(actions.contains(.halfSize))
        #expect(actions.contains(.max1080))
        #expect(actions.contains(.customResize))
        #expect(actions.contains(.compressJPEG))
        #expect(actions.contains(.stripMetadata))
        #expect(actions.contains(.imagesPDF))
        #expect(!actions.contains(.mergePDF))
        #expect(!actions.contains(.mp4H264))
    }

    @Test func plannerTreatsJPEGLikePNGAndPDFIsNotAnImage() {
        #expect(ConvertPlanner.actions(for: .jpeg) == ConvertPlanner.actions(for: .png))
        #expect(!ConvertPlanner.actions(for: .pdf).contains(.imagesPDF))
        #expect(ConvertPlanner.actions(for: .mpeg4Movie).contains(.makeGIF))
        #expect(ConvertPlanner.actions(for: .plainText).isEmpty)
    }

    @Test func outputNamingIgnoresCaseAndUnrelatedFiles() {
        let input = URL(fileURLWithPath: "/tmp/convert-tests/clip.mov")
        let upper = URL(fileURLWithPath: "/tmp/convert-tests/CLIP H264.MP4")
        let elsewhere = URL(fileURLWithPath: "/tmp/other/clip H264.mp4")
        #expect(ConvertNaming.outputURL(input: input, suffix: "H264", ext: "mp4", existing: [upper]).lastPathComponent
                == "clip H264 2.mp4")
        #expect(ConvertNaming.outputURL(input: input, suffix: "H264", ext: "mp4", existing: [elsewhere]).lastPathComponent
                == "clip H264.mp4")
        #expect(ConvertNaming.outputURL(input: input, suffix: "H264", ext: "mp4", existing: [elsewhere])
                .deletingLastPathComponent().path == "/tmp/convert-tests")
    }

    @Test func resizeMathBoundaryAroundMaxEdge() {
        #expect(ResizeMath.size(for: CGSize(width: 1081, height: 1081), maxEdge: 1080) == CGSize(width: 1080, height: 1080))
        #expect(ResizeMath.size(for: CGSize(width: 1080, height: 720), maxEdge: 1080) == CGSize(width: 1080, height: 720))
        #expect(ResizeMath.size(for: CGSize(width: 1079, height: 10), maxEdge: 1080) == CGSize(width: 1079, height: 10))
        #expect(ResizeMath.size(for: CGSize(width: 100, height: 100), maxEdge: CGFloat.nan) == .zero)
    }

    @Test func plannerSeparatesVideoAudioPDFAndUnsupportedTypes() {
        let videoActions = ConvertPlanner.actions(for: .quickTimeMovie)
        #expect(videoActions == [.mp4H264, .hevc, .compress1080, .compress720, .extractM4A, .makeGIF])
        #expect(ConvertPlanner.actions(for: .mpeg4Audio) == [.audioM4A])
        #expect(ConvertPlanner.actions(for: .pdf) == [.mergePDF])
        #expect(ConvertPlanner.actions(for: .application) == [])
    }

    @Test func outputNamingKeepsInputStemAndAddsCollisionNumbers() {
        let input = URL(fileURLWithPath: "/tmp/convert-tests/trip.photo.png")
        let first = ConvertNaming.outputURL(input: input, suffix: "PNG", ext: ".png", existing: [])
        #expect(first.lastPathComponent == "trip.photo PNG.png")

        let second = ConvertNaming.outputURL(input: input, suffix: "PNG", ext: "png", existing: Set([first]))
        #expect(second.lastPathComponent == "trip.photo PNG 2.png")

        let third = ConvertNaming.outputURL(input: input, suffix: "PNG", ext: "png", existing: Set([first, second]))
        #expect(third.lastPathComponent == "trip.photo PNG 3.png")
    }

    @Test func outputNamingHandlesEmptySuffixAndExtension() {
        let input = URL(fileURLWithPath: "/tmp/convert-tests/archive.tar.gz")
        let noSuffix = ConvertNaming.outputURL(input: input, suffix: "  ", ext: ".", existing: [])
        #expect(noSuffix.lastPathComponent == "archive.tar")

        let withExtension = ConvertNaming.outputURL(input: input, suffix: "copy", ext: "pdf", existing: [])
        #expect(withExtension.lastPathComponent == "archive.tar copy.pdf")
    }

    @Test func resizeMathCapsLongestEdgeAndPreservesAspectRatio() {
        #expect(ResizeMath.size(for: CGSize(width: 4000, height: 2000), maxEdge: 1080) == CGSize(width: 1080, height: 540))
        #expect(ResizeMath.size(for: CGSize(width: 200, height: 401), maxEdge: 200) == CGSize(width: 100, height: 200))
        #expect(ResizeMath.size(for: CGSize(width: 800, height: 400), maxEdge: 800) == CGSize(width: 800, height: 400))
    }

    @Test func resizeMathDoesNotUpscaleAndRejectsInvalidBoundaries() {
        #expect(ResizeMath.size(for: CGSize(width: 120, height: 80), maxEdge: 500) == CGSize(width: 120, height: 80))
        #expect(ResizeMath.size(for: CGSize(width: 1, height: 400), maxEdge: 1) == CGSize(width: 1, height: 1))
        #expect(ResizeMath.size(for: CGSize(width: 0, height: 400), maxEdge: 100) == .zero)
        #expect(ResizeMath.size(for: CGSize(width: 400, height: 100), maxEdge: 0) == .zero)
        #expect(ResizeMath.size(for: CGSize(width: -1, height: 100), maxEdge: 50) == .zero)
        #expect(ResizeMath.size(for: CGSize(width: CGFloat.infinity, height: 100), maxEdge: 50) == .zero)
    }
}
