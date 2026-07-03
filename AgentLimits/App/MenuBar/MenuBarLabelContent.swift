// MARK: - MenuBarLabelContent.swift
// SwiftUI content for the menu bar icon.
// Rendered by ImageRenderer and assigned to NSStatusItem.button.image.

import SwiftUI

/// Overall menu bar icon layout with provider statuses arranged horizontally.
struct MenuBarLabelContentView: View {
    /// Ordered (provider, snapshot?) entries. nil snapshots are hidden.
    let orderedSnapshots: [(provider: UsageProvider, snapshot: UsageSnapshot?)]
    let displayMode: UsageDisplayMode

    var body: some View {
        HStack(spacing: 6) {
            if orderedSnapshots.allSatisfy({ $0.snapshot == nil }) {
                Image(.menuBarIcon)
            }
            ForEach(orderedSnapshots, id: \.provider.id) { item in
                if let snapshot = item.snapshot {
                    MenuBarProviderStatusView(
                        primaryWindow: snapshot.primaryWindow,
                        secondaryWindow: snapshot.secondaryWindow,
                        isSingleMonthlyWindow: snapshot.isSingleMonthlyWindow,
                        displayMode: displayMode
                    )
                }
            }
        }
    }
}

/// Menu bar status for one provider.
struct MenuBarProviderStatusView: View {
    let primaryWindow: UsageWindow?
    let secondaryWindow: UsageWindow?
    let isSingleMonthlyWindow: Bool
    let displayMode: UsageDisplayMode

    var body: some View {
        MenuBarPercentLineView(
            primaryWindow: primaryWindow,
            secondaryWindow: secondaryWindow,
            isSingleMonthlyWindow: isSingleMonthlyWindow,
            displayMode: displayMode
        )
    }
}

/// 5h/weekly percentage display row.
struct MenuBarPercentLineView: View {
    let primaryWindow: UsageWindow?
    let secondaryWindow: UsageWindow?
    let isSingleMonthlyWindow: Bool
    let displayMode: UsageDisplayMode
    @AppStorage(UserDefaultsKeys.showAbsoluteSpendAmount, store: AppGroupDefaults.shared)
    private var showAbsoluteSpendAmount = false
    @AppStorage(UserDefaultsKeys.showDailySpendLeft, store: AppGroupDefaults.shared)
    private var showDailySpendLeft = false

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            valueView(primaryWindow)
            if !isSingleMonthlyWindow {
                Text("/")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                valueView(secondaryWindow)
            }
        }
        .monospacedDigit()
        .offset(y: 1.5)
    }

    @ViewBuilder
    private func valueView(_ window: UsageWindow?) -> some View {
        if let window {
            let spendParts = menuBarSpendParts(for: window)
            if spendParts.absolute != nil || spendParts.daily != nil {
                VStack(alignment: .trailing, spacing: -2) {
                    if let absolute = spendParts.absolute {
                        Text(absolute)
                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            .lineLimit(1)
                    }
                    if let daily = spendParts.daily {
                        Text(menuBarDailyText(daily))
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(.primary)
                .minimumScaleFactor(0.8)
            } else {
                Text(menuBarPercentText(for: window))
                    .font(.system(size: 13.5, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(.primary)
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

    private func menuBarDailyText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "/wd", with: "")
            .replacingOccurrences(of: "/d", with: "")
    }
}
