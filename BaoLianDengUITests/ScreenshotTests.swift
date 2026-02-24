// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

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
