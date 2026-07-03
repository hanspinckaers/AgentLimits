// MARK: - UsageLinearBarView.swift
// Linear progress bar for the menu bar dashboard, matching the widget donut ring behavior.
// Top row: usage bar, segmented when usage exceeds the pacemaker.
// Bottom row: pacemaker bar, split into 5h/weekly/monthly segments with gaps.

import SwiftUI

/// Draws usage and pacemaker progress for one usage window.
struct UsageLinearBarView: View {
    let provider: UsageProvider
    let windowKind: UsageWindowKind
    let window: UsageWindow?
    let displayMode: UsageDisplayMode

    /// Usage bar height, corresponding to the widget outer ring width.
    private let usageBarHeight: CGFloat = 7
    /// Pacemaker bar height, corresponding to the widget inner ring width.
    private let pacemakerBarHeight: CGFloat = 4
    /// Vertical gap between bars.
    private let verticalSpacing: CGFloat = 2
    /// Bar corner radius.
    private let cornerRadius: CGFloat = 2

    var body: some View {
        VStack(alignment: .leading, spacing: verticalSpacing) {
            usageBar
            // Match widgets: show pacemaker only when display-mode adjusted progress exists.
            if displayPacemakerPercent != nil {
                pacemakerBar
            }
        }
    }

    // MARK: - Top Row: Usage Bar

    private var usageBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Background track.
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.secondary.opacity(0.25))

                // Used portion.
                if let segments = pacemakerSegments {
                    segmentedFillView(segments: segments, totalWidth: geo.size.width)
                } else {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(barColor)
                        .frame(width: geo.size.width * usageProgress)
                }
            }
        }
        .frame(height: usageBarHeight)
    }

    /// Segmented fill used when usage exceeds the pacemaker.
    @ViewBuilder
    private func segmentedFillView(segments: PacemakerLinearSegments, totalWidth: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            // Keep ZStack width fixed so offset rectangles are clipped correctly.
            Color.clear.frame(width: totalWidth, height: usageBarHeight)
            // normal: 0..normalEnd, using the main color.
            if segments.normalEnd > 0 {
                Rectangle()
                    .fill(barColor)
                    .frame(width: totalWidth * segments.normalEnd, height: usageBarHeight)
            }
            // warning: warningStart..min(dangerStart, totalEnd), clipped like the widget.
            let warningEnd = min(segments.dangerStart, segments.totalEnd)
            if warningEnd > segments.warningStart {
                Rectangle()
                    .fill(pacemakerWarningColor)
                    .frame(width: totalWidth * (warningEnd - segments.warningStart), height: usageBarHeight)
                    .offset(x: totalWidth * segments.warningStart)
            }
            // danger: dangerStart..totalEnd.
            if segments.totalEnd > segments.dangerStart {
                Rectangle()
                    .fill(pacemakerDangerColor)
                    .frame(width: totalWidth * (segments.totalEnd - segments.dangerStart), height: usageBarHeight)
                    .offset(x: totalWidth * segments.dangerStart)
            }
        }
        .frame(width: totalWidth, height: usageBarHeight)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    // MARK: - Bottom Row: Pacemaker Bar

    private var pacemakerBar: some View {
        GeometryReader { geo in
            let totalWidth = geo.size.width
            let count = divisionCount
            let gapWidth = count > 1 ? totalWidth * LinearDivisionParams.gapFraction : 0
            let segmentWidth = (totalWidth - gapWidth * CGFloat(max(0, count - 1))) / CGFloat(count)

            HStack(spacing: gapWidth) {
                ForEach(0..<count, id: \.self) { index in
                    pacemakerSegmentView(index: index, width: segmentWidth)
                }
            }
        }
        .frame(height: pacemakerBarHeight)
    }

    /// One pacemaker segment with background and progress fill.
    private func pacemakerSegmentView(index: Int, width: CGFloat) -> some View {
        let count = divisionCount
        let segStart = Double(index) / Double(count)
        let segEnd = Double(index + 1) / Double(count)
        let progress = pacemakerProgress
        let fillRatio: Double
        if progress <= segStart {
            fillRatio = 0
        } else if progress >= segEnd {
            fillRatio = 1
        } else {
            fillRatio = (progress - segStart) / (segEnd - segStart)
        }

        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color.secondary.opacity(0.2))
            if fillRatio > 0 {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(pacemakerRingColor)
                    .frame(width: width * fillRatio)
            }
        }
        .frame(width: width, height: pacemakerBarHeight)
    }

    // MARK: - Progress Values

    private var usageProgress: Double {
        guard let window else { return 0 }
        // Match widgets: use display-mode adjusted value so bars and text agree.
        return clamp(displayMode.displayPercent(from: window.usedPercent, window: window) / 100)
    }

    private var pacemakerProgress: Double {
        guard let percent = displayPacemakerPercent else { return 0 }
        return clamp(percent / 100)
    }

    private var displayPacemakerPercent: Double? {
        window?.displayPacemakerPercent(for: displayMode.makeDisplayModeRaw())
    }

    private var divisionCount: Int {
        window?.pacemakerDivisionCount ?? (windowKind == .primary ? 5 : 7)
    }

    /// Segmentation data when usage exceeds the pacemaker, otherwise nil.
    private var pacemakerSegments: PacemakerLinearSegments? {
        guard PacemakerRingWarningSettings.isWarningEnabled() else { return nil }
        guard displayMode != .remaining else { return nil }
        guard let window else { return nil }
        // Do not segment when threshold coloring already marks the bar orange/red.
        if let level = AppUsageColorResolver.barLevel(
            usedPercent: window.usedPercent,
            provider: provider,
            windowKind: windowKind
        ), level != .green {
            return nil
        }
        guard let pacemakerPercent = window.calculatePacemakerPercent() else { return nil }
        let warningDelta = PacemakerThresholdSettings.loadWarningDelta()
        let dangerDelta = PacemakerThresholdSettings.loadDangerDelta()
        guard window.usedPercent > pacemakerPercent + warningDelta else { return nil }

        let totalEnd = usageProgress
        let warningStart = clamp((pacemakerPercent + warningDelta) / 100)
        let dangerStart = max(warningStart, clamp((pacemakerPercent + dangerDelta) / 100))
        let normalEnd = min(totalEnd, warningStart)
        return PacemakerLinearSegments(
            normalEnd: normalEnd,
            warningStart: warningStart,
            dangerStart: dangerStart,
            totalEnd: totalEnd
        )
    }

    // MARK: - Colors

    private var barColor: Color {
        AppUsageColorResolver.barColor(
            usedPercent: window?.usedPercent,
            provider: provider,
            windowKind: windowKind
        )
    }

    private var pacemakerRingColor: Color {
        UsageColorSettings.loadPacemakerRingColor()
    }

    private var pacemakerWarningColor: Color {
        UsageColorSettings.loadPacemakerStatusOrangeColor()
    }

    private var pacemakerDangerColor: Color {
        UsageColorSettings.loadPacemakerStatusRedColor()
    }

    private func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

/// Segment information for coloring the usage bar when it exceeds the pacemaker.
private struct PacemakerLinearSegments {
    let normalEnd: Double
    let warningStart: Double
    let dangerStart: Double
    let totalEnd: Double
}

/// Linear-bar division parameters, matching the donut ring division parameters.
enum LinearDivisionParams {
    /// Fraction of the total length occupied by gaps between segments.
    static let gapFraction: Double = 0.015
}
