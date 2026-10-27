import SwiftUI

// The InkBridge logo and ink backdrop, shared by the iPad start screen and the Mac window.

/// Ink arch over a baseline, beside the wordmark.
struct InkBridgeLogo: View {
    var body: some View {
        HStack(spacing: 14) {
            BridgeMark()
                .stroke(.primary,
                        style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round))
                .frame(width: 52, height: 34)
            (Text("Ink").fontWeight(.heavy) + Text("Bridge").fontWeight(.light))
                .font(.system(size: 40, design: .rounded))
                .foregroundStyle(.primary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("InkBridge")
        .accessibilityAddTraits(.isHeader)
    }
}

private struct BridgeMark: Shape {
    func path(in rect: CGRect) -> Path {
        // A deck across the top, carried by an arch whose crown meets it.
        let deck = rect.minY + rect.height * 0.25
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: deck))
        path.addLine(to: CGPoint(x: rect.maxX, y: deck))
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.14, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - rect.width * 0.14, y: rect.maxY),
                          control: CGPoint(x: rect.midX, y: 2 * deck - rect.maxY))
        return path
    }
}

/// A slow-moving ink wash for the glass to refract: ink on black in dark mode, a faint wash on paper in light mode.
struct InkBackdrop: View {
    @Environment(\.colorScheme) private var scheme

    private static let ink: [Color] = [
        Color(white: 0.03), Color(white: 0.07), Color(white: 0.035),
        Color(red: 0.06, green: 0.08, blue: 0.16), Color(white: 0.2), Color(white: 0.09),
        Color(white: 0.04), Color(red: 0.05, green: 0.07, blue: 0.14), Color(white: 0.02),
    ]
    private static let paper: [Color] = [
        Color(red: 0.97, green: 0.96, blue: 0.93), Color(red: 0.95, green: 0.94, blue: 0.91), Color(red: 0.97, green: 0.96, blue: 0.94),
        Color(red: 0.88, green: 0.89, blue: 0.93), Color(red: 0.8, green: 0.81, blue: 0.84), Color(red: 0.93, green: 0.92, blue: 0.89),
        Color(red: 0.95, green: 0.94, blue: 0.9), Color(red: 0.87, green: 0.88, blue: 0.92), Color(red: 0.96, green: 0.95, blue: 0.92),
    ]

    /// Off on the Mac, whose window stays open beside the screen it sends.
    var moving = true

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 15, paused: !moving)) { context in
            let t = Float(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 40) / 40 * 2 * .pi)
            let colors = scheme == .dark ? Self.ink : Self.paper
            if #available(macOS 15.0, *) {
                MeshGradient(width: 3, height: 3, points: [
                    [0, 0], [0.5, 0], [1, 0],
                    [0, 0.5], [0.5 + 0.12 * cos(t), 0.5 + 0.1 * sin(t)], [1, 0.5],
                    [0, 1], [0.5, 1], [1, 1],
                ], colors: colors)
            } else {
                LinearGradient(colors: [colors[0], colors[4], colors[8]], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .ignoresSafeArea()
    }
}
