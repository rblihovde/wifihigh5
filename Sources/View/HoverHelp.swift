import SwiftUI

/// Whether hover explanations are shown. Owned here so both the modifier and
/// the Help window's switch read the same value.
enum HoverHelpSetting {
    static let key = "hoverHelpEnabled"
}

/// Shows a short explanation when the pointer rests on a reading.
///
/// The text comes from the same topics as the Help window, so the two cannot
/// disagree. Labels with no matching topic get no tooltip and no hover
/// affordance at all, rather than an approximate one.
enum HoverHelpAffordance {
    /// A faint underline, for a single word such as a column heading.
    case underline
    /// A faint background wash, for a whole row or tile.
    case highlight
}

private struct HoverHelpModifier: ViewModifier {
    let label: String
    let affordance: HoverHelpAffordance
    @AppStorage(HoverHelpSetting.key) private var enabled = true
    @State private var hovering = false
    @State private var showing = false

    private var topic: HelpTopic? { HelpIndex.topic(forLabel: label) }

    func body(content: Content) -> some View {
        if let topic, enabled {
            content
                // A faint underline only while hovering, so the affordance is
                // discoverable without cluttering a dense readout.
                .background {
                    if hovering, affordance == .highlight {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.10))
                            .padding(.horizontal, -5)
                            .padding(.vertical, -2)
                    }
                }
                .overlay(alignment: .bottom) {
                    if hovering, affordance == .underline {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.4))
                            .frame(height: 1)
                            .offset(y: 2)
                    }
                }
                // Without this the pointer only registers over the glyphs
                // themselves, so the gaps in a row would silently do nothing.
                .contentShape(Rectangle())
                .onHover { isInside in
                    hovering = isInside
                    if isInside {
                        // A short delay stops tooltips flickering up as the
                        // pointer crosses a card on its way somewhere else.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                            if hovering { showing = true }
                        }
                    } else {
                        showing = false
                    }
                }
                .popover(isPresented: $showing, arrowEdge: .trailing) {
                    HoverHelpCard(topic: topic)
                }
        } else {
            content
        }
    }
}

struct HoverHelpCard: View {
    let topic: HelpTopic

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(topic.term)
                .font(.system(size: 12.5, weight: .semibold))
            Text(topic.short)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !topic.scale.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(topic.scale.prefix(5).enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .top, spacing: 8) {
                            Text(row.0)
                                .font(.system(size: 10, weight: .semibold))
                                .frame(width: 62, alignment: .leading)
                            Text(row.1)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 96, alignment: .leading)
                        }
                    }
                }
            }

            Divider()
            Text("⌘? for the full explanation · turn these off in Help")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
        }
        .padding(11)
        .frame(width: topic.scale.isEmpty ? 250 : 288)
    }
}

extension View {
    /// Attaches the hover explanation for a reading, looked up by its label.
    func explains(_ label: String,
                  affordance: HoverHelpAffordance = .underline) -> some View {
        modifier(HoverHelpModifier(label: label, affordance: affordance))
    }
}
