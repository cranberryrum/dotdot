//
//  OnboardingStateTests.swift
//  Dot GridTests
//

import Foundation
import Testing
@testable import Dot_Grid

@MainActor
struct OnboardingStateTests {
    private func defaults() -> UserDefaults {
        let name = "OnboardingStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func freshInstallStartsIntroduction() {
        let store = OnboardingStore(defaults: defaults())
        let progress = store.resolveAndPersist(profileExists: false)

        #expect(progress == .fresh)
        #expect(OnboardingDestination.resolve(profileExists: false, progress: progress) == .onboarding)
    }

    @Test func existingProfileMigrationDoesNotReplayOnboarding() {
        let store = OnboardingStore(defaults: defaults())
        let progress = store.resolveAndPersist(profileExists: true)

        #expect(progress == .existingUser)
        #expect(OnboardingDestination.resolve(profileExists: true, progress: progress) == .composer)
    }

    @Test func remoteProfileDiscoveryOverridesPreProfileEducationProgress() {
        let defaults = defaults()
        let store = OnboardingStore(defaults: defaults)
        var progress = OnboardingProgress.fresh
        progress.apply(.finishedIntroduction)
        progress.apply(.finishedModes)
        store.save(progress)

        let afterSignIn = store.resolve(profileExists: true)
        #expect(afterSignIn == .existingUser)
        #expect(OnboardingDestination.resolve(profileExists: true, progress: afterSignIn) == .composer)
    }

    @Test func relaunchAfterProfileCreationResumesAtConnection() {
        let defaults = defaults()
        let store = OnboardingStore(defaults: defaults)
        var progress = store.resolve(profileExists: false)
        progress.apply(.finishedIntroduction)
        progress.apply(.finishedModes)
        progress.apply(.createdProfile)
        store.save(progress)

        let relaunched = OnboardingStore(defaults: defaults).resolve(profileExists: true)
        #expect(relaunched.step == .connection)
        #expect(OnboardingDestination.resolve(profileExists: true, progress: relaunched) == .onboarding)
    }

    @Test func connectedFriendAndSoloBothReachWidgetStep() {
        let base = OnboardingProgress(version: OnboardingProgress.currentVersion, step: .connection)
        var connected = base
        var solo = base

        connected.apply(.connectedFriend)
        solo.apply(.choseSolo)

        #expect(connected.step == .widget)
        #expect(solo.step == .widget)
    }

    @Test func widgetEducationCanFinishOrBeSkipped() {
        let base = OnboardingProgress(version: OnboardingProgress.currentVersion, step: .widget)
        var learned = base
        var skipped = base

        learned.apply(.finishedWidgetEducation)
        skipped.apply(.skippedWidgetEducation)

        #expect(learned.isComplete)
        #expect(skipped.isComplete)
        #expect(OnboardingDestination.resolve(profileExists: true, progress: learned) == .composer)
        #expect(OnboardingDestination.resolve(profileExists: true, progress: skipped) == .composer)
    }

    @Test func firstUseCoachAdvancesOnceAndStaysDismissed() {
        let defaults = defaults()
        let store = ComposerCoachStore(defaults: defaults)

        // Existing installations have no record and should not see a new surprise.
        #expect(store.load().stage == .complete)

        store.begin()
        var coach = store.load()
        #expect(coach.stage == .draw)

        coach.noteDotPlaced()
        store.save(coach)
        #expect(store.load().stage == .send)

        coach.noteSent()
        store.save(coach)
        #expect(store.load().stage == .complete)
        #expect(ComposerCoachStore(defaults: defaults).load().stage == .complete)
    }
}
