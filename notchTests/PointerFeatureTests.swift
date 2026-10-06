import Testing
@testable import notch

struct PointerFeatureTests {
    @Test func easedScrollSamplesSumToDeltaAndEaseOut() {
        let positive = ScrollEasing.samples(delta: 120, duration: 0.18, hz: 120)
        let negative = ScrollEasing.samples(delta: -45.5, duration: 0.18, hz: 120)
        #expect(positive.count == 22)
        #expect(abs(positive.reduce(0, +) - 120) < 0.000_001)
        #expect(abs(negative.reduce(0, +) + 45.5) < 0.000_001)
        #expect(positive.first! > positive.last!)
        #expect(ScrollEasing.samples(delta: 1, duration: 0, hz: 120).isEmpty)
        #expect(ScrollEasing.samples(delta: 1, duration: 0.1, hz: 0).isEmpty)
        #expect(ScrollEasing.samples(delta: .infinity, duration: 0.1, hz: 120).isEmpty)
        #expect(ScrollEasing.samples(delta: 1, duration: 20, hz: 120).count == 512)
    }

    @Test func scrollTransformChangesMouseOnlyAndUsesSelectedModifier() {
        let reversed = ScrollTransform.apply(verticalDelta: 8, horizontalDelta: -2, isContinuous: false, reverseMouse: true)
        #expect(reversed == ScrollDelta(vertical: -8, horizontal: 2))

        let shifted = ScrollTransform.apply(
            verticalDelta: 8, horizontalDelta: 2, isContinuous: false,
            modifiers: .shift, reverseMouse: false, horizontalModifier: .shift
        )
        #expect(shifted == ScrollDelta(vertical: 0, horizontal: 10))

        let optionNotShift = ScrollTransform.apply(
            verticalDelta: 8, horizontalDelta: 2, isContinuous: false,
            modifiers: .shift, horizontalModifier: .option
        )
        #expect(optionNotShift == ScrollDelta(vertical: 8, horizontal: 2))

        let option = ScrollTransform.apply(
            verticalDelta: 8, horizontalDelta: 2, isContinuous: false,
            modifiers: .option, horizontalModifier: .option
        )
        #expect(option == ScrollDelta(vertical: 0, horizontal: 10))

        let trackpad = ScrollTransform.apply(
            verticalDelta: 8, horizontalDelta: 2, isContinuous: true,
            modifiers: .shift, reverseMouse: true, horizontalModifier: .shift
        )
        #expect(trackpad == ScrollDelta(vertical: 8, horizontal: 2))
    }

    @Test func clickFilterSwallowsOnlyUnmarkedClicksInsideThreshold() {
        var filter = ClickFilter()
        do { let result = filter.shouldSwallow(button: 0, at: 1, clickState: 1, thresholdMS: 60); #expect(!result) }
        do { let result = filter.shouldSwallow(button: 0, at: 1.059, clickState: 1, thresholdMS: 60); #expect(result) }
        do { let result = filter.shouldSwallow(button: 1, at: 1.02, clickState: 1, thresholdMS: 60); #expect(!result) }

        do { let result = filter.shouldSwallow(button: 0, at: 1.03, clickState: 2, thresholdMS: 60); #expect(!result) }
        do { let result = filter.shouldSwallow(button: 0, at: 1.09, clickState: 1, thresholdMS: 60); #expect(!result) }

        var boundary = ClickFilter()
        do { let result = boundary.shouldSwallow(button: 0, at: 4, clickState: 1, thresholdMS: 60); #expect(!result) }
        do { let result = boundary.shouldSwallow(button: 0, at: 4.06, clickState: 1, thresholdMS: 60); #expect(!result) }
        do { let result = boundary.shouldSwallow(button: 0, at: 4.05, clickState: 1, thresholdMS: 20); #expect(!result) }
    }

    @Test func keyDebounceHonorsKeyUpWindowAndAutorepeat() {
        var debounce = KeyDebounce()
        do { let result = debounce.process(.keyUp(keyCode: 12), at: 2, thresholdMS: 40); #expect(!result) }
        do { let result = debounce.process(.keyDown(keyCode: 12, autorepeat: false), at: 2.039, thresholdMS: 40); #expect(result) }
        do { let result = debounce.process(.keyUp(keyCode: 12), at: 2.04, thresholdMS: 40); #expect(result) }
        do { let result = debounce.process(.keyDown(keyCode: 12, autorepeat: true), at: 2.05, thresholdMS: 40); #expect(!result) }

        do { let result = debounce.process(.keyUp(keyCode: 13), at: 3, thresholdMS: 40); #expect(!result) }
        do { let result = debounce.process(.keyDown(keyCode: 13, autorepeat: false), at: 3.04, thresholdMS: 40); #expect(!result) }
        do { let result = debounce.process(.keyUp(keyCode: 12), at: 4, thresholdMS: 40); #expect(!result) }
        do { let result = debounce.process(.keyDown(keyCode: 12, autorepeat: false), at: 3.99, thresholdMS: 40); #expect(!result) }

        do { let result = debounce.process(.keyDown(keyCode: 12, autorepeat: false), at: 5, thresholdMS: 40); #expect(!result) }
        do { let result = debounce.process(.keyUp(keyCode: 300), at: 5.01, thresholdMS: 40); #expect(!result) }
    }

    @Test func threeFingerTapRequiresThreeStableTouchesAndShortDuration() {
        let start = [
            PointerTouchPoint(x: 0.2, y: 0.4),
            PointerTouchPoint(x: 0.3, y: 0.4),
            PointerTouchPoint(x: 0.4, y: 0.4)
        ]
        var detector = ThreeFingerTapDetector()
        do { let result = detector.update(points: start, at: 1); #expect(!result) }
        do { let result = detector.update(points: start, at: 1.19); #expect(!result) }
        do { let result = detector.update(points: [], at: 1.199); #expect(result) }

        var durationBoundary = ThreeFingerTapDetector()
        do { let result = durationBoundary.update(points: start, at: 2); #expect(!result) }
        do { let result = durationBoundary.update(points: [], at: 2.2); #expect(!result) }

        var movementBoundary = ThreeFingerTapDetector()
        do { let result = movementBoundary.update(points: start, at: 3); #expect(!result) }
        let within = [
            PointerTouchPoint(x: 0.23, y: 0.4),
            PointerTouchPoint(x: 0.3, y: 0.4),
            PointerTouchPoint(x: 0.4, y: 0.4)
        ]
        do { let result = movementBoundary.update(points: within, at: 3.1); #expect(!result) }
        do { let result = movementBoundary.update(points: [], at: 3.15); #expect(result) }

        var moved = ThreeFingerTapDetector()
        do { let result = moved.update(points: start, at: 4); #expect(!result) }
        let beyond = [
            PointerTouchPoint(x: 0.2301, y: 0.4),
            PointerTouchPoint(x: 0.3, y: 0.4),
            PointerTouchPoint(x: 0.4, y: 0.4)
        ]
        do { let result = moved.update(points: beyond, at: 4.1); #expect(!result) }
        do { let result = moved.update(points: [], at: 4.15); #expect(!result) }

        var wrongCount = ThreeFingerTapDetector()
        do { let result = wrongCount.update(points: Array(start.prefix(2)), at: 5); #expect(!result) }
        do { let result = wrongCount.update(points: [], at: 5.1); #expect(!result) }
    }
}
