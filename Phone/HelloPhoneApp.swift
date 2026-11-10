import SwiftUI
import WatchConnectivity

@main
struct HelloPhoneApp: App {
    var body: some Scene {
        WindowGroup {
            DiagnosticsView()
        }
    }
}

// MARK: - What's physically inside this app bundle

struct EmbeddedWatchApp {
    let fileName: String
    let bundleID: String?
    let companionID: String?
    let isWKApplication: Bool
    let hasCodeSignature: Bool
    let hasProvisioningProfile: Bool
}

enum BundleInspector {
    static var watchFolder: URL { Bundle.main.bundleURL.appendingPathComponent("Watch") }

    static var watchFolderExists: Bool {
        FileManager.default.fileExists(atPath: watchFolder.path)
    }

    static func embeddedWatchApp() -> EmbeddedWatchApp? {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: watchFolder, includingPropertiesForKeys: nil),
              let app = items.first(where: { $0.pathExtension == "app" }) else { return nil }

        let plist = NSDictionary(contentsOf: app.appendingPathComponent("Info.plist")) as? [String: Any] ?? [:]
        return EmbeddedWatchApp(
            fileName: app.lastPathComponent,
            bundleID: plist["CFBundleIdentifier"] as? String,
            companionID: plist["WKCompanionAppBundleIdentifier"] as? String,
            isWKApplication: plist["WKApplication"] as? Bool ?? false,
            hasCodeSignature: fm.fileExists(atPath: app.appendingPathComponent("_CodeSignature").path),
            hasProvisioningProfile: fm.fileExists(atPath: app.appendingPathComponent("embedded.mobileprovision").path)
        )
    }
}

// MARK: - What iOS reports about the paired watch

final class WatchStatus: NSObject, ObservableObject, WCSessionDelegate {
    @Published var supported = WCSession.isSupported()
    @Published var activation = "Not started"
    @Published var paired: Bool?
    @Published var watchAppInstalled: Bool?
    @Published var lastError: String?

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
        activation = "Activating…"
    }

    func refresh() {
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        switch s.activationState {
        case .activated: activation = "Activated"
        case .inactive: activation = "Inactive"
        case .notActivated: activation = "Not activated"
        @unknown default: activation = "Unknown"
        }
        if s.activationState == .activated {
            paired = s.isPaired
            watchAppInstalled = s.isWatchAppInstalled
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            self.lastError = error?.localizedDescription
            self.refresh()
        }
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        DispatchQueue.main.async { self.refresh() }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }
}

// MARK: - UI

struct DiagnosticsView: View {
    @StateObject private var watch = WatchStatus()
    @Environment(\.scenePhase) private var scenePhase
    @State private var embedded = BundleInspector.embeddedWatchApp()
    @State private var watchFolderExists = BundleInspector.watchFolderExists

    private var myBundleID: String { Bundle.main.bundleIdentifier ?? "?" }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    verdict
                }

                Section("Inside this app (Watch/ folder)") {
                    Row("Watch/ folder present", watchFolderExists)
                    Row("Watch app embedded", embedded != nil)
                    if let e = embedded {
                        Detail("File", e.fileName)
                        Detail("Watch bundle ID", e.bundleID ?? "missing")
                        Detail("Companion ID", e.companionID ?? "missing")
                        Row("Companion ID matches this app", e.companionID == myBundleID)
                        Row("Watch ID starts with this app's ID", e.bundleID?.hasPrefix(myBundleID + ".") ?? false)
                        Row("WKApplication = YES", e.isWKApplication)
                        Row("Watch app is code-signed", e.hasCodeSignature)
                        Row("Watch app has provisioning profile", e.hasProvisioningProfile)
                    }
                }

                Section("Reported by iOS (WatchConnectivity)") {
                    Row("WatchConnectivity supported", watch.supported)
                    Detail("Session", watch.activation)
                    Row("Apple Watch paired", watch.paired)
                    Row("HelloWatch installed on watch", watch.watchAppInstalled)
                    if let err = watch.lastError {
                        Detail("Error", err)
                    }
                }

                Section("This iPhone app") {
                    Detail("Bundle ID", myBundleID)
                    Detail("Version", "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))")
                }
            }
            .navigationTitle("HelloWatch")
            .toolbar {
                Button("Refresh", systemImage: "arrow.clockwise", action: reload)
            }
            .refreshable { reload() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { reload() }
        }
    }

    @ViewBuilder private var verdict: some View {
        if embedded == nil {
            Label("No watch app inside this install — the signing tool stripped it.", systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
        } else if watch.watchAppInstalled == true {
            Label("Watch app is installed on your Apple Watch.", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
        } else if embedded?.companionID != myBundleID {
            Label("Watch app is embedded but its companion ID doesn't match this app.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else {
            Label("Watch app is embedded but not installed on the watch yet. Check the Watch app → Available Apps.", systemImage: "applewatch")
                .foregroundStyle(.orange)
        }
    }

    private func reload() {
        embedded = BundleInspector.embeddedWatchApp()
        watchFolderExists = BundleInspector.watchFolderExists
        watch.refresh()
    }
}

private struct Row: View {
    let title: String
    let value: Bool?
    init(_ title: String, _ value: Bool?) { self.title = title; self.value = value }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            switch value {
            case .some(true): Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .some(false): Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            case .none: Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
            }
        }
    }
}

private struct Detail: View {
    let title: String
    let value: String
    init(_ title: String, _ value: String) { self.title = title; self.value = value }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.monospaced()).textSelection(.enabled)
        }
    }
}
