import Foundation
import Testing
@testable import notch

struct WorkspaceTests {
    @MainActor
    @Test func companionChoicesPersistWithoutChangingOtherPreferences() {
        let suite = "notch.workspace.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("keep", forKey: "unrelated")
        let settings = NotchDesignPreferences(defaults: defaults)
        #expect(!settings.festiveLights && settings.dropPaw)
        settings.festiveLights = true
        settings.dropPaw = false
        settings.assistantActivity = false
        let restored = NotchDesignPreferences(defaults: defaults)
        #expect(restored.festiveLights && !restored.dropPaw && !restored.assistantActivity)
        #expect(defaults.string(forKey: "unrelated") == "keep")
    }
    @Test func dragIntentsRejectWrongAxesDiagonalsAndInactiveTracks() {
        #expect(NotchDragIntent.vertical(CGSize(width: 100, height: -80), isExpanded: true) == nil)
        #expect(NotchDragIntent.track(CGSize(width: 60, height: 100), hasTrack: true) == nil)
        #expect(NotchDragIntent.vertical(CGSize(width: 100, height: 80), isExpanded: false) == nil)
        #expect(NotchDragIntent.track(CGSize(width: 100, height: 80), hasTrack: true) == nil)
        #expect(NotchDragIntent.track(CGSize(width: -100, height: 0), hasTrack: false) == nil)
        #expect(NotchDragIntent.vertical(CGSize(width: 0, height: 40), isExpanded: false) == nil)
        #expect(NotchDragIntent.track(CGSize(width: 48, height: 0), hasTrack: true) == nil)
        #expect(NotchDragIntent.vertical(CGSize(width: 0, height: -100), isExpanded: false) == nil)
        #expect(NotchDragIntent.vertical(CGSize(width: 0, height: 100), isExpanded: true) == nil)
    }

    @Test func directionalDragsExpandCollapseAndChangeTracks() {
        #expect(NotchDragIntent.vertical(CGSize(width: 15, height: 60), isExpanded: false) == .expand)
        #expect(NotchDragIntent.vertical(CGSize(width: 15, height: -60), isExpanded: true) == .collapse)
        #expect(NotchDragIntent.track(CGSize(width: -60, height: 15), hasTrack: true) == .next)
        #expect(NotchDragIntent.track(CGSize(width: 60, height: 15), hasTrack: true) == .previous)
    }

}
