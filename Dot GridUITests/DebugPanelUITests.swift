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
    func testSignedOutFriendsKeepsICloudNote() throws {
        let app = XCUIApplication()
        app.launch()

        let addFriend = app.buttons["add a friend"]
        XCTAssertTrue(addFriend.waitForExistence(timeout: 10), "signed-out launch did not reach the composer")
        addFriend.tap()

        let iCloudNote = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'sign into icloud to send & receive'")
        ).firstMatch
        XCTAssertTrue(iCloudNote.waitForExistence(timeout: 5), "persistent iCloud note missing from friends")
    }

    @MainActor
    func testSimulateOnboardingFromDebugPanel() throws {
        let app = XCUIApplication()
        app.launch()

        let badge = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == 'profile' OR label == 'settings'")
        ).firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 10), "profile badge missing from top bar")
        badge.press(forDuration: 1.0)

        let simulate = app.buttons["Simulate onboarding"]
        XCTAssertTrue(simulate.waitForExistence(timeout: 5), "simulate onboarding action missing")
        simulate.tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let introCTA = app.buttons["see dotdot in action"]
        XCTAssertTrue(introCTA.waitForExistence(timeout: 5), "onboarding replay did not reach the introduction")
        XCTAssertTrue(introCTA.isHittable, "tap-anywhere did not fast-forward the introduction")
        let hittableCTA = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"),
            object: introCTA
        )
        XCTAssertEqual(XCTWaiter.wait(for: [hittableCTA], timeout: 5), .completed)
        introCTA.tap()

        let modesCTA = app.buttons["make dotdot mine"]
        XCTAssertTrue(modesCTA.waitForExistence(timeout: 5), "onboarding replay did not reach the modes step")
        modesCTA.tap()

        let nameField = app.textFields["your name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "onboarding replay did not reach identity")
        nameField.tap()
        nameField.typeText("debug")
        let identityCTA = app.buttons["that’s me"]
        XCTAssertTrue(identityCTA.waitForExistence(timeout: 5), "identity action missing")
        identityCTA.tap()

        let solo = app.buttons["try it with myself first"]
        if !solo.waitForExistence(timeout: 2) { app.swipeUp() }
        XCTAssertTrue(solo.waitForExistence(timeout: 5), "signed-out replay could not continue solo")
        solo.tap()

        let skipWidget = app.buttons["i’ll do it later"]
        XCTAssertTrue(skipWidget.waitForExistence(timeout: 5), "onboarding replay did not reach widget education")
        skipWidget.tap()

        XCTAssertTrue(app.buttons["add a friend"].waitForExistence(timeout: 5), "finishing the replay did not restore the composer")
    }

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
