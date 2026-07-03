// MARK: - MenuBarController.swift
// Menu bar controller that manages NSStatusItem and NSMenu.
// Created and retained by AppDelegate.
// - NSStatusItem.button.image: dynamic SwiftUI ImageRenderer output.
// - NSMenu: dashboard rows use NSHostingView; other entries are standard NSMenuItem values.

import AppKit
import Combine
import SwiftUI

// MARK: - MenuBarIconCacheKey

/// Cache key describing the inputs used to render the menu bar icon.
/// When unchanged from the previous render, ImageRenderer work is skipped.
private struct MenuBarIconCacheKey: Equatable {
    struct ProviderEntry: Equatable {
        let provider: UsageProvider
        let fetchedAt: Date?
        let isEnabled: Bool
    }
    let providers: [ProviderEntry]
    let displayMode: UsageDisplayMode
    let colorScheme: ColorScheme
}

@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let appState: AppSharedState
    private var cancellables: Set<AnyCancellable> = []
    private var appearanceObservation: NSKeyValueObservation?
    private var debounceTask: Task<Void, Never>?
    private static let debounceMs: UInt64 = 300
    private var lastIconCacheKey: MenuBarIconCacheKey?
    // Keep the same instance for addObserver/removeObserver.
    // nonisolated(unsafe): accessed from nonisolated deinit.
    nonisolated(unsafe) private var observedAppGroupDefaults: UserDefaults?

    // Dashboard host views, reused by updating rootView.
    private var dashboardHostViews: [UsageProvider: NSHostingView<DashboardMenuItemView>] = [:]

    /// True while the icon is temporarily revealed after the app is reopened.
    private var isTemporarilyRevealed = false

    init(appState: AppSharedState) {
        self.appState = appState
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureButton()
        buildMenu()
        observeChanges()
        applyIconVisibility()
    }

    // MARK: - Icon Visibility

    /// Applies the persisted icon-hidden setting unless a temporary reveal is active.
    private func applyIconVisibility() {
        let isHidden = UserDefaults.standard.bool(forKey: UserDefaultsKeys.menuBarIconHidden)
        statusItem.isVisible = !(isHidden && !isTemporarilyRevealed)
    }

    /// Temporarily shows the icon after reopening the app when the icon is normally hidden.
    func temporarilyRevealForReopen() {
        let isHidden = UserDefaults.standard.bool(forKey: UserDefaultsKeys.menuBarIconHidden)
        guard isHidden else { return }
        isTemporarilyRevealed = true
        applyIconVisibility()
    }

    /// Ends temporary visibility when the settings window closes.
    func endTemporaryRevealIfNeeded() {
        guard isTemporarilyRevealed else { return }
        isTemporarilyRevealed = false
        applyIconVisibility()
    }

    // MARK: - Button (Menu Bar Icon)

    private func configureButton() {
        statusItem.button?.imageScaling = .scaleProportionallyDown
        statusItem.button?.imagePosition = .imageOnly
        updateButtonImage()
    }

    private func updateButtonImage() {
        let snapshots = appState.viewModel.snapshots
        let displayMode = loadDisplayMode()
        let colorScheme = resolveButtonColorScheme()
        let orderedProviders = ProviderOrderStore.loadProviderOrder()

        // Skip ImageRenderer when render inputs have not changed.
        let cacheKey = MenuBarIconCacheKey(
            providers: orderedProviders.map { provider in
                MenuBarIconCacheKey.ProviderEntry(
                    provider: provider,
                    fetchedAt: isMenuBarEnabled(provider) ? snapshots[provider]?.fetchedAt : nil,
                    isEnabled: isMenuBarEnabled(provider)
                )
            },
            displayMode: displayMode,
            colorScheme: colorScheme
        )
        guard cacheKey != lastIconCacheKey else { return }
        lastIconCacheKey = cacheKey

        // Resolve ImageRenderer colors from the menu bar button's current appearance.
        let orderedSnapshots = orderedProviders.map { provider in
            (provider: provider, snapshot: isMenuBarEnabled(provider) ? snapshots[provider] : nil)
        }
        let content = MenuBarLabelContentView(
            orderedSnapshots: orderedSnapshots,
            displayMode: displayMode
        )
        .environment(\.colorScheme, colorScheme)

        let renderer = ImageRenderer(content: content.fixedSize())
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        if let image = renderer.nsImage {
            image.isTemplate = true
            statusItem.button?.image = image
        } else {
            let image = NSImage(resource: .menuBarIcon)
            image.isTemplate = true
            statusItem.button?.image = image
        }
    }

    private func isMenuBarEnabled(_ provider: UsageProvider) -> Bool {
        let defaults = UserDefaults.standard
        switch provider {
        case .chatgptCodex: return defaults.bool(forKey: UserDefaultsKeys.menuBarStatusCodexEnabled)
        case .claudeCode: return defaults.bool(forKey: UserDefaultsKeys.menuBarStatusClaudeEnabled)
        case .githubCopilot: return defaults.bool(forKey: UserDefaultsKeys.menuBarStatusCopilotEnabled)
        }
    }

    private func loadDisplayMode() -> UsageDisplayMode {
        UsageDisplayMode.makeSelectableMode(
            from: UserDefaults.standard.string(forKey: UserDefaultsKeys.displayMode)
        )
    }

    // MARK: - Menu Construction

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
    }

    // MARK: - Change Observation

    private func observeChanges() {
        appState.viewModel.objectWillChange
            .sink { [weak self] _ in self?.scheduleImageUpdate() }
            .store(in: &cancellables)

        // Observe only the keys that affect icon rendering instead of all UserDefaults changes.
        for key in [
            UserDefaultsKeys.displayMode,
            UserDefaultsKeys.menuBarStatusCodexEnabled,
            UserDefaultsKeys.menuBarStatusClaudeEnabled,
            UserDefaultsKeys.menuBarStatusCopilotEnabled,
            UserDefaultsKeys.providerDisplayOrder,
            UserDefaultsKeys.menuBarIconHidden,
        ] {
            UserDefaults.standard.addObserver(self, forKeyPath: key, options: [.new], context: nil)
        }
        // Retain the same instance used by addObserver/removeObserver.
        let appGroupDefaults = AppGroupDefaults.shared
        observedAppGroupDefaults = appGroupDefaults
        for key in [
            SharedUserDefaultsKeys.showAbsoluteSpendAmount,
            SharedUserDefaultsKeys.showDailySpendLeft,
        ] {
            appGroupDefaults?.addObserver(self, forKeyPath: key, options: [.new], context: nil)
        }

        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.scheduleImageUpdate() }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .sink { [weak self] _ in self?.scheduleImageUpdate() }
            .store(in: &cancellables)

        DistributedNotificationCenter.default()
            .publisher(for: Notification.Name("AppleInterfaceThemeChangedNotification"))
            .sink { [weak self] _ in self?.scheduleImageUpdate() }
            .store(in: &cancellables)

        appearanceObservation = statusItem.button?.observe(
            \.effectiveAppearance,
            options: [.new]
        ) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.scheduleImageUpdate()
            }
        }
    }

    // KVO callback for the specific observed keys.
    nonisolated override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        // Inline strings because this nonisolated context cannot access @MainActor type members.
        let iconVisibilityKey = "menu_bar_icon_hidden"
        let imageObservedKeys = [
            "usage_display_mode", "menu_bar_status_codex_enabled",
            "menu_bar_status_claude_enabled", "menu_bar_status_copilot_enabled",
            "provider_display_order",
            "usage_show_absolute_spend_amount", "usage_show_daily_spend_left",
        ]
        guard let keyPath else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }
        if keyPath == iconVisibilityKey {
            Task { @MainActor [weak self] in
                self?.applyIconVisibility()
            }
            return
        }
        guard imageObservedKeys.contains(keyPath) else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }
        // Invalidate the cache and force redraw for settings changes.
        Task { @MainActor [weak self] in
            self?.lastIconCacheKey = nil
            self?.scheduleImageUpdate()
        }
    }

    deinit {
        let standardKeys = [
            "usage_display_mode", "menu_bar_status_codex_enabled",
            "menu_bar_status_claude_enabled", "menu_bar_status_copilot_enabled",
            "provider_display_order", "menu_bar_icon_hidden",
        ]
        for key in standardKeys {
            UserDefaults.standard.removeObserver(self, forKeyPath: key)
        }
        // Remove observers from the same instance used to add them.
        let appGroupKeys = [
            "usage_show_absolute_spend_amount", "usage_show_daily_spend_left",
        ]
        for key in appGroupKeys {
            observedAppGroupDefaults?.removeObserver(self, forKeyPath: key)
        }
    }

    private func scheduleImageUpdate() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.debounceMs * 1_000_000)
            guard !Task.isCancelled else { return }
            updateButtonImage()
        }
    }

    private func resolveButtonColorScheme() -> ColorScheme {
        let appearance = statusItem.button?.effectiveAppearance ?? NSApp.effectiveAppearance
        let matched = appearance.bestMatch(from: [
            .darkAqua,
            .aqua,
            .vibrantDark,
            .vibrantLight,
            .accessibilityHighContrastDarkAqua,
            .accessibilityHighContrastAqua
        ])
        switch matched {
        case .darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua:
            return .dark
        default:
            return .light
        }
    }
}

// MARK: - NSMenuDelegate

extension MenuBarController: NSMenuDelegate {
    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        // NSMenuDelegate is called on the main thread, so run synchronously via assumeIsolated.
        MainActor.assumeIsolated {
            self.rebuildMenu(menu)
        }
    }

    @MainActor
    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        // Dashboard rows.
        let displayMode = loadDisplayMode()
        let snapshots = appState.viewModel.snapshots
        let visibleProviders = ProviderOrderStore.loadProviderOrder().filter {
            isDashboardEnabled($0) && snapshots[$0] != nil
        }
        for (index, provider) in visibleProviders.enumerated() {
            guard let snapshot = snapshots[provider] else { continue }
            let item = makeDashboardItem(provider: provider, snapshot: snapshot, displayMode: displayMode)
            menu.addItem(item)
            // Separator between providers, except after the last row.
            if index < visibleProviders.count - 1 {
                menu.addItem(.separator())
            }
        }
        if !visibleProviders.isEmpty {
            menu.addItem(.separator())
        }

        // Open settings.
        menu.addItem(makeActionItem(
            title: "menu.openSettings".localized(),
            image: NSImage(systemSymbolName: "gear", accessibilityDescription: nil),
            action: #selector(openSettings)
        ))
        menu.addItem(.separator())

        // Display mode submenu.
        menu.addItem(makeDisplayModeItem())
        // Language submenu.
        menu.addItem(makeLanguageItem())
        // Wake Up submenu.
        menu.addItem(makeWakeUpItem())
        menu.addItem(.separator())

        // Start at login.
        let loginItem = makeActionItem(
            title: "wakeUp.startAtLogin".localized(),
            image: NSImage(systemSymbolName: "arrow.up.circle", accessibilityDescription: nil),
            action: #selector(toggleLoginItem)
        )
        loginItem.state = LoginItemManager.shared.isEnabled ? .on : .off
        menu.addItem(loginItem)
        menu.addItem(.separator())

        // Check for updates.
        let updateItem = makeActionItem(
            title: "menu.checkForUpdates".localized(),
            image: NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil),
            action: #selector(checkForUpdates)
        )
        updateItem.isEnabled = AppUpdateController.shared.canCheckForUpdates
        menu.addItem(updateItem)
        menu.addItem(.separator())

        // About
        menu.addItem(makeActionItem(
            title: "menu.about".localized(),
            image: NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil),
            action: #selector(showAbout)
        ))
        menu.addItem(.separator())

        // Quit.
        menu.addItem(makeActionItem(
            title: "menu.quit".localized(),
            image: NSImage(systemSymbolName: "power", accessibilityDescription: nil),
            action: #selector(quit)
        ))
    }

    // MARK: - Dashboard Rows

    private func makeDashboardItem(
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        displayMode: UsageDisplayMode
    ) -> NSMenuItem {
        let view = DashboardMenuItemView(
            provider: provider,
            snapshot: snapshot,
            displayMode: displayMode
        )
        let hosting = NSHostingView(rootView: view)
        // Keep transparent so it composites correctly with NSMenu's NSVisualEffectView background.
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear
        // Use the natural height while enforcing a 300px minimum width so the menu is not too narrow.
        let fittingSize = hosting.fittingSize
        hosting.frame = NSRect(x: 0, y: 0, width: max(300, fittingSize.width), height: fittingSize.height)
        hosting.autoresizingMask = [.width]

        let item = NSMenuItem()
        item.view = hosting
        item.isEnabled = true
        return item
    }

    // MARK: - Helpers

    private func makeActionItem(title: String, image: NSImage?, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = image
        item.isEnabled = true
        return item
    }

    private func isDashboardEnabled(_ provider: UsageProvider) -> Bool {
        let defaults = UserDefaults.standard
        switch provider {
        case .chatgptCodex:
            return defaults.object(forKey: UserDefaultsKeys.menuBarDashboardCodexEnabled) as? Bool ?? true
        case .claudeCode:
            return defaults.object(forKey: UserDefaultsKeys.menuBarDashboardClaudeEnabled) as? Bool ?? true
        case .githubCopilot:
            return defaults.object(forKey: UserDefaultsKeys.menuBarDashboardCopilotEnabled) as? Bool ?? true
        }
    }

    // MARK: - Submenu: Display Mode

    private func makeDisplayModeItem() -> NSMenuItem {
        let current = loadDisplayMode()
        let sub = NSMenu()
        for mode in UsageDisplayMode.selectableCases {
            let item = NSMenuItem(
                title: mode.localizedDisplayName,
                action: #selector(setDisplayMode(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = mode
            item.state = current == mode ? .on : .off
            sub.addItem(item)
        }
        let parent = NSMenuItem(title: "menu.displayMode".localized(), action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: "eye", accessibilityDescription: nil)
        parent.submenu = sub
        return parent
    }

    // MARK: - Submenu: Language

    private func makeLanguageItem() -> NSMenuItem {
        let languages = LanguageManager.shared.availableLanguages
        let current = LanguageManager.shared.currentLanguage
        let sub = NSMenu()
        for language in languages {
            let item = NSMenuItem(
                title: language.displayName,
                action: #selector(setLanguage(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = language
            item.state = current == language ? .on : .off
            sub.addItem(item)
        }
        let parent = NSMenuItem(title: "menu.language".localized(), action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        parent.submenu = sub
        return parent
    }


    // MARK: - Submenu: Wake Up

    private func makeWakeUpItem() -> NSMenuItem {
        let sub = NSMenu()
        for provider in WakeUpScheduler.supportedProviders {
            let title = "\(provider.displayName) " + "menu.wakeUpNow".localized()
            let item = NSMenuItem(title: title, action: #selector(triggerWakeUp(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = provider
            sub.addItem(item)
        }
        let parent = NSMenuItem(title: "menu.wakeUp".localized(), action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: "alarm", accessibilityDescription: nil)
        parent.submenu = sub
        return parent
    }

    // MARK: - Actions

    @objc private func openSettings() {
        SettingsWindowController.shared.showSettingsWindow()
    }

    @objc private func toggleLoginItem() {
        LoginItemManager.shared.setEnabled(!LoginItemManager.shared.isEnabled)
    }

    @objc private func checkForUpdates() {
        AppUpdateController.shared.checkForUpdates()
    }

    @objc private func showAbout() {
        let options: [NSApplication.AboutPanelOptionKey: Any] = [
            .credits: makeAboutCredits()
        ]
        NSApp.orderFrontStandardAboutPanel(options: options)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeAboutCredits() -> NSAttributedString {
        let copyright = resolveAboutCopyright()
        let repositoryURLString = "https://products.desireforwealth.com/products/agentlimits"
        let creditsText = "\(copyright)\nWebsite: \(repositoryURLString)"
        let attributed = NSMutableAttributedString(string: creditsText)
        let linkRange = (creditsText as NSString).range(of: repositoryURLString)
        attributed.addAttribute(.link, value: repositoryURLString, range: linkRange)
        return attributed
    }

    private func resolveAboutCopyright() -> String {
        if let value = Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String,
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value
        }
        return "Copyright © 2025-2026 Nihondo"
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    @objc private func setDisplayMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? UsageDisplayMode else { return }
        let displayMode = mode.normalizedSelectableMode
        UserDefaults.standard.set(displayMode.rawValue, forKey: UserDefaultsKeys.displayMode)
        appState.viewModel.updateDisplayMode(displayMode)
    }

    @objc private func setLanguage(_ sender: NSMenuItem) {
        guard let language = sender.representedObject as? AppLanguageOption else { return }
        LanguageManager.shared.setLanguage(language)
    }

    @objc private func triggerWakeUp(_ sender: NSMenuItem) {
        guard let provider = sender.representedObject as? UsageProvider else { return }
        Task { await WakeUpScheduler.shared.triggerWakeUp(for: provider) }
    }
}
