import SwiftUI
import AppKit

// MARK: - Job Row

struct JobRowView: View {
    let job: VeeamJob
    var isSelected: Bool = false
    @State private var pulse = false
    @Environment(\.textScaleFactor) private var textScaleFactor

    private var bucket: JobResultBucket {
        jobResultBucket(for: job)
    }

    private var style: StatusStyle {
        bucket.style
    }

    private var statusColor: Color {
        isSelected ? Theme.onSelectedRowStatus(for: bucket) : style.color
    }

    private var titleColor: Color {
        isSelected ? Theme.listRowSelectedPrimary : Theme.textPrimary
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            statusDot

            Text(job.name)
                .font(Font.scaledText(.callout, scale: textScaleFactor, weight: .medium))
                .foregroundStyle(titleColor)
                .lineLimit(1)
                .layoutPriority(1)

            Spacer()

            statusBadge
        }
        .padding(.vertical, Theme.Spacing.xs)
        .opacity(job.enabled ? 1.0 : 0.6)
    }

    private var statusDot: some View {
        ZStack {
            if job.isRunning {
                Circle()
                    .fill(statusColor.opacity(0.30))
                    .frame(width: 18, height: 18)
                    .scaleEffect(pulse ? 1.0 : 0.55)
                    .opacity(pulse ? 0.0 : 0.9)
            }
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
        }
        .frame(width: 18)
        .onAppear {
            guard job.isRunning else { return }
            withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: style.icon)
                .font(Font.scaledSystem(size: 9, weight: .bold, scale: textScaleFactor))
            Text(resultBadgeText)
                .font(Font.scaledText(.caption2, scale: textScaleFactor, weight: .semibold))
        }
        .foregroundStyle(statusColor)
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, 3)
        .background(statusBadgeBackground, in: Capsule())
    }

    private var statusBadgeBackground: Color {
        isSelected ? statusColor.opacity(0.22) : style.tint
    }

    private var resultBadgeText: String {
        job.isRunning ? job.runningStatusText : job.resultText
    }
}
