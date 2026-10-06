//
//  notchUITests.swift
//  notchUITests
//
//  Created by Balanagu Satya Siddhartha on 12/8/2025.
//

import XCTest

final class notchUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() throws {
        let app = launchApp()
        XCTAssertTrue(app.buttons["collapsed-notch"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testCanOpenMirrorModule() throws {
        let app = launchApp()
        expand(app)

        let mirrorButton = app.buttons["module-mirror"]
        XCTAssertTrue(mirrorButton.waitForExistence(timeout: 5))
        mirrorButton.click()
        XCTAssertTrue(app.descendants(matching: .any)["mirror-panel"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testEveryCoreModuleIsReachable() throws {
        let app = launchApp()
        expand(app)

        let checks: [(button: String, name: String, identifier: String)] = [
            ("module-calendar", "Calendar", "calendar-panel"),
            ("module-shelf", "Shelf", "shelf-panel"),
            ("module-apps", "Apps", "apps-panel"),
            ("module-controls", "Controls", "controls-panel"),
            ("module-mirror", "Mirror", "mirror-panel")
        ]

        for check in checks {
            let button = app.buttons[check.button]
            XCTAssertTrue(button.waitForExistence(timeout: 5), "Missing \(check.name) module button")
            button.click()
            XCTAssertTrue(app.descendants(matching: .any)[check.identifier].waitForExistence(timeout: 5), "\(check.name) module did not appear")
        }

        let homeButton = app.buttons["module-nowPlaying"]
        XCTAssertTrue(homeButton.waitForExistence(timeout: 5))
        homeButton.click()
        XCTAssertTrue(app.descendants(matching: .any)["home-panel"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testPrimaryTabsStaySynchronizedDuringRapidSwitching() throws {
        let app = launchApp()
        expand(app)

        let home = app.buttons["module-nowPlaying"]
        let shelf = app.buttons["module-shelf"]
        let apps = app.buttons["module-apps"]
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        XCTAssertTrue(shelf.waitForExistence(timeout: 5))
        XCTAssertTrue(apps.waitForExistence(timeout: 5))

        for _ in 0..<3 {
            shelf.click()
            waitForModule(app, identifier: "shelf-panel")
            apps.click()
            waitForModule(app, identifier: "apps-panel")
            home.click()
            waitForModule(app, identifier: "home-panel")
        }

        shelf.click()
        waitForModule(app, identifier: "shelf-panel")
        XCTAssertTrue(app.descendants(matching: .any)["shelf-panel"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["apps-panel"].waitForNonExistence(timeout: 2))
        XCTAssertTrue(app.descendants(matching: .any)["home-panel"].waitForNonExistence(timeout: 2))

        apps.click()
        waitForModule(app, identifier: "apps-panel")
        XCTAssertTrue(app.descendants(matching: .any)["apps-panel"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["shelf-panel"].waitForNonExistence(timeout: 2))
        XCTAssertTrue(app.descendants(matching: .any)["home-panel"].waitForNonExistence(timeout: 2))
    }

    @MainActor
    func testSettingsTabsAndPreferenceControlsAreReachable() throws {
        let app = launchApp()
        expand(app)

        app.buttons["module-nowPlaying"].rightClick()
        let settingsButton = app.descendants(matching: .any)["settings-button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
        settingsButton.click()

        let general = app.descendants(matching: .any)["settings-general"]
        XCTAssertTrue(general.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["settings-show-notch"].waitForExistence(timeout: 5))

        let showNotch = app.descendants(matching: .any)["settings-show-notch"]
        let originalValue = showNotch.value as? String
        showNotch.click()
        XCTAssertNotEqual(showNotch.value as? String, originalValue)
        showNotch.click()
        XCTAssertEqual(showNotch.value as? String, originalValue)

        let integrationsTab = app.buttons["Integrations"]
        XCTAssertTrue(integrationsTab.waitForExistence(timeout: 5))
        integrationsTab.click()
        XCTAssertTrue(app.descendants(matching: .any)["settings-integrations"].waitForExistence(timeout: 5))

        let aboutTab = app.buttons["About"]
        XCTAssertTrue(aboutTab.waitForExistence(timeout: 5))
        aboutTab.click()
        XCTAssertTrue(app.descendants(matching: .any)["settings-about"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testCanCollapseBackToCompactNotch() throws {
        let app = launchApp()
        expand(app)

        app.buttons["module-nowPlaying"].rightClick()
        let collapseButton = app.menuItems["Collapse notch"]
        XCTAssertTrue(collapseButton.waitForExistence(timeout: 5))
        collapseButton.click()
        XCTAssertTrue(app.buttons["collapsed-notch"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testDoubleClickCloseHandleCollapsesExpandedNotch() throws {
        let app = launchApp()
        expand(app)

        let closeHandle = app.descendants(matching: .any)["double-click-close-handle"]
        XCTAssertTrue(closeHandle.waitForExistence(timeout: 5))
        closeHandle.doubleClick()
        XCTAssertTrue(app.buttons["collapsed-notch"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testSoundOutputMenuSwitchesAndRestoresDevice() throws {
        let app = launchApp()
        expand(app)

        let controlsButton = app.buttons["module-controls"]
        XCTAssertTrue(controlsButton.waitForExistence(timeout: 5), "Controls module button should exist")
        controlsButton.click()

        let controlsPanel = app.descendants(matching: .any)["controls-panel"]
        XCTAssertTrue(controlsPanel.waitForExistence(timeout: 5), "Controls pane should appear")

        // Capture initial Controls screenshot
        let controlsAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        controlsAttachment.name = "Controls-Pane-Initial"
        controlsAttachment.lifetime = .keepAlways
        add(controlsAttachment)

        let soundMenu = controlsPanel.descendants(matching: .any)["sound-output-menu"]
        XCTAssertTrue(soundMenu.waitForExistence(timeout: 5), "Sound output menu should exist")

        // Verify initial selection is non-empty before touching route
        let initialSoundValue = (soundMenu.value as? String) ?? ""
        XCTAssertFalse(initialSoundValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Initial sound output selection must be non-empty")

        // Open menu to inspect items
        soundMenu.click()

        let menuAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        menuAttachment.name = "Sound-Output-Menu-Open"
        menuAttachment.lifetime = .keepAlways
        add(menuAttachment)

        // Find available menu items scoped strictly to the sound output menu
        let audioDevicePredicate = NSPredicate(format: "identifier BEGINSWITH %@", "audio-device-")
        let soundMenuItems = soundMenu.descendants(matching: .menuItem).matching(audioDevicePredicate)
        let menuItems = soundMenuItems.allElementsBoundByIndex
        var outputNames: [String] = []
        for item in menuItems {
            let label = item.title.isEmpty ? item.label : item.title
            if !label.isEmpty && label != "No Output Devices Found" {
                outputNames.append(label)
            }
        }

        // Verify menu enumeration returns at least one actual output
        XCTAssertFalse(outputNames.isEmpty, "Sound output menu must enumerate at least one actual output device")

        // Verify exclusion of microphone, camera, and private spectrum
        for name in outputNames {
            let lower = name.lowercased()
            XCTAssertFalse(lower.contains("microphone"), "Microphone must be excluded from sound output menu: \(name)")
            XCTAssertFalse(lower.contains("camera"), "Camera audio must be excluded from sound output menu: \(name)")
            XCTAssertFalse(lower.contains("private spectrum"), "Private spectrum must be excluded: \(name)")
            XCTAssertFalse(lower.contains("notch system audio spectrum"), "Spectrum aggregate must be excluded: \(name)")
        }

        // Filter valid alternative real outputs: avoid virtual aggregate/Teams endpoints
        let candidates = outputNames.filter { name in
            let lower = name.lowercased()
            return !lower.contains("microsoft teams") && name != initialSoundValue
        }

        // Prefer monitor HDMI/MAG or MacBook built-in
        let alternative = candidates.first { name in
            let lower = name.lowercased()
            return lower.contains("hdmi") || lower.contains("mag") || lower.contains("macbook") || lower.contains("built-in") || lower.contains("speakers")
        } ?? candidates.first

        if let targetDeviceName = alternative {
            defer {
                let currentVal = (soundMenu.value as? String) ?? ""
                if currentVal != initialSoundValue {
                    soundMenu.click()
                    let restoreItem = soundMenu.descendants(matching: .menuItem)
                        .matching(audioDevicePredicate)
                        .matching(NSPredicate(format: "title == %@ OR label == %@", initialSoundValue, initialSoundValue))
                        .firstMatch
                    if restoreItem.waitForExistence(timeout: 3) {
                        restoreItem.click()
                    } else {
                        soundMenu.typeKey(.escape, modifierFlags: [])
                    }
                    let restorePredicate = NSPredicate(format: "value == %@", initialSoundValue)
                    let restoreExpectation = XCTNSPredicateExpectation(predicate: restorePredicate, object: soundMenu)
                    _ = XCTWaiter().wait(for: [restoreExpectation], timeout: 5)
                }
            }

            // Switch to target device from the already-open menu
            let targetItem = soundMenu.descendants(matching: .menuItem)
                .matching(audioDevicePredicate)
                .matching(NSPredicate(format: "title == %@ OR label == %@", targetDeviceName, targetDeviceName))
                .firstMatch
            XCTAssertTrue(targetItem.waitForExistence(timeout: 3), "Target device item \(targetDeviceName) should exist in menu")
            targetItem.click()

            // Verify sound menu value updates
            let switchedPredicate = NSPredicate(format: "value == %@", targetDeviceName)
            let expectation = XCTNSPredicateExpectation(predicate: switchedPredicate, object: soundMenu)
            let switchResult = XCTWaiter().wait(for: [expectation], timeout: 5)
            XCTAssertEqual(switchResult, .completed, "Sound output menu should update to \(targetDeviceName)")

            // If HDMI or fixed device, require both slider and mute exist and are disabled
            if targetDeviceName.lowercased().contains("hdmi") || targetDeviceName.lowercased().contains("mag") {
                let muteButton = controlsPanel.descendants(matching: .any)["mute-button"]
                XCTAssertTrue(muteButton.waitForExistence(timeout: 3), "Mute button should exist for fixed HDMI device")
                let muteDisabledPredicate = NSPredicate(format: "isEnabled == false")
                let muteDisabledExpectation = XCTNSPredicateExpectation(predicate: muteDisabledPredicate, object: muteButton)
                XCTAssertEqual(XCTWaiter().wait(for: [muteDisabledExpectation], timeout: 5), .completed, "Mute should be disabled for fixed HDMI device")

                let volumeSlider = controlsPanel.sliders["Volume"]
                XCTAssertTrue(volumeSlider.waitForExistence(timeout: 3), "Volume slider should exist for fixed HDMI device")
                let sliderDisabledPredicate = NSPredicate(format: "isEnabled == false")
                let sliderDisabledExpectation = XCTNSPredicateExpectation(predicate: sliderDisabledPredicate, object: volumeSlider)
                XCTAssertEqual(XCTWaiter().wait(for: [sliderDisabledExpectation], timeout: 5), .completed, "Volume slider should be disabled for fixed HDMI device")

                let fixedAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                fixedAttachment.name = "Fixed-Volume-Endpoint"
                fixedAttachment.lifetime = .keepAlways
                add(fixedAttachment)
            }

            // Restore original device
            soundMenu.click()
            let originalItem = soundMenu.descendants(matching: .menuItem)
                .matching(audioDevicePredicate)
                .matching(NSPredicate(format: "title == %@ OR label == %@", initialSoundValue, initialSoundValue))
                .firstMatch
            XCTAssertTrue(originalItem.waitForExistence(timeout: 3), "Original device item \(initialSoundValue) should exist")
            originalItem.click()

            // Verify restored selection
            let restorePredicate = NSPredicate(format: "value == %@", initialSoundValue)
            let restoreExpectation = XCTNSPredicateExpectation(predicate: restorePredicate, object: soundMenu)
            let restoreResult = XCTWaiter().wait(for: [restoreExpectation], timeout: 5)
            XCTAssertEqual(restoreResult, .completed, "Sound output menu should restore to \(initialSoundValue)")
        } else {
            XCTFail("No alternative real sound output device available to switch to (found: \(outputNames.joined(separator: ", ")))")
        }

        // Capture compact layout screenshot
        let compactAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        compactAttachment.name = "Controls-Compact-Layout"
        compactAttachment.lifetime = .keepAlways
        add(compactAttachment)

        // Helper closures for Settings window
        func openSettings() -> XCUIElement {
            app.buttons["module-nowPlaying"].rightClick()
            let settingsButton = app.descendants(matching: .any)["settings-button"]
            if settingsButton.waitForExistence(timeout: 3) {
                settingsButton.click()
            }
            let settingsWindow = app.windows["General"]
            _ = settingsWindow.waitForExistence(timeout: 3)
            return settingsWindow
        }

        func closeSettings() {
            let settingsWindow = app.windows["General"]
            if settingsWindow.waitForExistence(timeout: 2) {
                let closeBtn = settingsWindow.buttons[XCUIIdentifierCloseWindow]
                if closeBtn.exists {
                    closeBtn.click()
                }
            }
        }

        func ensureControlsActive() {
            let collapsedNotch = app.buttons["collapsed-notch"]
            if collapsedNotch.exists {
                expand(app)
            }
            let controlsBtn = app.buttons["module-controls"]
            if controlsBtn.waitForExistence(timeout: 3) {
                controlsBtn.click()
            }
            XCTAssertTrue(controlsPanel.waitForExistence(timeout: 5), "Controls pane should be visible")
        }

        func verifyFooterContained() {
            let footerIdentifiers = ["mute-button", "sound-settings-button", "refresh-controls-button"]
            let controlsFrame = controlsPanel.frame
            for id in footerIdentifiers {
                let btn = controlsPanel.descendants(matching: .any)[id]
                XCTAssertTrue(btn.waitForExistence(timeout: 3), "Footer button \(id) should exist")
                let btnFrame = btn.frame
                XCTAssertTrue(btnFrame.width > 0 && btnFrame.height > 0, "Footer button \(id) should have positive dimensions")
                XCTAssertTrue(btnFrame.minX >= controlsFrame.minX - 1 && btnFrame.maxX <= controlsFrame.maxX + 1, "Footer button \(id) x bounds should lie within controls panel")
                XCTAssertTrue(btnFrame.minY >= controlsFrame.minY - 1 && btnFrame.maxY <= controlsFrame.maxY + 1, "Footer button \(id) y bounds should lie within controls panel")
            }
        }

        // Inspect initial preset from Settings
        _ = openSettings()
        let sizePicker = app.descendants(matching: .any)["settings-notch-size"]
        XCTAssertTrue(sizePicker.waitForExistence(timeout: 3), "Settings notch size picker should exist")

        var originalPreset: String? = nil
        for presetName in ["Compact", "Standard", "Roomy"] {
            let radio = sizePicker.radioButtons[presetName]
            if radio.exists, (radio.value as? Int == 1 || radio.isSelected) {
                originalPreset = presetName
                break
            }
        }
        closeSettings()

        guard let initialPreset = originalPreset else {
            XCTFail("Failed to detect original notch size preset from Settings")
            return
        }

        var currentPreset = initialPreset
        defer {
            if currentPreset != initialPreset {
                _ = openSettings()
                let picker = app.descendants(matching: .any)["settings-notch-size"]
                if picker.waitForExistence(timeout: 3) {
                    let restoreRadio = picker.radioButtons[initialPreset]
                    if restoreRadio.exists {
                        restoreRadio.click()
                    }
                }
                closeSettings()
            }
        }

        // For each Compact/Standard/Roomy: open Settings, select preset, close Settings, expand Controls if needed, verify footer contained, screenshot actual Controls
        for presetName in ["Compact", "Standard", "Roomy"] {
            _ = openSettings()
            let picker = app.descendants(matching: .any)["settings-notch-size"]
            XCTAssertTrue(picker.waitForExistence(timeout: 3), "Settings notch size picker should exist")
            let radio = picker.radioButtons[presetName]
            XCTAssertTrue(radio.waitForExistence(timeout: 3), "Radio button \(presetName) should exist")
            radio.click()
            currentPreset = presetName
            closeSettings()

            ensureControlsActive()

            XCTAssertTrue(controlsPanel.frame.size.width > 0, "Controls width should be positive in \(presetName)")
            XCTAssertTrue(controlsPanel.frame.size.height > 0, "Controls height should be positive in \(presetName)")

            verifyFooterContained()

            let presetAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            presetAttachment.name = "Controls-Layout-\(presetName)"
            presetAttachment.lifetime = .keepAlways
            add(presetAttachment)
        }

        // Restore original preset
        _ = openSettings()
        let picker = app.descendants(matching: .any)["settings-notch-size"]
        XCTAssertTrue(picker.waitForExistence(timeout: 3), "Settings notch size picker should exist")
        let restoreRadio = picker.radioButtons[initialPreset]
        XCTAssertTrue(restoreRadio.waitForExistence(timeout: 3), "Original preset radio button \(initialPreset) should exist")
        restoreRadio.click()
        currentPreset = initialPreset
        closeSettings()

        ensureControlsActive()
        verifyFooterContained()
    }

    @MainActor
    func testRepeatedLaunchIsStable() throws {
        for _ in 0..<3 {
            let app = launchApp()
            XCTAssertTrue(app.buttons["collapsed-notch"].waitForExistence(timeout: 5))
            app.terminate()
        }
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        return app
    }

    @MainActor
    private func expand(_ app: XCUIApplication) {
        let collapsed = app.buttons["collapsed-notch"]
        XCTAssertTrue(collapsed.waitForExistence(timeout: 10))
        // Click on the left-wing coordinate of the collapsed notch to avoid physical camera housing
        let leftWing = collapsed.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))
        leftWing.click()
        XCTAssertTrue(app.buttons["module-nowPlaying"].waitForExistence(timeout: 10))
    }

    @MainActor
    private func waitForModule(_ app: XCUIApplication, identifier: String) {
        XCTAssertTrue(
            app.descendants(matching: .any)[identifier].waitForExistence(timeout: 5),
            "Expected module \(identifier) to appear"
        )
    }
}
