import SwiftUI
import WatchKit

@main
struct HelloWatchApp: App {
    var body: some Scene {
        WindowGroup {
            BuzzView()
        }
    }
}

/// One giant button: tap for a single buzz, press and hold for a continuous buzz.
struct BuzzView: View {
    @Environment(\.scenePhase) private var scenePhase

    @State private var isPressed = false
    @State private var isHolding = false
    @State private var holdStart: Date?
    @State private var holdTask: Task<Void, Never>?
    @State private var buzzCount = 0
    @State private var ripples: [UUID] = []

    /// How long the finger must stay down before a tap becomes a hold.
    private let holdThreshold: Duration = .milliseconds(350)
    /// Time between haptic pulses while holding.
    private let pulseInterval: Duration = .milliseconds(450)

    private var colors: [Color] {
        isHolding
            ? [Color(red: 1.0, green: 0.25, blue: 0.45), Color(red: 1.0, green: 0.55, blue: 0.1)]
            : [Color(red: 0.2, green: 0.55, blue: 1.0), Color(red: 0.55, green: 0.3, blue: 1.0)]
    }

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height - 26) * 0.98

            VStack(spacing: 4) {
                ZStack {
                    ForEach(ripples, id: \.self) { _ in
                        RippleRing(color: colors[0])
                    }
                    buttonFace
                }
                .frame(width: size, height: size)
                .contentShape(Circle())
                .gesture(pressGesture)
                .accessibilityElement()
                .accessibilityLabel("Buzz")
                .accessibilityHint("Tap to vibrate once, hold to keep vibrating")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { buzz(.notification) }

                statusLine
                    .frame(height: 22)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { endPress() }
        }
        .onDisappear { endPress() }
    }

    // MARK: - Visuals

    private var buttonFace: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            Circle()
                .fill(
                    RadialGradient(
                        colors: [.white.opacity(isPressed ? 0.05 : 0.28), .clear],
                        center: .init(x: 0.3, y: 0.25),
                        startRadius: 0,
                        endRadius: 90
                    )
                )
            Circle()
                .strokeBorder(.white.opacity(isPressed ? 0.6 : 0.25), lineWidth: isPressed ? 3 : 1.5)

            VStack(spacing: 2) {
                Image(systemName: isHolding ? "waveform.path" : "hand.tap.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .symbolEffect(.variableColor.iterative.reversing, isActive: isHolding)
                    .contentTransition(.symbolEffect(.replace))
                Text(isHolding ? "BUZZING" : "TAP · HOLD")
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .tracking(1)
                    .contentTransition(.opacity)
            }
            .foregroundStyle(.white)
        }
        .shadow(color: colors[0].opacity(isPressed ? 0.9 : 0.45), radius: isPressed ? 16 : 8)
        .scaleEffect(isPressed ? 0.9 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.55), value: isPressed)
        .animation(.easeInOut(duration: 0.3), value: isHolding)
    }

    private var statusLine: some View {
        Group {
            if isHolding, let holdStart {
                TimelineView(.periodic(from: holdStart, by: 0.1)) { context in
                    let secs = context.date.timeIntervalSince(holdStart)
                    Text(String(format: "Holding %.1fs", secs))
                        .monospacedDigit()
                        .foregroundStyle(colors[1])
                }
            } else {
                Text(buzzCount == 0 ? "Give it a try" : "\(buzzCount) buzz\(buzzCount == 1 ? "" : "es")")
                    .contentTransition(.numericText())
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 14, weight: .semibold, design: .rounded))
        .animation(.snappy, value: buzzCount)
    }

    // MARK: - Interaction

    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                if !isPressed { beginPress() }
            }
            .onEnded { _ in endPress() }
    }

    private func beginPress() {
        isPressed = true
        buzz(.notification)   // instant feedback on touch-down

        holdTask?.cancel()
        holdTask = Task { @MainActor in
            try? await Task.sleep(for: holdThreshold)
            guard !Task.isCancelled, isPressed else { return }
            holdStart = Date()
            isHolding = true
            while !Task.isCancelled && isPressed {
                buzz(.notification)
                try? await Task.sleep(for: pulseInterval)
            }
        }
    }

    private func endPress() {
        holdTask?.cancel()
        holdTask = nil
        if isHolding { WKInterfaceDevice.current().play(.stop) }
        isPressed = false
        isHolding = false
        holdStart = nil
    }

    private func buzz(_ type: WKHapticType) {
        WKInterfaceDevice.current().play(type)
        buzzCount += 1

        let id = UUID()
        ripples.append(id)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            ripples.removeAll { $0 == id }
        }
    }
}

/// An expanding ring that fades out — drawn once per haptic pulse.
private struct RippleRing: View {
    let color: Color
    @State private var expanded = false

    var body: some View {
        Circle()
            .stroke(color, lineWidth: 4)
            .scaleEffect(expanded ? 1.3 : 0.95)
            .opacity(expanded ? 0 : 0.85)
            .onAppear {
                withAnimation(.easeOut(duration: 0.75)) { expanded = true }
            }
    }
}
