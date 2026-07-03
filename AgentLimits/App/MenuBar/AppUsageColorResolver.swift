// MARK: - AppUsageColorResolver.swift
// Usage color resolver for the app target.
// Mirrors AgentLimitsWidget's WidgetUsageColorResolver logic for app-side rendering.

import SwiftUI

/// Utility for resolving menu colors from usage.
enum AppUsageColorResolver {
    /// Returns the status color for usage text: green, orange, or red.
    static func statusColor(
        for window: UsageWindow?,
        provider: UsageProvider,
        windowKind: UsageWindowKind
    ) -> Color {
        guard let window else { return .secondary }
        let thresholds = UsageStatusThresholdStore.loadThresholds(for: provider, windowKind: windowKind)
        let level = UsageStatusLevelResolver.level(
            for: window.usedPercent,
            isRemainingMode: false,
            warningThreshold: thresholds.warningPercent,
            dangerThreshold: thresholds.dangerPercent
        )
        return statusColor(for: level)
    }

    /// Resolves the main bar color level, matching widgets.
    /// Returns threshold level only when `donutUseStatus` is enabled.
    static func barLevel(
        usedPercent: Double?,
        provider: UsageProvider,
        windowKind: UsageWindowKind
    ) -> UsageStatusLevel? {
        let defaults = AppGroupDefaults.shared
        let useStatusColor = defaults?.bool(forKey: UsageColorKeys.donutUseStatus) ?? false
        guard useStatusColor, let usedPercent else { return nil }
        let thresholds = UsageStatusThresholdStore.loadThresholds(for: provider, windowKind: windowKind)
        return UsageStatusLevelResolver.level(
            for: usedPercent,
            isRemainingMode: false,
            warningThreshold: thresholds.warningPercent,
            dangerThreshold: thresholds.dangerPercent
        )
    }

    /// Main usage bar color, following the same rules as the donut outer ring.
    static func barColor(
        usedPercent: Double?,
        provider: UsageProvider,
        windowKind: UsageWindowKind
    ) -> Color {
        if let level = barLevel(usedPercent: usedPercent, provider: provider, windowKind: windowKind) {
            return statusColor(for: level)
        }
        return resolveStoredColor(for: UsageColorKeys.donut, defaultColor: .accentColor)
    }

    private static func statusColor(for level: UsageStatusLevel) -> Color {
        switch level {
        case .green:
            return resolveStoredColor(for: UsageColorKeys.statusGreen, defaultColor: .green)
        case .orange:
            return resolveStoredColor(for: UsageColorKeys.statusOrange, defaultColor: .orange)
        case .red:
            return resolveStoredColor(for: UsageColorKeys.statusRed, defaultColor: .red)
        }
    }

    private static func resolveStoredColor(for key: String, defaultColor: Color) -> Color {
        let defaults = AppGroupDefaults.shared
        let storedValue = defaults?.string(forKey: key)
        return ColorHexCodec.resolveColor(from: storedValue, defaultColor: defaultColor)
    }
}
