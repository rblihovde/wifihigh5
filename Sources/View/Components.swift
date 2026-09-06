import SwiftUI

// MARK: - Design tokens

enum UI {
    static let radius: CGFloat = 12
    static let cardPadding: CGFloat = 14
    static let gap: CGFloat = 12
}

extension Color {
    static let cardBG = Color(nsColor: .controlBackgroundColor)
    static let hairline = Color(nsColor: .separatorColor)
    static let subtle = Color(nsColor: .tertiaryLabelColor)
}

// MARK: - Card

struct Card<Content: View>: View {
    var title: String?
    var systemImage: String?
    var accessory: AnyView?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, systemImage: String? = nil,
         accessory: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.accessory = accessory
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if title != nil || accessory != nil {
                HStack(spacing: 6) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    if let title {
                        Text(title.uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if let accessory { accessory }
                }
            }
            content
        }
        .padding(UI.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardBG, in: RoundedRectangle(cornerRadius: UI.radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: UI.radius, style: .continuous)
                .strokeBorder(Color.hairline.opacity(0.6), lineWidth: 1)
        )
    }
}

// MARK: - Label / value row

struct InfoRow: View {
    var label: String
    var value: String
    var mono: Bool = false
    var tint: Color?
    var help: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 108, alignment: .leading)
            Text(value)
                .font(.system(size: 11.5, weight: .medium, design: mono ? .monospaced : .default))
                .foregroundStyle(tint ?? .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .explains(label, affordance: .highlight)
        .help(HelpIndex.topic(forLabel: label) == nil ? (help ?? "") : "")
    }
}

// MARK: - Big stat

struct StatTile: View {
    var label: String
    var value: String
    var unit: String?
    var tint: Color = .primary
    var caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                if let unit {
                    Text(unit)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            if let caption {
                Text(caption)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color.subtle)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .explains(label, affordance: .highlight)
    }
}

// MARK: - Quality indicators

struct QualityBadge: View {
    var quality: SignalQuality
    var compact = false

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(quality.color).frame(width: 7, height: 7)
            Text(quality.label)
                .font(.system(size: compact ? 10 : 11, weight: .semibold))
        }
        .padding(.horizontal, compact ? 7 : 9)
        .padding(.vertical, compact ? 3 : 4)
        .background(quality.color.opacity(0.15), in: Capsule())
        .overlay(Capsule().strokeBorder(quality.color.opacity(0.35), lineWidth: 1))
        .foregroundStyle(quality.color)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Signal quality: \(quality.label)")
    }
}

/// Four-bar strength meter, matching how the menu bar presents signal.
struct SignalBars: View {
    var quality: SignalQuality
    var size: CGFloat = 18

    private var filled: Int {
        switch quality {
        case .poor: return 1
        case .weak: return 2
        case .fair: return 3
        case .good: return 4
        case .excellent: return 4
        }
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: size * 0.11) {
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: size * 0.06)
                    .fill(i < filled ? quality.color : Color.secondary.opacity(0.22))
                    .frame(width: size * 0.17, height: size * (0.32 + Double(i) * 0.22))
            }
        }
        .frame(height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Signal quality: \(quality.label)")
    }
}

// MARK: - Access point chip

struct APChip: View {
    var name: String
    var color: Color
    var subtitle: String?
    var isPrecise: Bool = true

    var body: some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color)
                .frame(width: 10, height: 10)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(.white.opacity(0.25), lineWidth: 0.5)
                )
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    if !isPrecise {
                        Image(systemName: "questionmark.circle")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                            .help("Identified by radio fingerprint, not BSSID. Two APs on the same channel may look identical.")
                    }
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

// MARK: - Small pill

struct Pill: View {
    var text: String
    var tint: Color
    var filled = false

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(tint.opacity(filled ? 0.9 : 0.15), in: Capsule())
            .foregroundStyle(filled ? .white : tint)
    }
}

// MARK: - Empty state

struct EmptyHint: View {
    var systemImage: String
    var title: String
    var message: String
    var action: (label: String, run: () -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            if let action {
                Button(action.label, action: action.run)
                    .controlSize(.small)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
