//
//  ServerDashboardView.swift
//  afm-server
//
//  Main dashboard UI for server management
//

import SwiftUI

struct ServerDashboardView: View {
    private enum DashboardTab: String, CaseIterable {
        case dashboard = "Dashboard"
        case settings = "Settings"
    }

    @EnvironmentObject private var serverController: ServerController
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var appLogStore = AppLogStore.shared
    @State private var localPort: String = "11434"
    @State private var showCopiedToast: Bool = false
    @State private var copiedText: String = ""
    @State private var testResult: String = ""
    @State private var isTesting: Bool = false
    @State private var autoScrollLogs: Bool = true
    @State private var selectedTab: DashboardTab = .dashboard
    @State private var autoStart: Bool = true
    @AppStorage("apiKey") private var currentAPIKey: String = ""
    @State private var customAPIKey: String = ""
    @State private var apiKeyStatusMessage: String = ""
    @State private var apiKeyStatusIsError: Bool = false
    @State private var isSavingAPIKey: Bool = false
    @State private var metrics: MetricsSnapshot = MetricsSnapshot(
        totalRequests: 0, totalInferenceRequests: 0,
        totalTokens: 0, requestsLast5Min: 0,
        averageTTFT: nil, lastTTFT: nil
    )
    @State private var metricsTimer: Timer? = nil
    
    // Native system colors
    private let successColor = Color.green
    private let errorColor = Color.red
    private static let logTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
    
    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Header
                    headerSection

                    tabSelector

                    if selectedTab == .dashboard {
                        // Main Status Card
                        mainStatusCard

                        // Server Stats Card
                        if serverController.isRunning {
                            serverStatsCard
                        }

                        // Server Controls Card
                        serverControlsCard

                        // API Key Card
                        apiKeyCard

                        // Xcode Integration Card
                        xcodeIntegrationCard

                        // API Endpoints Card
                        endpointsCard

                        // Quick Actions Card
                        actionsCard

                        // Connection Test Card
                        testConnectionCard

                        // Logs Card
                        logsCard
                    } else {
                        settingsTabCard
                    }
                    
                    Spacer(minLength: 20)
                }
                .padding(24)
            }
            .background(Color(NSColor.windowBackgroundColor))
            
            // Toast overlay
            if showCopiedToast {
                VStack {
                    Spacer()
                    toastView
                        .padding(.bottom, 40)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(minWidth: 550, minHeight: 700)
        .onAppear {
            syncServerState()
            refreshMetrics()
            metricsTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                Task { @MainActor in
                    refreshMetrics()
                }
            }
        }
        .onDisappear {
            metricsTimer?.invalidate()
            metricsTimer = nil
        }
        .animation(.easeInOut(duration: 0.25), value: showCopiedToast)
    }
    
    // MARK: - Toast View
    
    private var toastView: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(successColor)
                .accessibilityHidden(true)
            Text(copiedText)
                .font(.subheadline.weight(.medium))
                .foregroundColor(.primary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(25)
        .overlay(
            RoundedRectangle(cornerRadius: 25)
                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.2), radius: 10, y: 5)
        .accessibilityLabel(copiedText)
    }
    
    // MARK: - Header Section
    
    private var headerSection: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.2))
                    .frame(width: 60, height: 60)
                
                Image(systemName: "bolt.horizontal.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text("afm-server")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(.primary)
                
                Text("Local AI Server powered by Apple Intelligence")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button(action: {
                openWindow(id: "chat")
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .accessibilityHidden(true)
                    Text("Chat")
                }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("Open chat window")
        }
    }

    private var tabSelector: some View {
        Picker("Section", selection: $selectedTab) {
            ForEach(DashboardTab.allCases, id: \.self) { tab in
                Text(tab.rawValue).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("Dashboard section")
    }

    private var settingsTabCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Settings", systemImage: "gearshape")
                .font(.headline)
                .foregroundColor(.primary)

            Divider()

            SettingsView(embeddedInDashboard: true)
                .frame(minHeight: 560)
        }
        .padding(20)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
        )
    }
    
    // MARK: - Main Status Card
    
    private var serverStatusText: String {
        if serverController.isRunning {
            return "Server Running"
        } else if serverController.errorMessage != nil {
            return "Server Error"
        } else {
            return "Server Stopped"
        }
    }
    
    private var statusIndicatorColor: Color {
        if serverController.isRunning {
            return successColor
        } else if serverController.errorMessage != nil {
            return .orange
        } else {
            return errorColor
        }
    }
    
    private var mainStatusCard: some View {
        HStack(spacing: 0) {
            // Left side - Status
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(statusIndicatorColor.opacity(0.2))
                            .frame(width: 44, height: 44)
                        
                        Circle()
                            .fill(statusIndicatorColor)
                            .frame(width: 18, height: 18)
                            .shadow(color: statusIndicatorColor.opacity(0.6), radius: 8)
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(serverStatusText)
                            .font(.title2.weight(.semibold))
                            .foregroundColor(.primary)
                        
                        if serverController.isRunning {
                            Text(verbatim: "Listening on port \(serverController.port)")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        } else if let error = serverController.errorMessage {
                            Text(error)
                                .font(.subheadline)
                                .foregroundColor(errorColor)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("Click Start to begin")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                if serverController.isRunning {
                    HStack(spacing: 8) {
                        Label {
                            Text(verbatim: "http://127.0.0.1:\(serverController.port)")
                        } icon: {
                            Image(systemName: "link")
                        }
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.accentColor)
                        
                        Button(action: {
                            copyToClipboard(
                                endpointDetails(path: "", includeOpenAIBaseURL: false),
                                message: "Base URL details copied"
                            )
                        }) {
                            Image(systemName: "doc.on.doc")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(copiedAccessibilityLabel(defaultLabel: "Copy base URL", copiedLabel: "Base URL copied", copiedMessage: "Base URL details copied"))
                        .accessibilityValue(copiedAccessibilityValue(copiedMessage: "Base URL details copied"))
                        .accessibilityHint("Copies the base URL details to the clipboard")
                    }

                }
            }

            Spacer()

            // Right side - Big action button
            Button(action: {
                if serverController.isRunning {
                    serverController.stop()
                    AppLog.info("Server stop requested from dashboard", source: "dashboard")
                } else {
                    if let portNum = UInt16(localPort) {
                        serverController.port = portNum
                    }
                    serverController.start()
                    AppLog.info("Server start requested from dashboard (port \(serverController.port))", source: "dashboard")
                }
            }) {
                VStack(spacing: 8) {
                    Image(systemName: serverController.isRunning ? "stop.circle.fill" : "play.circle.fill")
                        .font(.system(size: 40))
                        .accessibilityHidden(true)
                    Text(serverController.isRunning ? "Stop Server" : "Start Server")
                        .font(.headline)
                }
                .foregroundColor(.white)
                .frame(width: 120, height: 120)
                .background(serverController.isRunning ? errorColor : successColor)
                .cornerRadius(16)
            }
            .buttonStyle(.plain)
            .focusable()
            .accessibilityLabel(serverController.isRunning ? "Stop server" : "Start server")
            .accessibilityHint(serverController.isRunning ? "Double tap to stop the server" : "Double tap to start the server")
        }
        .padding(24)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(serverController.isRunning ? successColor.opacity(0.3) : Color(NSColor.separatorColor), lineWidth: 1)
        )
    }

    private var loadedAdapterCount: Int {
        FoundationModelAdapterRegistry.loadRecords().count
    }

    private var modelSummaryText: String {
        let count = loadedAdapterCount
        if count == 0 {
            return "apple.local:latest"
        }
        return "apple.local:latest + \(count) adapter\(count == 1 ? "" : "s")"
    }

    // MARK: - API Key Card

    private var apiKeyCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("API Key", systemImage: "key.horizontal.fill")
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()

                Button(action: {
                    copyToClipboard(currentAPIKey, message: "API key copied")
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc")
                            .accessibilityHidden(true)
                        Text("Copy Key")
                    }
                    .font(.caption.weight(.medium))
                    .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(currentAPIKey.isEmpty)
                .accessibilityLabel(copiedAccessibilityLabel(defaultLabel: "Copy API key", copiedLabel: "API key copied", copiedMessage: "API key copied"))
                .accessibilityValue(copiedAccessibilityValue(copiedMessage: "API key copied"))
            }

            Divider()

            Text("Set this to the same API key used by Hermes, OpenClaw, Pi, or any OpenAI-compatible client.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("Current API key")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(currentAPIKey.isEmpty ? "No API key saved yet." : currentAPIKey)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(currentAPIKey.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
            }

            HStack(spacing: 10) {
                SecureField("Set API key", text: $customAPIKey)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("API key")
                    .accessibilityHint("Enter the API key clients should send")

                Button("Save") {
                    saveAPIKey()
                }
                .disabled(isSavingAPIKey || LocalHTTPServer.authTokenValidationMessage(for: customAPIKey) != nil)

                Button("Generate") {
                    generateAPIKey()
                }
                .disabled(isSavingAPIKey)
            }

            if !apiKeyStatusMessage.isEmpty {
                Text(apiKeyStatusMessage)
                    .font(.caption)
                    .foregroundStyle(apiKeyStatusIsError ? .red : .green)
            }
        }
        .padding(20)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
        )
    }

    // MARK: - Server Controls Card

    private var serverControlsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Server Configuration", systemImage: "gearshape.fill")
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()
            }
            
            Divider()
            
            // Port Configuration
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Port Number")
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.secondary)
                    
                    HStack(spacing: 0) {
                        TextField("Port", text: $localPort)
                            .textFieldStyle(.plain)
                            .font(.system(size: 20, weight: .semibold, design: .monospaced))
                            .foregroundColor(.primary)
                            .frame(width: 80)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(Color(NSColor.textBackgroundColor))
                            .accessibilityLabel("Port number")
                            .accessibilityValue(localPort)
                        
                        // Stepper buttons
                        VStack(spacing: 0) {
                            Button(action: {
                                if let port = UInt16(localPort), port < 65535 {
                                    localPort = String(port + 1)
                                }
                            }) {
                                Image(systemName: "chevron.up")
                                    .font(.caption.weight(.bold))
                                    .foregroundColor(.secondary)
                                    .frame(width: 30, height: 20)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Increase port")
                            
                            Divider()
                            
                            Button(action: {
                                if let port = UInt16(localPort), port > 1 {
                                    localPort = String(port - 1)
                                }
                            }) {
                                Image(systemName: "chevron.down")
                                    .font(.caption.weight(.bold))
                                    .foregroundColor(.secondary)
                                    .frame(width: 30, height: 20)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Decrease port")
                        }
                        .background(Color(NSColor.controlBackgroundColor))
                    }
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                    )
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Presets")
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.secondary)
                    
                    HStack(spacing: 8) {
                        portPresetButton("11434", label: "Default")
                        portPresetButton("11435", label: "Alt 1")
                        portPresetButton("8080", label: "Alt 2")
                    }
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 8) {
                    Text("Actions")
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.secondary)
                    
                    HStack(spacing: 8) {
                        Button(action: {
                            if let portNum = UInt16(localPort) {
                                serverController.port = portNum
                                if serverController.isRunning {
                                    serverController.restart()
                                    AppLog.info("Server restart requested from dashboard (port \(portNum))", source: "dashboard")
                                } else {
                                    serverController.start()
                                    AppLog.info("Server start requested from dashboard (port \(portNum))", source: "dashboard")
                                }
                            }
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: serverController.isRunning ? "arrow.clockwise" : "play.fill")
                                    .accessibilityHidden(true)
                                Text(serverController.isRunning ? "Restart" : "Start")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityLabel(serverController.isRunning ? "Restart server with new port" : "Start server")
                    }
                }
            }
            
            // Model info
            HStack(spacing: 12) {
                Image(systemName: "cube.fill")
                    .foregroundColor(.accentColor)
                    .accessibilityHidden(true)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Models")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.primary)
                    Text(modelSummaryText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            .padding(12)
            .background(Color(NSColor.textBackgroundColor))
            .cornerRadius(8)
        }
        .padding(20)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
        )
    }
    
    private func portPresetButton(_ port: String, label: String) -> some View {
        Button(action: {
            localPort = port
        }) {
            VStack(spacing: 2) {
                Text(port)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                Text(label)
                    .font(.system(size: 9))
            }
            .foregroundColor(localPort == port ? .white : .secondary)
            .frame(width: 60, height: 44)
            .background(localPort == port ? Color.accentColor : Color(NSColor.textBackgroundColor))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(localPort == port ? Color.accentColor : Color(NSColor.separatorColor), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label), port \(port)")
        .accessibilityAddTraits(localPort == port ? .isSelected : [])
    }
    
    // MARK: - Xcode Integration Card
    
    private var xcodeIntegrationCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Xcode 26 Integration", systemImage: "hammer.fill")
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 12) {
                Text("To use with Xcode 26 Intelligence Mode:")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                instructionRow(number: 1, text: "Open Xcode > Settings > Intelligence")
                instructionRow(number: 2, text: "Click Add a Model Provider > Locally Hosted")
                instructionRow(number: 3, text: "Enter port: \(localPort)")
                instructionRow(number: 4, text: loadedAdapterCount == 0 ? "Select apple.local:latest from the model list" : "Select apple.local:latest or an adapter model")
                
                HStack(spacing: 12) {
                    infoBox(title: "Port", value: localPort, icon: "network")
                    infoBox(title: "Models", value: "\(loadedAdapterCount + 1) available", icon: "cube")
                    infoBox(title: "Protocol", value: "Ollama API", icon: "arrow.left.arrow.right")
                }
                .padding(.top, 8)
            }
        }
        .padding(20)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
        )
    }
    
    private func instructionRow(number: Int, text: String) -> some View {
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundColor(.white)
                .frame(width: 22, height: 22)
                .background(Color.accentColor)
                .clipShape(Circle())
            
            Text(text)
                .font(.subheadline)
                .foregroundColor(.primary)
            
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number): \(text)")
    }
    
    private func infoBox(title: String, value: String, icon: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.accentColor)
                .accessibilityHidden(true)
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color(NSColor.textBackgroundColor))
        .cornerRadius(8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }
    
    // MARK: - Endpoints Card
    
    private var endpointsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("API Endpoints", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()
                
                Button(action: {
                    copyToClipboard(
                        endpointDetails(path: "/v1", includeOpenAIBaseURL: true),
                        message: "OpenAI setup details copied"
                    )
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc")
                            .accessibilityHidden(true)
                        Text("Copy URL")
                    }
                    .font(.caption.weight(.medium))
                    .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(copiedAccessibilityLabel(defaultLabel: "Copy OpenAI base URL", copiedLabel: "OpenAI base URL copied", copiedMessage: "OpenAI setup details copied"))
                .accessibilityValue(copiedAccessibilityValue(copiedMessage: "OpenAI setup details copied"))
                .accessibilityHint("Copies the OpenAI base URL details to the clipboard")
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 6) {
                endpointRow(method: "GET", path: "/api/tags", description: "List models (Xcode/Ollama)")
                endpointRow(method: "POST", path: "/api/chat", description: "Chat (Ollama format)")
                endpointRow(method: "GET", path: "/v1/models", description: "List models (OpenAI)")
                endpointRow(method: "POST", path: "/v1/chat/completions", description: "Chat (OpenAI)")
                endpointRow(method: "POST", path: "/v1/completions", description: "Completions")
                endpointRow(method: "GET", path: "/debug/health", description: "Health check")
            }
        }
        .padding(20)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
        )
    }
    
    private func endpointRow(method: String, path: String, description: String) -> some View {
        HStack(spacing: 12) {
            Text(method)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.primary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(method == "GET" ? Color.green.opacity(0.2) : Color.orange.opacity(0.2))
                .cornerRadius(4)
                .frame(width: 50)
            
            Text(path)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(.primary)
                .frame(width: 170, alignment: .leading)
            
            Text(description)
                .font(.caption)
                .foregroundColor(.secondary)
            
            Spacer()
            
            Button(action: {
                copyToClipboard(
                    endpointDetails(path: path),
                    message: "Endpoint details copied"
                )
            }) {
                Image(systemName: "doc.on.doc")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(copiedAccessibilityLabel(defaultLabel: "Copy endpoint URL", copiedLabel: "Endpoint copied", copiedMessage: "Endpoint details copied"))
            .accessibilityValue(copiedAccessibilityValue(copiedMessage: "Endpoint details copied"))
            .accessibilityHint("Copies the endpoint details to the clipboard")
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(method) \(path), \(description)")
    }
    
    // MARK: - Actions Card
    
    private var actionsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Quick Actions", systemImage: "bolt.fill")
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()
            }
            
            Divider()
            
            HStack(spacing: 12) {
                actionButton(
                    title: "Copy cURL",
                    subtitle: "Test command",
                    icon: "terminal",
                    accessibilityLabel: copiedAccessibilityLabel(defaultLabel: "Copy cURL, Test command", copiedLabel: "cURL command copied", copiedMessage: "cURL command copied"),
                    accessibilityValue: copiedAccessibilityValue(copiedMessage: "cURL command copied"),
                    action: {
                        let token = loadStoredAPIKey()
                        let cmd = token.isEmpty
                            ? "curl http://127.0.0.1:\(serverController.port)/api/tags"
                            : "curl -H \"Authorization: Bearer \(token)\" http://127.0.0.1:\(serverController.port)/api/tags"
                        copyToClipboard(cmd, message: "cURL command copied")
                    }
                )
                
                actionButton(
                    title: "Settings",
                    subtitle: "Preferences",
                    icon: "gearshape",
                    action: {
                        selectedTab = .settings
                    }
                )
                
                actionButton(
                    title: "Chat",
                    subtitle: "Test AI",
                    icon: "bubble.left.and.bubble.right",
                    action: {
                        openWindow(id: "chat")
                    }
                )
                
                actionButton(
                    title: "Docs",
                    subtitle: "README",
                    icon: "book",
                    action: {
                        if let url = URL(string: "https://github.com") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                )
            }
        }
        .padding(20)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
        )
    }
    
    private func actionButton(
        title: String,
        subtitle: String,
        icon: String,
        accessibilityLabel: String? = nil,
        accessibilityValue: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.title2)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(subtitle)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .foregroundColor(.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Color(NSColor.textBackgroundColor))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(NSColor.separatorColor), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel ?? "\(title), \(subtitle)")
        .accessibilityValue(accessibilityValue ?? "")
    }
    
    // MARK: - Test Connection Card
    
    private var testConnectionCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Connection Test", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()
            }
            
            Divider()
            
            HStack(spacing: 16) {
                Button(action: testConnection) {
                    HStack(spacing: 10) {
                        if isTesting {
                            ProgressView()
                                .scaleEffect(0.8)
                                .progressViewStyle(CircularProgressViewStyle())
                        } else {
                            Image(systemName: "play.fill")
                                .accessibilityHidden(true)
                        }
                        Text(isTesting ? "Testing..." : "Run Test")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isTesting || !serverController.isRunning)
                .accessibilityLabel(isTesting ? "Testing connection" : "Run connection test")
                
                if !serverController.isRunning {
                    Text("Start the server to test")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            
            if !testResult.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: testResult.contains("Success") ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(testResult.contains("Success") ? successColor : .orange)
                        .accessibilityHidden(true)
                    
                    Text(testResult)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(testResult.contains("Success") ? successColor : .orange)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(10)
                .accessibilityLabel("Test result: \(testResult)")
            }
        }
        .padding(20)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
        )
    }
    
    // MARK: - Server Stats Card

    private var serverStatsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Server Stats", systemImage: "chart.bar.fill")
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()

                Text("Updates every 2s")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Divider()

            HStack(spacing: 12) {
                statBox(
                    title: "Requests",
                    value: "\(metrics.totalRequests)",
                    subtitle: "\(metrics.requestsLast5Min) in last 5 min",
                    icon: "arrow.up.arrow.down"
                )

                statBox(
                    title: "Tokens",
                    value: formatNumber(metrics.totalTokens),
                    subtitle: "generated",
                    icon: "textformat.abc"
                )

                statBox(
                    title: "Avg TTFT",
                    value: formatTTFT(metrics.averageTTFT),
                    subtitle: "time to first token",
                    icon: "clock"
                )

                statBox(
                    title: "Last TTFT",
                    value: formatTTFT(metrics.lastTTFT),
                    subtitle: "most recent",
                    icon: "clock.arrow.circlepath"
                )
            }
        }
        .padding(20)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Server statistics")
    }

    private func statBox(title: String, value: String, subtitle: String, icon: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.accentColor)
                .accessibilityHidden(true)
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .monospaced))
                .foregroundColor(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundColor(.primary)
            Text(subtitle)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color(NSColor.textBackgroundColor))
        .cornerRadius(10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value), \(subtitle)")
    }

    private func formatTTFT(_ value: Double?) -> String {
        guard let v = value, v >= 0 else { return "--" }
        if v < 1 {
            return String(format: "%.0fms", v * 1000)
        } else {
            return String(format: "%.1fs", v)
        }
    }

    private func formatNumber(_ n: Int) -> String {
        if n >= 1_000_000 {
            return String(format: "%.1fM", Double(n) / 1_000_000)
        } else if n >= 1_000 {
            return String(format: "%.1fK", Double(n) / 1_000)
        }
        return "\(n)"
    }

    // MARK: - Logs Card

    private var logsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Logs", systemImage: "text.alignleft")
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()
                Toggle("Auto-scroll", isOn: $autoScrollLogs)
                    .toggleStyle(.switch)
                    .font(.caption)
                    .labelsHidden()
                    .help("Automatically scroll to newest log entries")
                Button("Copy") {
                    copyToClipboard(appLogStore.exportText(), message: "Logs copied")
                }
                .buttonStyle(.bordered)
                .disabled(appLogStore.entries.isEmpty)
                Button("Clear") {
                    appLogStore.clear()
                    AppLog.info("Logs cleared from dashboard", source: "dashboard")
                }
                .buttonStyle(.bordered)
                .disabled(appLogStore.entries.isEmpty)
            }

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    if appLogStore.entries.isEmpty {
                        Text("No log entries yet.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(appLogStore.entries) { entry in
                                logRow(entry)
                                    .id(entry.id)
                            }
                        }
                        .textSelection(.enabled)
                        .padding(.vertical, 2)
                    }
                }
                .frame(minHeight: 150, maxHeight: 220)
                .padding(10)
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(10)
                .onAppear {
                    scrollLogsToBottom(proxy)
                }
                .onChange(of: appLogStore.entries.count) { _, _ in
                    scrollLogsToBottom(proxy)
                }
            }
        }
        .padding(20)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
        )
    }

    private func logRow(_ entry: AppLogEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(Self.logTimeFormatter.string(from: entry.timestamp))
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 58, alignment: .leading)

            Text(entry.severity.label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(severityColor(entry.severity))
                .frame(width: 52, alignment: .leading)

            Text("[\(entry.source)] \(entry.message)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
    }

    private func severityColor(_ severity: AppLogSeverity) -> Color {
        switch severity {
        case .debug:
            return .secondary
        case .info:
            return .blue
        case .warning:
            return .orange
        case .error:
            return errorColor
        }
    }

    private func scrollLogsToBottom(_ proxy: ScrollViewProxy) {
        guard autoScrollLogs, let lastID = appLogStore.entries.last?.id else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(lastID, anchor: .bottom)
        }
    }

    @MainActor
    private func refreshMetrics() {
        Task {
            let snap = await ServerMetrics.shared.snapshot
            metrics = snap
        }
    }

    // MARK: - Helper Methods

    private func syncServerState() {
        Task {
            let running = await LocalHTTPServer.shared.getIsRunning()
            let port = await LocalHTTPServer.shared.getPort()
            let error = await LocalHTTPServer.shared.getLastError()
            await MainActor.run {
                serverController.isRunning = running
                serverController.port = port
                serverController.errorMessage = error
                localPort = String(port)
            }
        }
    }
    
    private func copyToClipboard(_ text: String, message: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedText = message
        showCopiedToast = true
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            showCopiedToast = false
        }
    }

    private func saveAPIKey() {
        let token = LocalHTTPServer.normalizedAuthToken(customAPIKey)
        if let validationMessage = LocalHTTPServer.authTokenValidationMessage(for: token) {
            apiKeyStatusMessage = validationMessage
            apiKeyStatusIsError = true
            return
        }

        isSavingAPIKey = true
        Task {
            do {
                try await LocalHTTPServer.shared.setAuthToken(token)
                await MainActor.run {
                    currentAPIKey = token
                    customAPIKey = ""
                    apiKeyStatusMessage = "API key saved. Update Hermes or other clients to use this same value."
                    apiKeyStatusIsError = false
                    isSavingAPIKey = false
                    AppLog.info("API key saved from dashboard", source: "auth")
                }
            } catch {
                await MainActor.run {
                    apiKeyStatusMessage = error.localizedDescription
                    apiKeyStatusIsError = true
                    isSavingAPIKey = false
                    AppLog.error("API key save failed: \(error.localizedDescription)", source: "auth")
                }
            }
        }
    }

    private func generateAPIKey() {
        isSavingAPIKey = true
        Task {
            do {
                let token = try await LocalHTTPServer.shared.rotateAuthToken()
                await MainActor.run {
                    currentAPIKey = token
                    customAPIKey = ""
                    apiKeyStatusMessage = "Generated a new API key. Update Hermes or other clients before using them again."
                    apiKeyStatusIsError = false
                    isSavingAPIKey = false
                    AppLog.info("API key generated from dashboard", source: "auth")
                }
            } catch {
                await MainActor.run {
                    apiKeyStatusMessage = error.localizedDescription
                    apiKeyStatusIsError = true
                    isSavingAPIKey = false
                    AppLog.error("API key generation failed: \(error.localizedDescription)", source: "auth")
                }
            }
        }
    }
    
    private func testConnection() {
        isTesting = true
        testResult = ""
        
        Task {
            let url = URL(string: "http://127.0.0.1:\(serverController.port)/api/tags")!
            do {
                var request = URLRequest(url: url)
                if let token = await LocalHTTPServer.shared.getAuthToken() {
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                }
                let (data, response) = try await URLSession.shared.data(for: request)
                
                if let httpResponse = response as? HTTPURLResponse {
                    if httpResponse.statusCode == 200 {
                        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let models = json["models"] as? [[String: Any]] {
                            let modelNames = models.compactMap { $0["name"] as? String }
                            await MainActor.run {
                                if modelNames.isEmpty {
                                    testResult = "Success! Server responded. No models listed."
                                } else {
                                    testResult = "Success! Models found:\n• " + modelNames.joined(separator: "\n• ")
                                }
                                isTesting = false
                                AppLog.info("Connection test passed", source: "dashboard")
                            }
                        } else {
                            await MainActor.run {
                                testResult = "Success! Server responded (status 200)"
                                isTesting = false
                            }
                        }
                    } else {
                        await MainActor.run {
                            testResult = "Server returned status \(httpResponse.statusCode)"
                            isTesting = false
                            AppLog.error("Connection test failed: status \(httpResponse.statusCode)", source: "dashboard")
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    testResult = "Connection failed:\n\(error.localizedDescription)"
                    isTesting = false
                    AppLog.error("Connection test failed: \(error.localizedDescription)", source: "dashboard")
                }
            }
        }
    }

    // Protected API routes require the configured API key.

    private func loadStoredAPIKey() -> String {
        currentAPIKey
    }

    private func isCopied(_ copiedMessage: String) -> Bool {
        showCopiedToast && copiedText == copiedMessage
    }

    private func copiedAccessibilityLabel(defaultLabel: String, copiedLabel: String, copiedMessage: String) -> String {
        isCopied(copiedMessage) ? copiedLabel : defaultLabel
    }

    private func copiedAccessibilityValue(copiedMessage: String) -> String {
        isCopied(copiedMessage) ? "Copied to clipboard" : ""
    }

    private func endpointDetails(path: String, includeOpenAIBaseURL: Bool = false) -> String {
        let baseURL = "http://127.0.0.1:\(serverController.port)"
        let fullURL = "\(baseURL)\(path)"

        var lines = ["URL: \(fullURL)"]
        if includeOpenAIBaseURL {
            lines.append("OpenAI Base URL: \(fullURL)")
        }

        let token = loadStoredAPIKey()
        if token.isEmpty {
            lines.append("API Key: <set one in afm-server Settings>")
            lines.append("Authorization: Bearer <API key>")
        } else {
            lines.append("API Key: \(token)")
            lines.append("Authorization: Bearer \(token)")
        }

        return lines.joined(separator: "\n")
    }
}

#Preview {
    ServerDashboardView()
        .environmentObject(ServerController())
}
