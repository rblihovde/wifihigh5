import SwiftUI

/// View-level state for the survey workflow, kept out of the measurement model.
@MainActor
final class SurveyUI: ObservableObject {
    struct Pending: Identifiable {
        let id = UUID()
        let time: Date
    }

    @Published var pendingWaypoint: Pending?
    @Published var showRecordingSetup = false
    @Published var lastLabel = ""

    /// Stamps the moment the shortcut fired. Naming happens afterwards, but the
    /// waypoint belongs to this instant, not to whenever typing finishes.
    func captureWaypoint() {
        pendingWaypoint = Pending(time: Date())
    }
}

/// Fast, keyboard-only waypoint naming: the field is focused on appear, the
/// previous label is pre-selected so typing replaces it, and Return commits.
struct WaypointCaptureSheet: View {
    @EnvironmentObject private var monitor: WiFiMonitor
    @EnvironmentObject private var registry: APRegistry
    @EnvironmentObject private var surveyUI: SurveyUI
    @Environment(\.dismiss) private var dismiss

    let time: Date
    @State private var label = ""
    @State private var note = ""
    @FocusState private var focused: Bool

    private var sample: WiFiSample? { monitor.current }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "mappin.and.ellipse")
                    .foregroundStyle(.blue)
                Text("Mark this spot")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(Fmt.clock.string(from: time))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if let s = sample {
                HStack(spacing: 8) {
                    readingPill("\(s.rssi) dBm", s.quality.color)
                    if let snr = s.snr { readingPill("SNR \(snr) dB", s.snrQuality?.color ?? .secondary) }
                    readingPill(registry.displayName(for: s.apKey,
                                                     fallbackChannel: s.channel,
                                                     fallbackBand: s.bandRaw),
                                registry.color(for: s.apKey))
                }
            }

            TextField("Where are you? e.g. Reception, Conf B, East stairwell", text: $label)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
                .focused($focused)
                .onSubmit(commit)

            if !monitor.recentWaypointLabels.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("REUSE")
                        .font(.system(size: 9, weight: .semibold)).tracking(0.5)
                        .foregroundStyle(.secondary)
                    // Wrapping row of recent labels: one click instead of retyping
                    // a name that repeats on every floor.
                    FlowRow(spacing: 5) {
                        ForEach(monitor.recentWaypointLabels, id: \.self) { recent in
                            Button {
                                label = recent
                                commit()
                            } label: {
                                Text(recent)
                                    .font(.system(size: 10.5))
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(Color.hairline.opacity(0.35), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            TextField("Note (optional)", text: $note)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))

            HStack {
                Text("⏎ to save · esc to cancel")
                    .font(.system(size: 10)).foregroundStyle(Color.subtle)
                Spacer()
                Button("Cancel") { dismiss() }
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
                Button("Save Waypoint", action: commit)
                    .controlSize(.small).buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 380)
        .onAppear {
            label = surveyUI.lastLabel
            focused = true
        }
    }

    private func readingPill(_ text: String, _ tint: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
            .lineLimit(1)
    }

    private func commit() {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        monitor.addWaypoint(label: trimmed, note: note, at: time)
        surveyUI.lastLabel = trimmed
        dismiss()
    }
}

/// Minimal wrapping layout, so recent labels flow onto more than one line.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = Swift.max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = Swift.max(rowHeight, size.height)
        }
    }
}
