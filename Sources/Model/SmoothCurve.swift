import CoreGraphics

/// A smooth line through a series of readings that never overshoots them.
///
/// This is monotone cubic interpolation (Fritsch–Carlson). Between any two
/// readings the curve bends, but it never rises above the higher of the two or
/// dips below the lower, so it cannot draw a peak or a trough that was never
/// measured. A plain spline would, and on a signal chart that is a lie.
enum SmoothCurve {

    /// The two Bézier control points for each span between consecutive points.
    /// Points must be in order of increasing x.
    static func controlPoints(through points: [CGPoint]) -> [(CGPoint, CGPoint)] {
        let n = points.count
        guard n > 1 else { return [] }

        // Slope of each span.
        var delta = [CGFloat](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) {
            let dx = points[i + 1].x - points[i].x
            delta[i] = dx == 0 ? 0 : (points[i + 1].y - points[i].y) / dx
        }

        // Tangent at each point: the average of the spans either side, or flat
        // where the series turns, so a local peak stays at the reading.
        var m = [CGFloat](repeating: 0, count: n)
        m[0] = delta[0]
        m[n - 1] = delta[n - 2]
        if n > 2 {
            for i in 1..<(n - 1) {
                m[i] = delta[i - 1] * delta[i] <= 0 ? 0 : (delta[i - 1] + delta[i]) / 2
            }
        }

        // A flat span gets flat tangents at both ends.
        for i in 0..<(n - 1) where delta[i] == 0 {
            m[i] = 0
            m[i + 1] = 0
        }

        // Pull in any tangent steep enough to carry the curve past a reading.
        for i in 0..<(n - 1) where delta[i] != 0 {
            let a = m[i] / delta[i]
            let b = m[i + 1] / delta[i]
            let length = a * a + b * b
            if length > 9 {
                let t = 3 / length.squareRoot()
                m[i] = t * a * delta[i]
                m[i + 1] = t * b * delta[i]
            }
        }

        var out: [(CGPoint, CGPoint)] = []
        out.reserveCapacity(n - 1)
        for i in 0..<(n - 1) {
            let third = (points[i + 1].x - points[i].x) / 3
            out.append((
                CGPoint(x: points[i].x + third, y: points[i].y + m[i] * third),
                CGPoint(x: points[i + 1].x - third, y: points[i + 1].y - m[i + 1] * third)
            ))
        }
        return out
    }
}
