// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// Licensed under the MIT License. See LICENSE file in the project root for details.

import XCTest

final class ScreenshotTests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    /// Tap a tab by its label text. Handles both iPhone (bottom tab bar) and iPad (top tab bar) layouts.
    private func selectTab(_ label: String) {
        // iPhone: standard tab bar at the bottom
        let tabButton = app.tabBars.buttons[label]
        if tabButton.waitForExistence(timeout: 2) {
            tabButton.tap()
            return
        }

        // iPad (iOS 18+): tabs render in a top bar as plain buttons, match by label
        let predicate = NSPredicate(format: "label == %@", label)
        let button = app.buttons.matching(predicate).firstMatch
        if button.waitForExistence(timeout: 3) {
            button.tap()
            return
        }

        XCTFail("Tab '\(label)' not found in tab bar or top bar")
    }

    func testCaptureScreenshots() throws {
        let tabs: [(name: String, label: String)] = [
            ("01_Home", "Home"),
            ("02_Config", "Config"),
            ("03_Data", "Data"),
            ("04_Settings", "Settings"),
        ]

        for tab in tabs {
            selectTab(tab.label)

            // Allow UI to settle
            Thread.sleep(forTimeInterval: 1)

            let screenshot = app.windows.firstMatch.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = tab.name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
