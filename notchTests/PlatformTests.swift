import Foundation
import Testing
@testable import notch

struct PlatformTests {
    @Test func panelOrderingDropsUnknownsDeduplicatesAppendsMissingAndHonorsHiddenPages() {
        let ordered = NotchPanelLayout.ordered(
            stored: ["unknown", NotchToolkitPage.tools.rawValue, NotchToolkitPage.tools.rawValue, NotchToolkitPage.notes.rawValue],
            hidden: [NotchToolkitPage.notes.rawValue]
        )
        #expect(ordered.first == .tools)
        #expect(!ordered.contains(.notes))
        #expect(Set(ordered).count == ordered.count)
        #expect(ordered.count == NotchToolkitPage.allCases.count - 1)

        let allHidden = Set(NotchToolkitPage.allCases.map(\.rawValue))
        #expect(NotchPanelLayout.ordered(stored: [], hidden: allHidden) == [.tools])
    }

    @Test func panelMoveClampsAtBothEndsAndMovesPages() {
        let pages = NotchToolkitPage.allCases
        #expect(NotchPanelLayout.move(pages[0], by: -1, in: pages) == pages)
        #expect(NotchPanelLayout.move(pages[pages.count - 1], by: 1, in: pages) == pages)
        #expect(NotchPanelLayout.move(pages[0], by: Int.min, in: pages) == pages)
        #expect(NotchPanelLayout.move(pages[pages.count - 1], by: Int.max, in: pages) == pages)

        let movedFirst = NotchPanelLayout.move(pages[0], by: 1, in: pages)
        #expect(movedFirst[0] == pages[1])
        #expect(movedFirst[1] == pages[0])
        let movedLast = NotchPanelLayout.move(pages[pages.count - 1], by: -1, in: pages)
        #expect(movedLast[movedLast.count - 2] == pages[pages.count - 1])
        #expect(movedLast.last == pages[pages.count - 2])
    }

    @Test func settingsExportIncludesOnlyAllowedNotchValues() throws {
        let suite = "notch.platform.export.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(true, forKey: "notch.panel.testBool")
        defaults.set(17, forKey: "notch.panel.testInt")
        defaults.set(2.75, forKey: "notch.panel.testDouble")
        defaults.set("value", forKey: "notch.panel.testString")
        defaults.set(["one", "two"], forKey: "notch.panel.testStrings")
        defaults.set(Data([1, 2]), forKey: "notch.panel.data")
        defaults.set(Date(timeIntervalSince1970: 10), forKey: "notch.panel.date")
        defaults.set(["nested": "object"], forKey: "notch.panel.object")
        defaults.set("outside", forKey: "unrelated.key")
        defaults.set("secret", forKey: "notch.apiToken")
        defaults.set("secret", forKey: "notch.secret.value")
        defaults.set("secret", forKey: "notch.userPassword")
        defaults.set("secret", forKey: "notch.service.key.value")

        let json = try #require(JSONSerialization.jsonObject(with: NotchSettingsTransfer.export(defaults: defaults)) as? [String: Any])
        #expect((json["version"] as? Int) == 1)
        let values = try #require(json["values"] as? [String: Any])
        #expect(values["notch.panel.testBool"] as? Bool == true)
        #expect(values["notch.panel.testInt"] as? Int == 17)
        #expect(values["notch.panel.testDouble"] as? Double == 2.75)
        #expect(values["notch.panel.testString"] as? String == "value")
        #expect(values["notch.panel.testStrings"] as? [String] == ["one", "two"])
        #expect(values["notch.panel.data"] == nil)
        #expect(values["notch.panel.date"] == nil)
        #expect(values["notch.panel.object"] == nil)
        #expect(values["unrelated.key"] == nil)
        #expect(values["notch.apiToken"] == nil)
        #expect(values["notch.secret.value"] == nil)
        #expect(values["notch.userPassword"] == nil)
        #expect(values["notch.service.key.value"] == nil)
    }

    @Test func settingsImportRoundTripsIntoAnIsolatedDefaultsSuite() throws {
        let sourceSuite = "notch.platform.source.\(UUID().uuidString)"
        let targetSuite = "notch.platform.target.\(UUID().uuidString)"
        let source = try #require(UserDefaults(suiteName: sourceSuite))
        let target = try #require(UserDefaults(suiteName: targetSuite))
        defer {
            source.removePersistentDomain(forName: sourceSuite)
            target.removePersistentDomain(forName: targetSuite)
        }

        source.set(true, forKey: "notch.feature.capture")
        source.set("compact", forKey: "notch.panel.testPreset")
        source.set(Data([3, 4]), forKey: "notch.panel.bookmark")
        let imported = try NotchSettingsTransfer.importData(NotchSettingsTransfer.export(defaults: source), into: target)
        #expect(imported == 2)
        #expect(NotchFeatureRegistry.isEnabled(.capture, defaults: target))
        #expect(target.object(forKey: "notch.feature.capture") as? Bool == true)
        #expect(target.string(forKey: "notch.panel.testPreset") == "compact")
        #expect(target.object(forKey: "notch.panel.bookmark") == nil)
    }

    @Test func settingsImportRejectsUnsupportedVersionAndMalformedJSON() {
        let unsupported = Data(#"{"version":2,"values":{}}"#.utf8)
        let malformed = Data("{not json".utf8)
        #expect(throws: NotchSettingsTransfer.TransferError.self) {
            try NotchSettingsTransfer.importData(unsupported, into: .standard)
        }
        #expect(throws: NotchSettingsTransfer.TransferError.self) {
            try NotchSettingsTransfer.importData(malformed, into: .standard)
        }
    }

    @Test func everyFeatureAndPermissionHasLocalizedExplanatoryText() {
        #expect(NotchFeature.allCases.allSatisfy { !$0.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        #expect(NotchPermission.allCases.allSatisfy { !$0.why.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }

    @Test func localizationCatalogContainsEveryRequiredLanguage() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../notch/Localizable.xcstrings")
            .standardizedFileURL
        let data = try Data(contentsOf: source)
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(root["strings"] as? [String: Any])
        let languages = ["de", "es", "fr", "it", "ja", "ko", "pt-BR", "ru", "zh-Hans", "zh-Hant", "nl", "tr"]
        for (key, rawEntry) in strings {
            let entry = try #require(rawEntry as? [String: Any], "Missing entry for \(key)")
            let localizations = try #require(entry["localizations"] as? [String: Any], "Missing localizations for \(key)")
            for language in languages {
                let locale = try #require(localizations[language] as? [String: Any], "Missing \(language) for \(key)")
                let unit = try #require(locale["stringUnit"] as? [String: Any], "Missing string unit for \(key) / \(language)")
                #expect(unit["state"] as? String == "translated", "Untranslated \(language) string: \(key)")
                #expect(unit["value"] as? String != nil, "Missing value for \(key) / \(language)")
            }
        }
    }
}
