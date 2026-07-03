// MARK: - SettingsWindowController.swift
// AppKit-managed settings window for the menu bar app.
// Creates the SwiftUI settings view only when the user opens settings.

import AppKit
import SwiftUI

/// AppKit controller that creates and shows the settings window on demand.
@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private static let settingsWindowIdentifier = NSUserInterfaceItemIdentifier("settings")
    private let appState = AppSharedState.shared
    private var windowCloseObservation: NSObjectProtocol?

    private init() {
        super.init(window: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Shows the settings window, bringing an existing one to the front.
    func showSettingsWindow() {
        prepareSettingsState()

        if window == nil {
            let newWindow = makeSettingsWindow()
            window = newWindow
            observeWindowClose(newWindow)
        }

        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Notifies app state when the settings window closes so temporary icon visibility can end.
    private func observeWindowClose(_ window: NSWindow) {
        windowCloseObservation = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.appState.onSettingsWindowClosed?()
            }
        }
    }

    private func prepareSettingsState() {
        appState.viewModel.updateDisplayMode(
            UsageDisplayMode.makeSelectableMode(
                from: UserDefaults.standard.string(forKey: UserDefaultsKeys.displayMode)
            )
        )
        appState.startBackgroundRefresh()
        LoginItemManager.shared.updateStatus()
        _ = AppUpdateController.shared
    }

    private func makeSettingsWindow() -> NSWindow {
        let rootView = SettingsTabView(
            viewModel: appState.viewModel,
            webViewPool: appState.webViewPool,
            tokenUsageViewModel: appState.tokenUsageViewModel
        )
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "window.settings.title".localized()
        window.identifier = Self.settingsWindowIdentifier
        window.styleMask = [.titled, .closable, .resizable]
        window.minSize = NSSize(
            width: DesignTokens.WindowSize.minWidth,
            height: DesignTokens.WindowSize.minHeight
        )
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.center()
        return window
    }
}
