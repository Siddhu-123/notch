import Foundation
import Testing
@testable import notch

struct ProductivityFeatureTests {
    @Test func fuzzyMatcherRequiresAnOrderedSubsequenceAndPrefersCompactPrefixMatches() {
        #expect(FuzzyMatcher.score(query: "", candidate: "Anything") == 0)
        #expect(FuzzyMatcher.score(query: "safari", candidate: "Safari") != nil)
        #expect(FuzzyMatcher.score(query: "sfr", candidate: "Safari") != nil)
        #expect(FuzzyMatcher.score(query: "xyz", candidate: "Safari") == nil)
        #expect(FuzzyMatcher.score(query: "app", candidate: "Apps")! > FuzzyMatcher.score(query: "app", candidate: "Open Applications")!)
        #expect(FuzzyMatcher.score(query: "cafe", candidate: "Café") != nil)
    }

    @Test func safeMathEvaluatesPrecedenceDecimalsAndParentheses() {
        #expect(SafeMath.evaluate("1 + 2 * 3") == 7)
        #expect(SafeMath.evaluate("(1 + 2) * 3") == 9)
        #expect(SafeMath.evaluate("-2.5 + .5") == -2)
        #expect(SafeMath.evaluate("1 / 4") == 0.25)
        #expect(SafeMath.evaluate("1" + String(repeating: " ", count: 253) + "+1") == 2)
        #expect(SafeMath.evaluate(String(repeating: "(", count: 32) + "1" + String(repeating: ")", count: 32)) == 1)
    }

    @Test func safeMathRejectsNonMathInputMalformedEdgesAndNonFiniteResults() {
        for input in ["", " ", "1 +", "(1 + 2", "1 + 2)", "1..2", "1 2", "sqrt(4)", "1^2", "1/0", "1e3"] {
            #expect(SafeMath.evaluate(input) == nil)
        }
        #expect(SafeMath.evaluate(String(repeating: "1", count: 257)) == nil)
        #expect(SafeMath.evaluate(String(repeating: "(", count: 33) + "1" + String(repeating: ")", count: 33)) == nil)
    }

    @Test func radialSliceUsesTopClockwiseAndWrapsAtTheSeam() {
        #expect(RadialGeometry.slice(for: .pi / 2, count: 4) == 0)
        #expect(RadialGeometry.slice(for: 0, count: 4) == 1)
        #expect(RadialGeometry.slice(for: -.pi / 2, count: 4) == 2)
        #expect(RadialGeometry.slice(for: .pi, count: 4) == 3)
        #expect(RadialGeometry.slice(for: .pi / 2 - .pi / 4, count: 4) == 1)
        #expect(RadialGeometry.slice(for: .pi / 2 + 2 * .pi, count: 4) == 0)
        #expect(RadialGeometry.slice(for: -.pi, count: 1) == 0)
        #expect(RadialGeometry.slice(for: 0, count: 0) == -1)
        #expect(RadialGeometry.slice(for: .infinity, count: 8) == -1)
    }

    @Test func usageIsBoundedAndRanksFrequentActionsFirst() {
        let suite = "ProductivityFeatureTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["module.music": 2, "tool.tools": 4], forKey: ProductivityUsage.defaultsKey)
        ProductivityUsage.record("module.music", defaults: defaults)
        #expect(ProductivityUsage.counts(defaults: defaults)["module.music"] == 3)
        #expect(ProductivityUsage.top(["module.music", "tool.tools", "module.apps"], id: { $0 }, defaults: defaults) == ["tool.tools", "module.music", "module.apps"])

        for index in 0..<ProductivityUsage.maximumKeys {
            ProductivityUsage.record("action.\(index)", defaults: defaults)
        }
        #expect(ProductivityUsage.counts(defaults: defaults).count == ProductivityUsage.maximumKeys)
        ProductivityUsage.record("action.\(ProductivityUsage.maximumKeys)", defaults: defaults)
        #expect(ProductivityUsage.counts(defaults: defaults).count == ProductivityUsage.maximumKeys)
        defaults.set(["only": ProductivityUsage.maximumCount], forKey: ProductivityUsage.defaultsKey)
        ProductivityUsage.record("only", defaults: defaults)
        #expect(ProductivityUsage.counts(defaults: defaults)["only"] == ProductivityUsage.maximumCount)
    }

    @Test func cleaningModeExitsOnlyAfterHeldEscapeOrAtTheSixtySecondLimit() {
        var state = CleaningModeState()
        state.start(at: 10)
        #expect(state.isActive)
        do { let result = state.expire(at: 69.999); #expect(!result) }
        state.escapeDown(at: 20)
        do { let result = state.advance(at: 21.999); #expect(!result) }
        #expect(state.isActive)
        do { let result = state.advance(at: 22); #expect(result) }
        #expect(!state.isActive)

        state.start(at: 70)
        state.escapeDown(at: 71)
        do { let result = state.escapeUp(at: 72.999); #expect(!result) }
        #expect(state.isActive)
        state.escapeDown(at: 73)
        do { let result = state.escapeUp(at: 75); #expect(result) }
        #expect(!state.isActive)

        state.start(at: 100)
        do { let result = state.expire(at: 159.999); #expect(!result) }
        do { let result = state.expire(at: 160); #expect(result) }
        #expect(!state.isActive)
    }

    @Test func radialActionSettingsFiltersUnknownActionsAndCapsAtEight() {
        let allowed = (0..<10).map { "action.\($0)" }
        #expect(RadialActionSettings.decode(nil, allowed: allowed) == Array(allowed.prefix(8)))
        #expect(RadialActionSettings.decode("action.9,unknown,action.2", allowed: allowed) == ["action.9", "action.2", "action.0", "action.1", "action.3", "action.4", "action.5", "action.6"])
        #expect(RadialActionSettings.decode(allowed.joined(separator: ","), allowed: allowed).count == 8)
        #expect(RadialActionSettings.encode(["unknown", "action.1"], allowed: allowed) == "action.1,action.0,action.2,action.3,action.4,action.5,action.6,action.7")
    }
}
