//
//  PhotoStickers.swift
//  Dot Grid
//
//  Photo-widget stickers: time, place, and weather pills the user drops on a photo
//  before sending. They're baked INTO the sent JPEG (see PhotoComposerView's
//  renderer), so the widget needs no changes — what you frame is what they see.
//  A time/weather pill is therefore frozen at send, like a stamp on a postcard.
//

import CoreLocation
import SwiftUI
import WeatherKit

// MARK: - Model

enum StickerKind: String, Identifiable, CaseIterable {
    case time, location, weather
    var id: String { rawValue }

    /// Tray label + the icon shown before live data resolves.
    var trayLabel: String {
        switch self {
        case .time: "time"
        case .location: "place"
        case .weather: "weather"
        }
    }
    var defaultIcon: String {
        switch self {
        case .time: "clock.fill"
        case .location: "mappin.and.ellipse"
        case .weather: "cloud.sun.fill"
        }
    }
}

/// A placed sticker. `position` is normalized (0...1) within the square frame so it
/// scales cleanly from the on-screen frame to the high-res baked image.
struct PhotoSticker: Identifiable {
    let id = UUID()
    let kind: StickerKind
    var icon: String
    var text: String
    var position: CGPoint = CGPoint(x: 0.5, y: 0.5)
}

enum StickerError: Error { case locationDenied, noLocation }

// MARK: - Chip (used on-screen AND in the baked render — one source of truth)

struct StickerChip: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .bold))
            Text(text)
                .font(.custom("HankenGrotesk-Regular", size: 16).weight(.semibold))
                .textCase(.lowercase)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .background(
            Capsule(style: .continuous)
                .fill(.black.opacity(0.42))
                .overlay(Capsule(style: .continuous).strokeBorder(.white.opacity(0.22), lineWidth: 1))
        )
        // A soft shadow keeps the pill legible over busy photos (renders in ImageRenderer).
        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
        .fixedSize()
    }
}

// MARK: - Location (one-shot, when-in-use)

@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var locationConts: [CheckedContinuation<CLLocation, Error>] = []
    private var authCont: CheckedContinuation<CLAuthorizationStatus, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer   // city-level is plenty
    }

    /// Resolve a single current location, prompting for permission the first time.
    func current() async throws -> CLLocation {
        var status = manager.authorizationStatus
        if status == .notDetermined {
            status = await withCheckedContinuation { cont in
                authCont = cont
                manager.requestWhenInUseAuthorization()
            }
        }
        guard status == .authorizedWhenInUse || status == .authorizedAlways else {
            throw StickerError.locationDenied
        }
        return try await withCheckedThrowingContinuation { cont in
            locationConts.append(cont)
            manager.requestLocation()
        }
    }

    /// A place name (city, then a sensible fallback) for a location.
    func placeName(for location: CLLocation) async -> String {
        let marks = try? await CLGeocoder().reverseGeocodeLocation(location)
        let m = marks?.first
        return (m?.locality ?? m?.subLocality ?? m?.administrativeArea ?? m?.name ?? "here")
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            guard status != .notDetermined, let cont = authCont else { return }
            authCont = nil
            cont.resume(returning: status)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            guard let loc = locations.last else { return }
            let conts = locationConts; locationConts = []
            conts.forEach { $0.resume(returning: loc) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            let conts = locationConts; locationConts = []
            conts.forEach { $0.resume(throwing: error) }
        }
    }
}

// MARK: - Weather (WeatherKit)

enum WeatherProvider {
    /// Current conditions for a location → (SF Symbol name, short temperature string).
    static func current(for location: CLLocation) async throws -> (icon: String, text: String) {
        let weather = try await WeatherService.shared.weather(for: location)
        let now = weather.currentWeather
        let temp = now.temperature.formatted(
            .measurement(width: .narrow, usage: .weather,
                         numberFormatStyle: .number.precision(.fractionLength(0)))
        )
        return (now.symbolName, temp)
    }
}
