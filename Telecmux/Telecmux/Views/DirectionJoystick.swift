import SwiftUI

/// Floating four-direction virtual joystick. Drag past the dead zone to fire
/// an arrow key; keep holding to auto-repeat (like holding a physical arrow
/// key). Release snaps the knob back to center and stops the repeat.
///
/// Sends are awaited inside the repeat loop, so a slow SSH round-trip
/// naturally throttles the repeat rate instead of queueing a backlog that
/// keeps firing after the finger lifts.
struct DirectionJoystick: View {
    /// Sends one arrow key ("up" / "down" / "left" / "right") to the surface.
    var sendKey: (String) async -> Void

    @State private var knobOffset: CGSize = .zero
    @State private var activeDirection: String?
    @State private var repeatTask: Task<Void, Never>?

    private let baseSize: CGFloat = 92
    private let knobSize: CGFloat = 40
    /// Drag distance before a direction registers.
    private let deadZone: CGFloat = 14
    /// Max knob travel from center.
    private let maxTravel: CGFloat = 28
    /// Delay before auto-repeat kicks in, then per-repeat pause.
    private let repeatDelay: UInt64 = 350_000_000
    private let repeatPause: UInt64 = 120_000_000

    var body: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .overlay(hints)
            Circle()
                .fill(activeDirection == nil ? Color.gray.opacity(0.75) : Color.accentColor)
                .frame(width: knobSize, height: knobSize)
                .shadow(radius: 2)
                .offset(knobOffset)
        }
        .frame(width: baseSize, height: baseSize)
        .opacity(activeDirection == nil ? 0.55 : 0.95)
        .gesture(drag)
        .animation(.spring(duration: 0.15), value: knobOffset)
        .accessibilityLabel("Arrow key joystick")
    }

    // MARK: - gesture

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let dx = value.translation.width
                let dy = value.translation.height
                let distance = max(sqrt(dx * dx + dy * dy), 0.001)
                let clamped = min(distance, maxTravel)
                knobOffset = CGSize(width: dx / distance * clamped,
                                    height: dy / distance * clamped)

                let direction: String?
                if distance < deadZone {
                    direction = nil
                } else if abs(dx) > abs(dy) {
                    direction = dx > 0 ? "right" : "left"
                } else {
                    direction = dy > 0 ? "down" : "up"
                }
                if direction != activeDirection {
                    activeDirection = direction
                    restartRepeat(direction)
                }
            }
            .onEnded { _ in
                knobOffset = .zero
                activeDirection = nil
                repeatTask?.cancel()
                repeatTask = nil
            }
    }

    /// Fire immediately, wait the initial delay, then repeat — each send is
    /// awaited so SSH latency throttles the loop (no runaway backlog).
    private func restartRepeat(_ direction: String?) {
        repeatTask?.cancel()
        guard let direction else { repeatTask = nil; return }
        repeatTask = Task {
            await sendKey(direction)
            try? await Task.sleep(nanoseconds: repeatDelay)
            while !Task.isCancelled {
                await sendKey(direction)
                try? await Task.sleep(nanoseconds: repeatPause)
            }
        }
    }

    // MARK: - chrome

    private var hints: some View {
        ZStack {
            Image(systemName: "chevron.up").offset(y: -34)
            Image(systemName: "chevron.down").offset(y: 34)
            Image(systemName: "chevron.left").offset(x: -34)
            Image(systemName: "chevron.right").offset(x: 34)
        }
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(.secondary)
    }
}
