//
//  OnboardingState.swift
//  Dot Grid
//
//  One versioned, persisted state machine for the first-run journey. Keeping the
//  transitions here makes relaunch/migration behavior explicit and unit-testable.
//

import Foundation

enum OnboardingStep: String, Codable, CaseIterable {
    case introduction
    case modes
    case identity
    case connection
    case widget
    case complete
}

enum OnboardingAction: Equatable {
    case finishedIntroduction
    case finishedModes
    case createdProfile
    case connectedFriend
    case choseSolo
    case finishedWidgetEducation
    case skippedWidgetEducation
}

struct OnboardingProgress: Codable, Equatable {
    static let currentVersion = 1

    var version: Int
    var step: OnboardingStep

    static let fresh = OnboardingProgress(version: currentVersion, step: .introduction)
    static let existingUser = OnboardingProgress(version: currentVersion, step: .complete)

    var isComplete: Bool { step == .complete }

    mutating func apply(_ action: OnboardingAction) {
        switch (step, action) {
        case (.introduction, .finishedIntroduction):
            step = .modes
        case (.modes, .finishedModes):
            step = .identity
        case (.identity, .createdProfile):
            step = .connection
        case (.connection, .connectedFriend), (.connection, .choseSolo):
            step = .widget
        case (.widget, .finishedWidgetEducation), (.widget, .skippedWidgetEducation):
            step = .complete
        default:
            break
        }
    }
}

enum OnboardingDestination: Equatable {
    case onboarding
    case composer

    static func resolve(profileExists: Bool, progress: OnboardingProgress) -> Self {
        profileExists && progress.isComplete ? .composer : .onboarding
    }
}

struct OnboardingStore {
    static let defaultKey = "dotdot.onboarding.progress"

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    /// Missing state + a profile is the legacy-app migration: that person already
    /// used dotdot, so the new onboarding must not replay. Missing state without a
    /// profile is a genuinely fresh start.
    func resolve(profileExists: Bool) -> OnboardingProgress {
        guard let data = defaults.data(forKey: key),
              var stored = try? JSONDecoder().decode(OnboardingProgress.self, from: data),
              stored.version == OnboardingProgress.currentVersion else {
            return profileExists ? .existingUser : .fresh
        }

        // The app may have shown/advanced the educational steps while iCloud was
        // signed out, before it could discover a returning user's remote profile.
        // A current-flow profile save advances synchronously to `.connection`, so
        // a discovered profile paired with any earlier step is safely legacy.
        if profileExists,
           [.introduction, .modes, .identity].contains(stored.step) {
            return .existingUser
        }

        // A post-profile step cannot function without a profile. This is primarily
        // defensive recovery for a damaged/cleared cache; normal account deletion
        // resets the whole state explicitly.
        if !profileExists,
           [.connection, .widget, .complete].contains(stored.step) {
            stored.step = .identity
        }
        return stored
    }

    @discardableResult
    func resolveAndPersist(profileExists: Bool) -> OnboardingProgress {
        let progress = resolve(profileExists: profileExists)
        save(progress)
        return progress
    }

    func save(_ progress: OnboardingProgress) {
        defaults.set(try? JSONEncoder().encode(progress), forKey: key)
    }

    func reset() {
        defaults.removeObject(forKey: key)
    }
}

enum ComposerCoachStage: String, Codable, Equatable {
    case draw
    case send
    case complete
}

struct ComposerCoachProgress: Codable, Equatable {
    static let currentVersion = 1

    var version: Int
    var stage: ComposerCoachStage

    static let disabled = ComposerCoachProgress(version: currentVersion, stage: .complete)
    static let firstUse = ComposerCoachProgress(version: currentVersion, stage: .draw)

    mutating func noteDotPlaced() {
        if stage == .draw { stage = .send }
    }

    mutating func noteSent() {
        if stage == .send { stage = .complete }
    }
}

struct ComposerCoachStore {
    static let defaultKey = "dotdot.composer.coach"

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    /// No record means this is an existing installation, so do not introduce a
    /// surprise coach. Completing the new onboarding explicitly calls `begin()`.
    func load() -> ComposerCoachProgress {
        guard let data = defaults.data(forKey: key),
              let stored = try? JSONDecoder().decode(ComposerCoachProgress.self, from: data),
              stored.version == ComposerCoachProgress.currentVersion else {
            return .disabled
        }
        return stored
    }

    func begin() {
        save(.firstUse)
    }

    func save(_ progress: ComposerCoachProgress) {
        defaults.set(try? JSONEncoder().encode(progress), forKey: key)
    }

    func reset() {
        defaults.removeObject(forKey: key)
    }
}
