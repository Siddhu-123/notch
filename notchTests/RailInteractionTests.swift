import CoreGraphics
import SwiftUI
import Testing
@testable import notch

struct RailInteractionTests {
    @Test(arguments: [CGSize(width: 650, height: 244), CGSize(width: 760, height: 284), CGSize(width: 860, height: 324)])
    func everyButtonHasItsOwnPointerRegion(size: CGSize) {
        let rail = size.width * 0.075
        let innerHeight = size.height - rail
        let regions = (0..<3).map { NotchRailRegion.Kind.left($0) }
            + (0..<3).map { .right($0) } + (0..<11).map { .bottom($0) }
        let paths = regions.map {
            NotchRailRegion(kind: $0, rail: rail, innerHeight: innerHeight,
                leftCount: 3, rightCount: 3, bottomCount: 11).path(in: CGRect(origin: .zero, size: size))
        }
        var centers = (0..<3).map { CGPoint(x: rail / 2, y: innerHeight * (CGFloat($0) + 0.5) / 3) }
        centers += (0..<3).map { CGPoint(x: size.width - rail / 2, y: innerHeight * (CGFloat($0) + 0.5) / 3) }
        centers += (0..<11).map { CGPoint(x: rail + (size.width - 2 * rail) * (CGFloat($0) + 0.5) / 11,
            y: innerHeight + rail / 2) }
        for (index, point) in centers.enumerated() {
            #expect(paths.indices.filter { paths[$0].contains(point) } == [index])
        }
        #expect(!paths.contains { $0.contains(CGPoint(x: size.width / 2, y: innerHeight / 2)) })
        // Both diagonal corner pieces must remain separate click targets.
        for point in [CGPoint(x: 4, y: size.height - 25), CGPoint(x: 25, y: size.height - 4),
                      CGPoint(x: size.width - 4, y: size.height - 25), CGPoint(x: size.width - 25, y: size.height - 4)] {
            #expect(paths.filter { $0.contains(point) }.count == 1)
        }
    }

    @Test(arguments: [CGSize(width: 650, height: 244), CGSize(width: 760, height: 284), CGSize(width: 860, height: 324)])
    func weightedBottomFacesAndHitRegionsShareTheirBoundaries(size: CGSize) {
        let weights: [CGFloat] = [1, 1.5, 1, 1, 1.5, 1, 1, 1.5, 1, 1, 1]
        let rail = size.width * 0.075
        let innerHeight = size.height - rail
        let paths = weights.indices.map {
            NotchRailRegion(kind: .bottom($0), rail: rail, innerHeight: innerHeight,
                leftCount: 3, rightCount: 3, bottomCount: weights.count, bottomWeights: weights)
                .path(in: CGRect(origin: .zero, size: size))
        }
        let total = weights.reduce(0, +)
        var cursor: CGFloat = rail
        for index in weights.indices {
            let width = (size.width - 2 * rail) * weights[index] / total
            let center = CGPoint(x: cursor + width * 0.5, y: innerHeight + rail * 0.5)
            #expect(paths.indices.filter { paths[$0].contains(center) } == [index])
            cursor += width
        }
        #expect(paths[1].boundingRect.width > paths[2].boundingRect.width * 1.49)
        #expect(paths[4].boundingRect.width > paths[3].boundingRect.width * 1.49)
        #expect(paths[7].boundingRect.width > paths[6].boundingRect.width * 1.49)
        for point in [CGPoint(x: 4, y: size.height - 25), CGPoint(x: 25, y: size.height - 4),
                      CGPoint(x: size.width - 4, y: size.height - 25), CGPoint(x: size.width - 25, y: size.height - 4)] {
            let owners = (0..<3).map { NotchRailRegion(kind: .left($0), rail: rail, innerHeight: innerHeight,
                    leftCount: 3, rightCount: 3, bottomCount: weights.count, bottomWeights: weights)
                    .path(in: CGRect(origin: .zero, size: size)) }
                + (0..<3).map { NotchRailRegion(kind: .right($0), rail: rail, innerHeight: innerHeight,
                    leftCount: 3, rightCount: 3, bottomCount: weights.count, bottomWeights: weights)
                    .path(in: CGRect(origin: .zero, size: size)) }
                + paths
            #expect(owners.filter { $0.contains(point) }.count == 1)
        }
    }

    @Test(arguments: [CGFloat(650), 760, 860])
    func pressedFacesKeepTheInnerHingeAndRetractTheOuterEdgeFivePoints(width: CGFloat) {
        let size = CGSize(width: width, height: 244)
        let rail = width * 0.075
        for kind in [NotchRailRegion.Kind.left(0), .right(0), .bottom(0)] {
            let region = NotchRailRegion(kind: kind, rail: rail, innerHeight: size.height - rail,
                leftCount: 3, rightCount: 3, bottomCount: 11)
            let retraction = rail * (1 - cos(region.pressAngle * .pi / 180))
            #expect(abs(retraction - 5) < 0.001)
            let hinge = region.hinge(in: size)
            switch kind {
            case .left: #expect(abs(hinge.x * size.width - rail) < 0.001)
            case .right: #expect(abs(hinge.x * size.width - (size.width - rail)) < 0.001)
            case .bottom: #expect(abs(hinge.y * size.height - (size.height - rail)) < 0.001)
            }
        }
    }

    @Test(arguments: [CGFloat(650), 760, 860], [false, true])
    func mitredCornerFacesCoverTheirVisibleAreaWithoutOverlap(width: CGFloat, weighted: Bool) {
        let size = CGSize(width: width, height: 244)
        let rail = width * 0.075, radius = rail / 2
        let innerHeight = size.height - rail
        let weights: [CGFloat] = weighted ? [1, 1.5, 1, 1, 1.5, 1, 1, 1.5, 1, 1, 1] : Array(repeating: 1, count: 11)
        let rect = CGRect(origin: .zero, size: size)
        func region(_ kind: NotchRailRegion.Kind) -> Path {
            NotchRailRegion(kind: kind, rail: rail, innerHeight: innerHeight, leftCount: 3, rightCount: 3,
                            bottomCount: 11, bottomWeights: weights).path(in: rect)
        }
        let corners: [(Path, Path, CGFloat)] = [(region(.left(2)), region(.bottom(0)), 0),
                                               (region(.right(2)), region(.bottom(10)), size.width)]
        for (side, base, edge) in corners {
            let sign: CGFloat = edge == 0 ? 1 : -1
            let centre = CGPoint(x: edge + sign * (rail + radius), y: innerHeight - radius)
            var covered = 0
            for gx in stride(from: 0.5, to: rail + radius, by: 1.0) {
                for gy in stride(from: innerHeight - radius, to: size.height, by: 1.0) {
                    let point = CGPoint(x: edge + sign * gx, y: gy)
                    let insideContent = gx >= rail && hypot(point.x - centre.x, point.y - centre.y) < radius + 0.7
                        || (gx >= rail + radius && gy <= innerHeight)
                    let nearArc = abs(hypot(point.x - centre.x, point.y - centre.y) - radius) < 0.8
                    let nearMiter = abs((sign * point.x - (sign > 0 ? 0 : -size.width)) + point.y - size.height) < 0.8
                    if (insideContent && gx >= rail) || nearArc || nearMiter || gx > rail + radius { continue }
                    covered += 1
                    #expect([side, base].filter { $0.contains(point) }.count == 1, "\(point)")
                }
            }
            #expect(covered > 200)
            // The painted polygon never intrudes into the content's rounded corner.
            #expect(!side.contains(CGPoint(x: centre.x, y: centre.y)) && !base.contains(CGPoint(x: centre.x, y: centre.y)))
        }
    }

    @Test(arguments: [CGFloat(650), 860])
    func hingeStaysOnTheContentSideOfEveryKey(width: CGFloat) {
        let size = CGSize(width: width, height: 244)
        let rail = width * 0.075, innerHeight = size.height - rail
        let kinds: [NotchRailRegion.Kind] = [.left(0), .left(2), .right(0), .right(2), .bottom(0), .bottom(5), .bottom(10)]
        for kind in kinds {
            let region = NotchRailRegion(kind: kind, rail: rail, innerHeight: innerHeight,
                                         leftCount: 3, rightCount: 3, bottomCount: 11)
            let box = region.path(in: CGRect(origin: .zero, size: size)).boundingRect
            let hinge = region.hinge(in: size)
            switch kind {
            case .left: #expect(abs(hinge.x * size.width - rail) < 0.001 && box.minX == 0 && box.maxX >= rail)
            case .right: #expect(abs(hinge.x * size.width - (size.width - rail)) < 0.001
                                 && box.maxX == size.width && box.minX <= size.width - rail)
            case .bottom: #expect(abs(hinge.y * size.height - innerHeight) < 0.001
                                  && abs(box.maxY - size.height) < 0.001 && box.minY <= innerHeight)
            }
            #expect(region.pressAxis.z == 0)
        }
    }
}
