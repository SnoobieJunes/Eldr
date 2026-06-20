import Network
import SwiftUI

/// Browses the local network for the Bonjour services EldrChat / the Eldr node advertise,
/// answering the "is my Mac node broadcasting, and does this machine actually see the
/// other device?" question without guesswork. Pure discovery (no connection, no payload).
@MainActor
final class NearbyScanner: ObservableObject {
    /// The service types EldrChat / the node use (Info.plist NSBonjourServices).
    static let serviceTypes: [(label: String, type: String)] = [
        ("ACP bridge (coding agent)", "_eldr-acp._tcp"),
        ("Pocket relay", "_pqrc-relay._tcp"),
        ("Nearby message mesh", "_pqrc-local._tcp"),
    ]

    @Published private(set) var found: [String: [String]] = [:]  // type -> instance names
    @Published private(set) var browsing = false
    private var browsers: [NWBrowser] = []

    func toggle() { browsing ? stop() : start() }

    func start() {
        stop()
        browsing = true
        for (_, type) in Self.serviceTypes {
            let params = NWParameters()
            params.includePeerToPeer = true
            let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: params)
            browser.browseResultsChangedHandler = { results, _ in
                let names: [String] = results.compactMap { result in
                    if case let .service(name, _, _, _) = result.endpoint { return name }
                    return nil
                }.sorted()
                Task { @MainActor in self.found[type] = names }
            }
            browser.start(queue: .main)
            browsers.append(browser)
        }
    }

    func stop() {
        browsers.forEach { $0.cancel() }
        browsers.removeAll()
        browsing = false
        found.removeAll()
    }
}

struct NearbyScannerView: View {
    @StateObject private var scanner = NearbyScanner()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Nearby Multipeer / Bonjour scanner").font(.headline)
                    Text("Discovers Eldr services advertised on this network. Run it on the Mac to confirm the phone is visible (and vice-versa).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(scanner.browsing ? "Stop" : "Scan") { scanner.toggle() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            List {
                ForEach(Self.rows(scanner), id: \.type) { row in
                    Section(row.label + "  (" + row.type + ")") {
                        if row.names.isEmpty {
                            Text(scanner.browsing ? "Scanning… none seen yet" : "Not scanning")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            ForEach(row.names, id: \.self) { name in
                                Label(name, systemImage: "dot.radiowaves.left.and.right")
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
        .onDisappear { scanner.stop() }
    }

    private static func rows(_ s: NearbyScanner)
        -> [(label: String, type: String, names: [String])]
    {
        NearbyScanner.serviceTypes.map { ($0.label, $0.type, s.found[$0.type] ?? []) }
    }
}
