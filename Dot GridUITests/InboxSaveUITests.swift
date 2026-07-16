//
//  InboxSaveUITests.swift
//  Dot GridUITests
//
//  End-to-end: paint a dot, send it (local-only works signed out), open the
//  inbox's sent feed, save the card to Photos, and watch the chip confirm.
//  Run with photos-add pre-granted (simctl privacy grant photos-add …) so the
//  system prompt doesn't gate the flow.
//

import XCTest

final class InboxSaveUITests: XCTestCase {

    @MainActor
    func testSaveSentDotdotToPhotos() throws {
        let app = XCUIApplication()
        app.launch()

        // Land on the dots composer.
        let dotsTab = app.buttons["dots"]
        XCTAssertTrue(dotsTab.waitForExistence(timeout: 10), "mode toggle missing")
        dotsTab.tap()

        // Paint a couple of dots (the board fills the upper-middle of the screen).
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.35)).tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.38)).tap()

        // Send. Signed out + no friends → recorded as a local-only sent entry.
        // All three composer modes stay mounted, so "send" matches one button per
        // mode — only the active tab's is hittable.
        XCTAssertTrue(app.buttons["send"].firstMatch.waitForExistence(timeout: 5), "send button missing")
        let send = app.buttons.matching(identifier: "send").allElementsBoundByIndex
            .first(where: { $0.isHittable })
        let sendButton = try XCTUnwrap(send, "no hittable send button on the dots tab")
        XCTAssertTrue(sendButton.isEnabled, "send stayed disabled — the board taps missed the grid")
        sendButton.tap()

        // Open the inbox (wordmark) and switch to the sent feed.
        let inbox = app.buttons["dotdot inbox"]
        XCTAssertTrue(inbox.waitForExistence(timeout: 5), "wordmark missing")
        inbox.tap()
        let sentTab = app.buttons["sent"]
        XCTAssertTrue(sentTab.waitForExistence(timeout: 5), "inbox tabs missing")
        sentTab.tap()

        // Save the newest card and wait for the chip to flip to "saved".
        let save = app.buttons["save to photos"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 5), "save chip missing from the sent card")
        save.tap()
        XCTAssertTrue(app.buttons["saved"].firstMatch.waitForExistence(timeout: 10),
                      "save did not confirm — Photos write failed or was denied")
    }
}
