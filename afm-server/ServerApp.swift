import Combine
import SwiftUI

#if os(macOS)
struct ServerApp: App {
    @StateObject private var serverController = ServerController()

    var body: some Scene {
        MenuBarExtra("afm-server", systemImage: "bolt.horizontal.circle") {
            VStack(alignment: .leading, spacing: 10) {
                Text("afm-server")
                    .font(.headline)

                Text("Runs AI models on your Mac for private local clients. No cloud required.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                ServerStatusView()
                    .environmentObject(serverController)
                Divider()
            }
            .padding(12)
            .frame(width: 320)
        }
        .commands { // Ensure standard app commands (including Quit) are available
            CommandGroup(replacing: .appInfo) { }
        }
    }
}
#endif

@MainActor
final class ServerController: ObservableObject {
    @Published var isRunning: Bool = false
    @Published var port: UInt16 = 11434
    @Published var errorMessage: String? = nil

    init() {
        AppLog.info("ServerController initialized", source: "server")
        start()
    }

    func start() {
        errorMessage = nil
        AppLog.info("Server start requested on port \(port)", source: "server")
        Task {
            await ServerMetrics.shared.reset()
            await LocalHTTPServer.shared.setPort(port)
            await LocalHTTPServer.shared.start()
            try? await Task.sleep(nanoseconds: 300_000_000)
            let running = await LocalHTTPServer.shared.getIsRunning()
            let error = await LocalHTTPServer.shared.getLastError()
            self.isRunning = running
            self.errorMessage = error
            if running {
                AppLog.info("Server started on port \(self.port)", source: "server")
            } else if let error {
                AppLog.error("Server failed to start: \(error)", source: "server")
            }
        }
    }

    func stop() {
        AppLog.info("Server stop requested", source: "server")
        Task {
            await LocalHTTPServer.shared.stop()
            let running = await LocalHTTPServer.shared.getIsRunning()
            self.isRunning = running
            self.errorMessage = nil
            AppLog.info("Server stopped", source: "server")
        }
    }

    func restart() {
        errorMessage = nil
        AppLog.info("Server restart requested on port \(port)", source: "server")
        Task {
            await LocalHTTPServer.shared.stop()
            await LocalHTTPServer.shared.setPort(port)
            await LocalHTTPServer.shared.start()
            try? await Task.sleep(nanoseconds: 300_000_000)
            let running = await LocalHTTPServer.shared.getIsRunning()
            let error = await LocalHTTPServer.shared.getLastError()
            self.isRunning = running
            self.errorMessage = error
            if running {
                AppLog.info("Server restarted on port \(self.port)", source: "server")
            } else if let error {
                AppLog.error("Server failed to restart: \(error)", source: "server")
            }
        }
    }

    func syncState() {
        Task {
            let running = await LocalHTTPServer.shared.getIsRunning()
            let serverPort = await LocalHTTPServer.shared.getPort()
            let error = await LocalHTTPServer.shared.getLastError()
            self.isRunning = running
            self.port = serverPort
            self.errorMessage = error
        }
    }
}

struct ServerStatusView: View {
    @EnvironmentObject private var server: ServerController
    @State private var localPort: UInt16 = 11434

    private static let portFormatter: NumberFormatter = {
        let nf = NumberFormatter()
        nf.numberStyle = .none
        nf.minimum = 1
        nf.maximum = 65535
        return nf
    }()
    
    private var statusText: String {
        if server.isRunning {
            return "Running on port \(server.port)"
        } else if server.errorMessage != nil {
            return "Failed to start"
        } else {
            return "Stopped"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle()
                    .fill(server.isRunning ? .green : (server.errorMessage != nil ? .orange : .red))
                    .frame(width: 10, height: 10)
                Text(statusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            
            // Show error message if present
            if let error = server.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            HStack(spacing: 8) {
                Button(server.isRunning ? "Restart" : "Start") {
                    server.port = localPort
                    if server.isRunning { server.restart() } else { server.start() }
                }
                Button("Stop") {
                    server.stop()
                }
                .disabled(!server.isRunning)
            }
            HStack(spacing: 6) {
                Text("Port:")
                TextField("Port", value: $localPort, formatter: Self.portFormatter)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
            }
            Text("OpenAI-compatible endpoints:\nPOST /v1/chat/completions\nPOST /v1/completions\nPOST /api/generate\nGET /v1/models\nGET /v1/models/{id}\nGET /api/models\nGET /api/models/{id}\nGET /api/tags\nGET /api/version\nGET /api/ps\nPOST /api/chat")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .id("\(server.isRunning)-\(server.errorMessage ?? "")") // Force menu to refresh when state changes
        .animation(.default, value: server.isRunning)
        .onAppear {
            localPort = server.port
        }
        .onChange(of: server.port) { _, newValue in
            // Keep the text field in sync with external port changes
            localPort = newValue
        }
    }
}
