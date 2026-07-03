// MARK: - AppUpdateController.swift
// Singleton wrapper around the Sparkle updater.
// Sparkle handles launch and 24-hour automatic checks according to Info.plist settings.

import Combine
import Sparkle

/// Wraps Sparkle's SPUStandardUpdaterController and exposes state to SwiftUI.
@MainActor
final class AppUpdateController: ObservableObject {

    static let shared = AppUpdateController()

    let updater: SPUUpdater

    private let controller: SPUStandardUpdaterController

    /// Whether update checks are currently available, mirrored from Sparkle KVO.
    @Published var canCheckForUpdates: Bool

    /// Last update check date, mirrored from Sparkle KVO.
    @Published var lastUpdateCheckDate: Date?

    /// Launch and scheduled update check flag.
    @Published var automaticChecksEnabled: Bool

    private var cancellables = Set<AnyCancellable>()

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        updater = controller.updater
        canCheckForUpdates = updater.canCheckForUpdates
        lastUpdateCheckDate = updater.lastUpdateCheckDate
        automaticChecksEnabled = updater.automaticallyChecksForUpdates

        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)

        updater.publisher(for: \.lastUpdateCheckDate)
            .receive(on: DispatchQueue.main)
            .assign(to: &$lastUpdateCheckDate)
    }

    /// Starts a manual update check.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Toggles launch and scheduled update checks.
    func setAutomaticChecksEnabled(_ enabled: Bool) {
        updater.automaticallyChecksForUpdates = enabled
        automaticChecksEnabled = enabled
    }
}
