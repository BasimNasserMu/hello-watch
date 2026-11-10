import SwiftUI

@main
struct HelloPhoneApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 12) {
                Image(systemName: "applewatch")
                    .font(.system(size: 56))
                Text("HelloWatch")
                    .font(.title.bold())
                Text("Open the Watch app on your iPhone to install the watch side.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
    }
}
