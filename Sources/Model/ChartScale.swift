import Foundation

/// How tightly the signal chart frames its readings vertically.
///
/// The full scale shows the whole usable range of Wi-Fi signal, which puts a
/// 3 dB swing at a few percent of the chart's height. The zoomed scales frame
/// the readings instead, so small changes become visible. None of them ever
/// crops a signal reading: a span is the narrowest view offered, and it widens
/// whenever the readings need more room.
enum ChartScale: String, CaseIterable, Identifiable {
    case full
    case wide
    case medium
    case close
    case fit

    var id: String { rawValue }

    var label: String {
        switch self {
        case .full:   return "Full"
        case .wide:   return "40 dB"
        case .medium: return "20 dB"
        case .close:  return "10 dB"
        case .fit:    return "Fit"
        }
    }

    var help: String {
        switch self {
        case .full:
            return "The whole usable range of Wi-Fi signal, from −95 to −25 dBm."
        case .wide, .medium, .close:
            return "At least \(label) tall, centred on the readings, and wider if they need it."
        case .fit:
            return "As tight around the readings as they allow. Small changes look large here; read the axis."
        }
    }

    /// The narrowest span shown, in dB. Nil for the fixed full scale.
    var minimumSpan: Double? {
        switch self {
        case .full:   return nil
        case .wide:   return 40
        case .medium: return 20
        case .close:  return 10
        case .fit:    return 6
        }
    }

    var isZoomed: Bool { minimumSpan != nil }

    /// The dBm range to draw.
    ///
    /// Zoomed scales frame the signal only. Including the noise floor, typically
    /// 40 or 50 dB below the signal, would undo the zoom, so the noise line is
    /// drawn where it falls inside and noted when it does not.
    func verticalRange(signal: [Int], noise: [Int]) -> ClosedRange<Double> {
        guard let span = minimumSpan else {
            var lo = -95.0, hi = -25.0
            for value in signal {
                lo = Swift.min(lo, Double(value) - 3)
                hi = Swift.max(hi, Double(value) + 3)
            }
            for value in noise { lo = Swift.min(lo, Double(value) - 3) }
            return lo...hi
        }

        guard let low = signal.min(), let high = signal.max() else { return -95...(-25) }
        let dataLo = Double(low) - 2
        let dataHi = Double(high) + 2
        let width = Swift.max(span, dataHi - dataLo)
        let middle = (dataLo + dataHi) / 2

        // Snap outward to the gridline step. Without it the frame follows every
        // fraction of a dB the readings move, and the axis labels shimmer.
        let step = Self.gridStep(for: width)
        let lo = ((middle - width / 2) / step).rounded(.down) * step
        let hi = ((middle + width / 2) / step).rounded(.up) * step
        return lo...hi
    }

    /// Spacing between labelled gridlines for a given span, so a close view
    /// still has several labels and a full view is not crowded with them.
    static func gridStep(for span: Double) -> Double {
        if span <= 12 { return 2 }
        if span <= 30 { return 5 }
        return 10
    }
}
