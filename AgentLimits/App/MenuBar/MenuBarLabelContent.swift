// MARK: - MenuBarLabelContent.swift
// メニューバーアイコンの SwiftUI コンテンツ。
// ImageRenderer でレンダリングして NSStatusItem.button.image に設定する。

import SwiftUI
import AppKit

/// メニューバーアイコン全体のレイアウト（プロバイダーステータスを横並びで表示）
struct MenuBarLabelContentView: View {
    /// 表示順序付きの (プロバイダ, スナップショット?) 配列。nil は非表示。
    let orderedSnapshots: [(provider: UsageProvider, snapshot: UsageSnapshot?)]
    let displayMode: UsageDisplayMode
    let colorScheme: ColorScheme

    var body: some View {
        HStack(spacing: 6) {
            if orderedSnapshots.allSatisfy({ $0.snapshot == nil }) {
                Image(.menuBarIcon)
            }
            ForEach(orderedSnapshots, id: \.provider.id) { item in
                if let snapshot = item.snapshot {
                    MenuBarProviderStatusView(
                        provider: item.provider,
                        primaryWindow: snapshot.primaryWindow,
                        secondaryWindow: snapshot.secondaryWindow,
                        isSingleMonthlyWindow: snapshot.isSingleMonthlyWindow,
                        displayMode: displayMode,
                        colorScheme: colorScheme
                    )
                }
            }
        }
    }
}

/// 1プロバイダーのメニューバーステータス。
struct MenuBarProviderStatusView: View {
    let provider: UsageProvider
    let primaryWindow: UsageWindow?
    let secondaryWindow: UsageWindow?
    let isSingleMonthlyWindow: Bool
    let displayMode: UsageDisplayMode
    let colorScheme: ColorScheme

    var body: some View {
        MenuBarPercentLineView(
            provider: provider,
            primaryWindow: primaryWindow,
            secondaryWindow: secondaryWindow,
            isSingleMonthlyWindow: isSingleMonthlyWindow,
            displayMode: displayMode,
            colorScheme: colorScheme
        )
    }
}

/// 5h/週次のパーセント表示行。
struct MenuBarPercentLineView: View {
    let provider: UsageProvider
    let primaryWindow: UsageWindow?
    let secondaryWindow: UsageWindow?
    let isSingleMonthlyWindow: Bool
    let displayMode: UsageDisplayMode
    let colorScheme: ColorScheme
    @AppStorage(UsageColorKeys.statusGreen, store: AppGroupDefaults.shared)
    private var statusGreenHex: String = ""
    @AppStorage(UsageColorKeys.statusOrange, store: AppGroupDefaults.shared)
    private var statusOrangeHex: String = ""
    @AppStorage(UsageColorKeys.statusRed, store: AppGroupDefaults.shared)
    private var statusRedHex: String = ""
    @AppStorage(UserDefaultsKeys.showAbsoluteSpendAmount, store: AppGroupDefaults.shared)
    private var showAbsoluteSpendAmount = false
    @AppStorage(UserDefaultsKeys.showDailySpendLeft, store: AppGroupDefaults.shared)
    private var showDailySpendLeft = false

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            valueView(primaryWindow, windowKind: .primary)
            if !isSingleMonthlyWindow {
                Text("/")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                valueView(secondaryWindow, windowKind: .secondary)
            }
        }
        .monospacedDigit()
    }

    @ViewBuilder
    private func valueView(_ window: UsageWindow?, windowKind: UsageWindowKind) -> some View {
        if let window {
            let statusColor = resolveStatusColor(window, windowKind: windowKind)
            let adjustedStatusColor = MenuBarTextColorAdjuster.adjustedColor(
                statusColor,
                for: colorScheme
            )
            let spendParts = menuBarSpendParts(for: window)
            if spendParts.absolute != nil || spendParts.daily != nil {
                VStack(alignment: .trailing, spacing: -2) {
                    if let absolute = spendParts.absolute {
                        Text(absolute)
                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            .lineLimit(1)
                    }
                    if let daily = spendParts.daily {
                        Text(daily)
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .lineLimit(1)
                    }
                }
                .foregroundColor(adjustedStatusColor)
                .minimumScaleFactor(0.8)
            } else {
                Text(menuBarPercentText(for: window))
                    .font(.system(size: 13.5, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundColor(adjustedStatusColor)
            }
        } else {
            Text(UsagePercentFormatter.formatPercentText(nil))
                .font(.system(size: 13.5, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(.secondary)
        }
    }

    private func menuBarSpendParts(for window: UsageWindow) -> (absolute: String?, daily: String?) {
        UsageSpendFormatter.formatEnabledSpendParts(
            for: window,
            displayMode: displayMode.makeDisplayModeRaw(),
            showAbsoluteAmount: showAbsoluteSpendAmount,
            showDailySpendLeft: showDailySpendLeft,
            compact: true
        )
    }

    private func menuBarPercentText(for window: UsageWindow) -> String {
        let percent = displayMode.displayPercent(from: window.usedPercent, window: window)
        return UsagePercentFormatter.formatPercentText(percent)
    }

    private func resolveStatusColor(_ window: UsageWindow?, windowKind: UsageWindowKind) -> Color {
        guard let window else { return .secondary }
        let thresholds = UsageStatusThresholdStore.loadThresholds(for: provider, windowKind: windowKind)
        let level = UsageStatusLevelResolver.level(
            for: window.usedPercent,
            isRemainingMode: false,
            warningThreshold: thresholds.warningPercent,
            dangerThreshold: thresholds.dangerPercent
        )
        switch level {
        case .green: return resolveStoredColor(from: statusGreenHex, defaultColor: .green)
        case .orange: return resolveStoredColor(from: statusOrangeHex, defaultColor: .orange)
        case .red: return resolveStoredColor(from: statusRedHex, defaultColor: .red)
        }
    }

    private func resolveStoredColor(from storedValue: String, defaultColor: Color) -> Color {
        let trimmed = storedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return ColorHexCodec.resolveColor(from: trimmed.isEmpty ? nil : trimmed, defaultColor: defaultColor)
    }
}

private enum MenuBarTextColorAdjuster {
    private static let darkenAmount = 0.3
    private static let lightenAmount = 0.3

    static func adjustedColor(_ color: Color, for colorScheme: ColorScheme) -> Color {
        guard let nsColor = NSColor(color).usingColorSpace(.sRGB) else {
            return color
        }
        let target = colorScheme == .light ? 0.0 : 1.0
        let amount = colorScheme == .light ? darkenAmount : lightenAmount

        return Color(
            .sRGB,
            red: blend(nsColor.redComponent, toward: target, amount: amount),
            green: blend(nsColor.greenComponent, toward: target, amount: amount),
            blue: blend(nsColor.blueComponent, toward: target, amount: amount),
            opacity: Double(nsColor.alphaComponent)
        )
    }

    private static func blend(_ component: CGFloat, toward target: Double, amount: Double) -> Double {
        let value = Double(component)
        return value + ((target - value) * amount)
    }
}
