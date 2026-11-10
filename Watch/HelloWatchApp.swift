import SwiftUI

@main
struct HelloWatchApp: App {
    @State private var taps = 0

    var body: some Scene {
        WindowGroup {
            VStack(spacing: 8) {
                Text("Hello, wrist! 👋")
                    .font(.headline)
                Button("Tapped \(taps)×") { taps += 1 }
            }
        }
    }
}
