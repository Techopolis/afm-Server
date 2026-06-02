//
//  SettingsView.swift
//  afm-server
//
//  Created by GitHub Copilot on 9/14/25.
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

struct SettingsView: View {
    let embeddedInDashboard: Bool

    init(embeddedInDashboard: Bool = false) {
        self.embeddedInDashboard = embeddedInDashboard
    }

    @AppStorage("systemPrompt") private var systemPrompt: String = "You are a helpful assistant. Keep responses concise and relevant."
    @AppStorage("includeSystemPrompt") private var includeSystemPrompt: Bool = false
    @AppStorage("debugLogging") private var debugLogging: Bool = false
    @AppStorage("includeHistory") private var includeHistory: Bool = true
    @AppStorage("enableBetaUpdates") private var enableBetaUpdates: Bool = false
    @AppStorage("apiKey") private var currentAPIKey: String = ""
    @State private var customAPIKey: String = ""
    @State private var tokenStatusMessage: String = ""
    @State private var tokenStatusIsError: Bool = false
    @State private var isSavingToken: Bool = false

    var body: some View {
        Group {
            if embeddedInDashboard {
                dashboardEmbeddedContent
            } else {
                formContent
                    .padding()
                    .frame(minWidth: 460, minHeight: 440)
            }
        }
    }

    private var formContent: some View {
        Form {
            Toggle("Include System Prompt", isOn: $includeSystemPrompt)
                .accessibilityLabel("Include system prompt")
                .accessibilityHint("Turn off to send chats without the system instruction")
            Toggle("Enable Debug Logging", isOn: $debugLogging)
                .accessibilityLabel("Enable debug logging")
                .accessibilityHint("Print requests and responses to the console for troubleshooting")
            Toggle("Include Conversation History", isOn: $includeHistory)
                .accessibilityLabel("Include conversation history")
                .accessibilityHint("Turn off to send only the latest user message")
            Toggle("Receive Beta Updates", isOn: $enableBetaUpdates)
                .accessibilityLabel("Receive beta updates")
                .accessibilityHint("Get early access to new features before stable release")

            Section(header: Text("System Prompt")) {
                TextEditor(text: $systemPrompt)
                    .frame(minHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                    .accessibilityLabel("System prompt")
                    .accessibilityHint("Text used as the assistant's system instruction")
                HStack {
                    Spacer()
                    Button("Reset to Default") {
                        systemPrompt = "You are a helpful assistant. Keep responses concise and relevant."
                        includeSystemPrompt = true
                    }
                }
            }

            Section(header: Text("API Key")) {
                apiKeyControls
            }

            Section(header: Text("Foundation Model Adapters")) {
                FoundationModelAdapterSettingsView()
            }

            Text("The system prompt (if enabled) is sent with each chat to guide the assistant's behavior.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var dashboardEmbeddedContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                card(title: "General", systemImage: "switch.2") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Include System Prompt", isOn: $includeSystemPrompt)
                        Toggle("Enable Debug Logging", isOn: $debugLogging)
                        Toggle("Include Conversation History", isOn: $includeHistory)
                        Toggle("Receive Beta Updates", isOn: $enableBetaUpdates)
                    }
                }

                card(title: "System Prompt", systemImage: "text.quote") {
                    VStack(alignment: .leading, spacing: 10) {
                        TextEditor(text: $systemPrompt)
                            .frame(minHeight: 120)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                            .accessibilityLabel("System prompt")
                        HStack {
                            Spacer()
                            Button("Reset to Default") {
                                systemPrompt = "You are a helpful assistant. Keep responses concise and relevant."
                                includeSystemPrompt = true
                            }
                        }
                        Text("The system prompt (if enabled) is sent with each chat to guide the assistant's behavior.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                card(title: "API Key", systemImage: "key.horizontal") {
                    apiKeyControls
                }

                card(title: "Foundation Model Adapters", systemImage: "shippingbox") {
                    FoundationModelAdapterSettingsView()
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var apiKeyControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("OpenAI-compatible clients use this value as their API key. afm-server accepts it as `Authorization: Bearer <API key>`.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Current API key")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(currentAPIKey.isEmpty ? "No API key saved yet." : currentAPIKey)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(currentAPIKey.isEmpty ? .secondary : .primary)
            }

            SecureField("Set API key", text: $customAPIKey)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("API key")
                .accessibilityHint("Enter the API key Hermes, OpenClaw, Pi, or another client should use")

            Text("Use any stable value longer than 4 characters. Set the same value in Hermes, OpenClaw, Pi, or any OpenAI-compatible client.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Save API Key") {
                    saveCustomAPIKey()
                }
                .disabled(isSavingToken || LocalHTTPServer.authTokenValidationMessage(for: customAPIKey) != nil)

                Button("Generate API Key") {
                    rotateAPIKey()
                }
                .disabled(isSavingToken)

                Button("Copy API Key") {
                    copyAPIKey()
                }
                .disabled(currentAPIKey.isEmpty)
            }

            if !tokenStatusMessage.isEmpty {
                Text(tokenStatusMessage)
                    .font(.caption)
                    .foregroundStyle(tokenStatusIsError ? .red : .green)
            }
        }
    }

    private func card<Content: View>(title: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            Divider()
            content()
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
        )
    }

    private func saveCustomAPIKey() {
        let token = LocalHTTPServer.normalizedAuthToken(customAPIKey)
        if let validationMessage = LocalHTTPServer.authTokenValidationMessage(for: token) {
            tokenStatusMessage = validationMessage
            tokenStatusIsError = true
            return
        }

        isSavingToken = true
        Task {
            do {
                try await LocalHTTPServer.shared.setAuthToken(token)
                await MainActor.run {
                    currentAPIKey = token
                    customAPIKey = ""
                    tokenStatusMessage = "API key saved."
                    tokenStatusIsError = false
                    isSavingToken = false
                }
            } catch {
                await MainActor.run {
                    tokenStatusMessage = error.localizedDescription
                    tokenStatusIsError = true
                    isSavingToken = false
                }
            }
        }
    }

    private func rotateAPIKey() {
        isSavingToken = true
        Task {
            do {
                let token = try await LocalHTTPServer.shared.rotateAuthToken()
                await MainActor.run {
                    currentAPIKey = token
                    customAPIKey = ""
                    tokenStatusMessage = "Generated a new API key."
                    tokenStatusIsError = false
                    isSavingToken = false
                }
            } catch {
                await MainActor.run {
                    tokenStatusMessage = error.localizedDescription
                    tokenStatusIsError = true
                    isSavingToken = false
                }
            }
        }
    }

    private func copyAPIKey() {
        guard !currentAPIKey.isEmpty else { return }
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(currentAPIKey, forType: .string)
        tokenStatusMessage = "API key copied."
        tokenStatusIsError = false
        #endif
    }
}

#Preview {
    SettingsView()
}
