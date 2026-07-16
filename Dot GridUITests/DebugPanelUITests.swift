//
//  DebugPanelUITests.swift
//  Dot GridUITests
//
//  Drives the debug panel's widget-preview picker the way a person would:
//  long-press the profile badge, open the panel, flip the picker. The test
//  asserts the UI flow works even with no profile (simulator, signed out) —
//  the App Group write it triggers is checked out-of-band where needed.
//

import XCTest

final class DebugPanelUITests: XCTestCase {

    @MainActor
    func testWidgetPreviewPickerFromDebugPanel() throws {
        let app = XCUIApplication()
        app.launch()

        // The top-bar badge: "profile" when signed out (placeholder slot),
        // "settings" once a profile exists. Long-press opens the debug panel.
        let badge = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == 'profile' OR label == 'settings'")
        ).firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 10), "profile badge missing from top bar")
        badge.press(forDuration: 1.0)

        // The panel is up when its widget-preview picker row is visible. A menu
        // picker is exposed as one button whose label leads with the row title.
        let pickerButton = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Show'")
        ).firstMatch
        XCTAssertTrue(pickerButton.waitForExistence(timeout: 5), "debug panel did not open")

        // Flip the picker (menu style) to the 12×12 dots state. That label is
        // chosen deliberately: "photo"/"doodle" would ALSO match the composer's
        // mode tabs behind the sheet, and XCUITest taps whichever it finds first.
        pickerButton.tap()
        let option = app.buttons["dots 12×12"]
        XCTAssertTrue(option.waitForExistence(timeout: 5), "picker menu did not open")
        option.tap()

        // The row now reports the chosen state.
        let updated = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Show' AND label CONTAINS '12×12'")
        ).firstMatch
        XCTAssertTrue(updated.waitForExistence(timeout: 5), "picker did not take the new value")
    }
}
