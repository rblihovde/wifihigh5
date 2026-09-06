import SwiftUI

/// Turns radio measurements into a concise answer for people who do not think
/// in dBm. Raw readings remain available below for deeper troubleshooting.
struct ConnectionGuide: View {
    @EnvironmentObject private var monitor: WiFiMonitor
    @EnvironmentObject private var pinger: GatewayPinger

    private struct Verdict {
        var title: String
        var detail: String
        var nextStep: String?
        var symbol: String
        var tint: Color
    }

    var body: some View {
        Card {
            if let sample = monitor.current {
                connected(sample)
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 16))
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No connection to assess")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Connect this Mac to Wi-Fi and the app will explain the link quality here.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The verdict and the recent-stats window are each resolved once per
    /// render. Both walk the sample buffer, and the body reads them repeatedly.
    @ViewBuilder
    private func connected(_ sample: WiFiSample) -> some View {
        let recent = monitor.stats(inLast: 60)
        let v = verdict(for: sample, recent: recent)

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: v.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(v.tint)
                    .frame(width: 30, height: 30)
                    .background(v.tint.opacity(0.14), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(v.title)
                        .font(.system(size: 15, weight: .semibold))
                    Text(v.detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                Text(monitor.isRunning ? "LIVE" : "PAUSED")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(monitor.isRunning ? Color.green : Color.orange)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background((monitor.isRunning ? Color.green : Color.orange).opacity(0.12), in: Capsule())
            }

            HStack(spacing: 8) {
                guideMetric("Signal", "\(sample.rssi) dBm", sample.quality.color,
                            sample.quality.label)
                guideMetric("Signal clarity", sample.snr.map { "\($0) dB" } ?? "Not reported",
                            sample.snrQuality?.color ?? .secondary,
                            sample.snrQuality?.label ?? "Unavailable")
                if let recent, recent.count >= 3 {
                    guideMetric("Stability", "±\(recent.jitter) dB",
                                recent.jitter >= 7 ? .orange : .green,
                                recent.jitter >= 7 ? "Changing" : "Steady")
                }
                if pinger.enabled {
                    let ready = pinger.completed >= 3
                    guideMetric("Router", ready ? String(format: "%.0f%% loss", pinger.lossPercent) : "Testing…",
                                ready && pinger.lossPercent > 2 ? .red : .green,
                                ready ? (pinger.lossPercent > 2 ? "Unstable" : "Reachable") : "Collecting")
                }
            }

            if let next = v.nextStep {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(v.tint)
                        .padding(.top, 1)
                    Text(next)
                        .font(.system(size: 10.5, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private func guideMetric(_ label: String, _ value: String, _ tint: Color, _ status: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .explains(label)
                Text("\(status) · \(value)")
                    .font(.system(size: 10.5, weight: .semibold))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Color.hairline.opacity(0.20), in: RoundedRectangle(cornerRadius: 7))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("\(label), \(status), \(value)")
    }

    private func verdict(for sample: WiFiSample, recent: WiFiMonitor.Stats?) -> Verdict {
        if !monitor.isRunning {
            return Verdict(
                title: "Monitoring is paused",
                detail: "The readings are frozen at \(Fmt.relativeTime(sample.time)). Resume when you’re ready to keep walking the site.",
                nextStep: "Resume sampling before comparing another room or access point.",
                symbol: "pause.fill", tint: .orange)
        }

        if pinger.enabled, pinger.completed >= 5, pinger.lossPercent >= 5 {
            return Verdict(
                title: "The connection is losing router replies",
                detail: "The gateway check shows \(String(format: "%.0f", pinger.lossPercent))% packet loss. Calls and interactive apps may stutter even when the signal looks strong.",
                nextStep: sample.quality >= .good
                    ? "Because the radio signal is strong, check the access point or its wired uplink."
                    : "Move closer to the access point and watch whether both signal and packet loss improve.",
                symbol: "exclamationmark.triangle.fill", tint: .red)
        }

        if sample.rssi < -75 {
            return Verdict(
                title: "The Wi-Fi signal is unreliable here",
                detail: "At \(sample.rssi) dBm, dropouts and slow transfers are likely—especially while moving or on a call.",
                nextStep: "Move closer to an access point. If another radio serves this network, run a nearby scan to compare it.",
                symbol: "wifi.exclamationmark", tint: .red)
        }

        if let snr = sample.snr, snr < 15 {
            return Verdict(
                title: "Noise is overpowering the signal",
                detail: "The signal-to-noise gap is only \(snr) dB, so the link may retry data even though the signal level alone looks acceptable.",
                nextStep: "Try a different location or band. A nearby scan can show whether this channel is crowded.",
                symbol: "waveform.badge.exclamationmark", tint: .red)
        }

        if let snr = sample.snr, snr < 25 {
            return Verdict(
                title: "The connection may struggle under load",
                detail: "The signal is usable, but the \(snr) dB signal-to-noise gap leaves limited headroom for calls and large transfers.",
                nextStep: "Keep walking and watch whether signal clarity improves near another access point.",
                symbol: "exclamationmark.circle.fill", tint: .orange)
        }

        if let stats = recent, stats.count >= 10, stats.jitter >= 7 {
            return Verdict(
                title: "The signal is changing quickly",
                detail: "Signal varied by about ±\(stats.jitter) dB over the last minute. That can happen near a coverage edge or while moving.",
                nextStep: "Pause briefly in one spot. If variation stays high, compare nearby access points and channels.",
                symbol: "waveform.path", tint: .orange)
        }

        if sample.rssi < -67 {
            return Verdict(
                title: "The connection is usable, with limited headroom",
                detail: "Basic browsing should work, but this signal level may become unreliable during calls or as you move farther away.",
                nextStep: "Use −67 dBm as a practical coverage edge for voice and video walkthroughs.",
                symbol: "wifi", tint: .orange)
        }

        return Verdict(
            title: sample.quality == .excellent ? "The connection looks excellent" : "The connection looks solid",
            detail: sample.snr.map { "Signal is strong and the \($0) dB signal-to-noise gap provides healthy headroom." }
                ?? "Signal strength is healthy. The Wi-Fi driver is not reporting a noise floor, so signal clarity cannot be graded.",
            nextStep: nil,
            symbol: "checkmark.circle.fill", tint: .green)
    }
}
