import HermesKit
import SwiftUI

/// Issue #101: the Quiet Ring. One thin ring: blue for the owner, the label color for Hermes.
/// No Liquid Glass on the ring. Reduce Motion: no bend and no arc, the opacity follows the level.
struct QuietRing: View {
    var style: VoiceRingStyle
    /// From 0 to 1: the mic level while listening, the output level while speaking.
    var level: Float
    var diameter: CGFloat
    var lineWidth: CGFloat = 3
    /// The mic symbol in the Idle and Muted rings. The mini bar has no symbol.
    var showsSymbol = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var value: CGFloat { CGFloat(min(max(level, 0), 1)) }

    var body: some View {
        ZStack {
            switch style {
            case .idle:
                Circle().stroke(Color(uiColor: .tertiaryLabel), lineWidth: lineWidth)
                symbol("mic.fill", color: .primary)
            case .listening:
                live(color: .blue)
            case .speaking:
                Circle()
                    .fill(Color(uiColor: .label).opacity(0.04 + 0.1 * value))
                    .padding(lineWidth)
                live(color: Color(uiColor: .label))
            case .working:
                working
            case .muted:
                dotted(Color(uiColor: .secondaryLabel))
                symbol("mic.slash.fill", color: .secondary)
            case .paused:
                dotted(Color(uiColor: .tertiaryLabel))
            }
        }
        .frame(width: diameter, height: diameter)
        .animation(.spring(duration: 0.25), value: value)
        .animation(.easeInOut(duration: 0.25), value: style)
    }

    @ViewBuilder private func live(color: Color) -> some View {
        if reduceMotion {
            Circle()
                .stroke(color, lineWidth: lineWidth)
                .opacity(0.35 + 0.65 * value)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                BendingCircle(level: value, phase: context.date.timeIntervalSinceReferenceDate)
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            }
        }
    }

    /// Gray at 70 %. One short arc turns, 1.8 s a turn.
    @ViewBuilder private var working: some View {
        let gray = Color(uiColor: .systemGray)
        ZStack {
            Circle().stroke(gray.opacity(0.35), lineWidth: lineWidth)
            if !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
                    Circle()
                        .trim(from: 0, to: 0.12)
                        .stroke(gray, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(turn * 360 - 90))
                }
            }
        }
        .scaleEffect(0.7)
    }

    private func dotted(_ color: Color) -> some View {
        Circle().stroke(color, style: StrokeStyle(lineWidth: lineWidth * 0.8, lineCap: .round, dash: [0.1, 7]))
    }

    @ViewBuilder private func symbol(_ name: String, color: Color) -> some View {
        if showsSymbol {
            Image(systemName: name)
                .font(.system(size: diameter * 0.16, weight: .regular))
                .foregroundStyle(color)
        }
    }
}

/// A circle whose outline bends with the level. Silence makes a calm circle.
struct BendingCircle: Shape {
    var level: CGFloat
    var phase: TimeInterval

    var animatableData: CGFloat {
        get { level }
        set { level = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2 * 0.9
        let amount = 0.1 * level
        let time = CGFloat(phase)
        var path = Path()
        let steps = 96
        for step in 0...steps {
            let angle = CGFloat(step) / CGFloat(steps) * 2 * .pi
            let wave = 0.5 * sin(3 * angle + 2.1 * time) + 0.3 * sin(5 * angle - 2.9 * time)
                + 0.2 * sin(2 * angle + 1.3 * time)
            let r = radius * (1 + amount * wave)
            let point = CGPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle))
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}
