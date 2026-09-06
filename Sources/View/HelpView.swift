import SwiftUI

/// A reference for every reading the app shows.
///
/// Deliberately out of the way in the Help menu: the main window stays a dense
/// instrument, and the explanations live here for when a number needs one.
struct HelpTopic: Identifiable, Hashable {
    let id = UUID()
    var term: String
    var category: HelpCategory
    /// One-line answer, shown under the heading and used for search previews.
    var short: String
    var body: [String]
    /// Optional threshold table: label, range, meaning.
    var scale: [(String, String, String)] = []

    static func == (a: HelpTopic, b: HelpTopic) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    var searchText: String {
        ([term, short] + body + scale.flatMap { [$0.0, $0.1, $0.2] }).joined(separator: " ").lowercased()
    }
}

enum HelpCategory: String, CaseIterable, Identifiable {
    case signal = "Signal & quality"
    case radio = "Radio & channels"
    case accessPoints = "Access points"
    case walkthroughs = "Walkthroughs"
    case networkMap = "Network map"
    case network = "Network & IP"
    case permissions = "Permissions & privacy"
    case shortcuts = "Shortcuts"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .signal: return "antenna.radiowaves.left.and.right"
        case .radio: return "dot.radiowaves.left.and.right"
        case .accessPoints: return "wifi.router"
        case .walkthroughs: return "figure.walk"
        case .networkMap: return "point.topleft.down.to.point.bottomright.curvepath"
        case .network: return "network"
        case .permissions: return "lock.shield"
        case .shortcuts: return "keyboard"
        }
    }
}

struct HelpView: View {
    @State private var search = ""
    @State private var selection: HelpTopic?
    @AppStorage(HoverHelpSetting.key) private var hoverHelpEnabled = true

    private var filtered: [HelpTopic] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return HelpContent.topics }
        return HelpContent.topics.filter { $0.searchText.contains(q) }
    }

    /// A named group rather than a tuple: ForEach needs a stable identity, and
    /// tuples do not provide one.
    private struct TopicGroup: Identifiable {
        let category: HelpCategory
        let topics: [HelpTopic]
        var id: String { category.rawValue }
    }

    private var grouped: [TopicGroup] {
        HelpCategory.allCases.compactMap { c in
            let items = filtered.filter { $0.category == c }
            return items.isEmpty ? nil : TopicGroup(category: c, topics: items)
        }
    }

    var body: some View {
        // A plain split rather than NavigationSplitView: that container does not
        // reliably render inside a secondary Window scene on macOS, and a help
        // window has no need for navigation stacks anyway.
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                sidebar
                preferences
            }
            .frame(width: 262)
            .background(Color(nsColor: .controlBackgroundColor))
            Divider()
            Group {
                if let topic = selection {
                    topicDetail(topic)
                } else {
                    welcome
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 820, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Settings that belong with the reference rather than with the
    /// measurement controls in Diagnostics.
    private var preferences: some View {
        VStack(alignment: .leading, spacing: 5) {
            Divider()
            Toggle(isOn: $hoverHelpEnabled) {
                Text("Explain readings on hover")
                    .font(.system(size: 11.5))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            Text(hoverHelpEnabled
                 ? "Resting the pointer on a reading shows a short explanation."
                 : "Hover explanations are off. Everything is still here.")
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Search readings and terms", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            Divider()

            if grouped.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 20)).foregroundStyle(.tertiary)
                    Text("No matches for “\(search)”")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            } else {
                List(selection: $selection) {
                    ForEach(grouped) { group in
                        Section {
                            ForEach(group.topics) { topic in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(topic.term)
                                        .font(.system(size: 12, weight: .medium))
                                    Text(topic.short)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .padding(.vertical, 1)
                                .tag(topic)
                            }
                        } header: {
                            Label(group.category.rawValue, systemImage: group.category.symbol)
                                .font(.system(size: 10, weight: .semibold))
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("What the numbers mean")
                    .font(.system(size: 20, weight: .bold))
                Text("Every reading this app shows, what a good value looks like, and what to do when it isn't. Pick a term on the left or search.")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Text("IF YOU READ ONLY ONE THING")
                .font(.system(size: 9.5, weight: .semibold)).tracking(0.6)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 9) {
                quickPoint("−67 dBm is the number that matters.",
                           "It is the usual practical floor for voice and video. Above it, things work. Below it, expect trouble as you move.")
                quickPoint("Signal alone can lie. Check clarity too.",
                           "A strong signal on a noisy channel still performs badly. Signal clarity (SNR) is the better predictor.")
                quickPoint("Know which access point you are on.",
                           "A reading is only actionable if you know which radio produced it. Nickname your access points and the graph colours follow.")
            }
            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func quickPoint(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.system(size: 12)).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .semibold))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func topicDetail(_ topic: HelpTopic) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Label(topic.category.rawValue, systemImage: topic.category.symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(topic.term).font(.system(size: 21, weight: .bold))
                    Text(topic.short)
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                ForEach(Array(topic.body.enumerated()), id: \.offset) { _, para in
                    Text(para)
                        .font(.system(size: 12.5))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

                if !topic.scale.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text("RATING").frame(width: 92, alignment: .leading)
                            Text("RANGE").frame(width: 116, alignment: .leading)
                            Text("WHAT IT MEANS").frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.system(size: 9, weight: .semibold)).tracking(0.5)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 6)

                        ForEach(Array(topic.scale.enumerated()), id: \.offset) { _, row in
                            HStack(alignment: .top) {
                                Text(row.0).font(.system(size: 11.5, weight: .semibold))
                                    .frame(width: 92, alignment: .leading)
                                Text(row.1).font(.system(size: 11.5, design: .monospaced))
                                    .frame(width: 116, alignment: .leading)
                                Text(row.2).font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.vertical, 5)
                            Divider().opacity(0.4)
                        }
                    }
                    .padding(12)
                    .background(Color.hairline.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
                }
                Spacer(minLength: 10)
            }
            .padding(28)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
