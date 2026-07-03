// MARK: - UpdateSettingsView.swift
// Update settings tab for showing Sparkle update check state and starting manual checks.

import SwiftUI

/// Update settings tab UI.
struct UpdateSettingsView: View {

    let releasesURL: URL

    @ObservedObject private var updateController = AppUpdateController.shared

    var body: some View {
        Form {
            Section {
                currentVersionRow
                lastCheckedRow
            }

            Section {
                checkNowButton
                automaticChecksToggle
            }

            Section {
                releasesLink
            }
        }
        .formStyle(.grouped)
        .navigationTitle("tab.update".localized())
    }

    // MARK: - Rows

    private var currentVersionRow: some View {
        LabeledContent("update.currentVersion".localized()) {
            Text(versionString)
                .foregroundStyle(.secondary)
        }
    }

    private var lastCheckedRow: some View {
        LabeledContent("update.lastChecked".localized()) {
            Text(lastCheckedText)
                .foregroundStyle(.secondary)
        }
    }

    private var checkNowButton: some View {
        Button("update.checkNow".localized()) {
            updateController.checkForUpdates()
        }
        .disabled(!updateController.canCheckForUpdates)
    }

    private var automaticChecksToggle: some View {
        Toggle(
            "update.automaticChecks".localized(),
            isOn: Binding(
                get: { updateController.automaticChecksEnabled },
                set: { updateController.setAutomaticChecksEnabled($0) }
            )
        )
    }

    private var releasesLink: some View {
        Link(destination: releasesURL) {
            HStack {
                Text("update.releasesPage".localized())
                Spacer()
                Image(systemName: "arrow.up.right.square")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Helpers

    private var versionString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(version) (\(build))"
    }

    private var lastCheckedText: String {
        guard let date = updateController.lastUpdateCheckDate else {
            return "update.neverChecked".localized()
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
