//
//  FoundationModelAdapterSettingsView.swift
//  afm-server
//

import Combine
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

extension UTType {
    static var foundationModelAdapter: UTType {
        UTType(filenameExtension: "fmadapter") ?? .data
    }

    static var appleAssetArchive: UTType {
        UTType(filenameExtension: "aar") ?? .data
    }
}

@MainActor
final class FoundationModelAdapterStore: ObservableObject {
    @Published private(set) var adapters: [FoundationModelAdapterRecord] = []
    @Published var isImporting: Bool = false
    @Published var statusMessage: String = ""
    @Published var statusIsError: Bool = false

    init() {
        refresh()
    }

    func refresh() {
        adapters = FoundationModelAdapterRegistry.loadRecords()
    }

    func importAdapters(from urls: [URL]) async {
        guard !urls.isEmpty else { return }

        isImporting = true
        statusMessage = urls.count == 1 ? "Loading adapter..." : "Loading adapters..."
        statusIsError = false

        var imported: [FoundationModelAdapterRecord] = []

        for url in urls {
            do {
                let record = try await FoundationModelAdapterRegistry.importAdapter(from: url)
                imported.append(record)
            } catch {
                statusMessage = error.localizedDescription
                statusIsError = true
                isImporting = false
                refresh()
                return
            }
        }

        refresh()
        isImporting = false
        statusIsError = false
        if imported.count == 1, let first = imported.first {
            statusMessage = "Loaded \(first.displayName)."
        } else {
            statusMessage = "Loaded \(imported.count) adapters."
        }
    }

    func remove(_ record: FoundationModelAdapterRecord) {
        do {
            try FoundationModelAdapterRegistry.removeAdapter(id: record.id)
            refresh()
            statusMessage = "Removed \(record.displayName)."
            statusIsError = false
        } catch {
            statusMessage = error.localizedDescription
            statusIsError = true
        }
    }
}

struct FoundationModelAdapterSettingsView: View {
    @StateObject private var store = FoundationModelAdapterStore()
    @State private var isImporterPresented = false

    private let adapterContentTypes: [UTType] = [
        .foundationModelAdapter,
        .appleAssetArchive,
        .package,
        .data
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Loaded Adapters")
                        .font(.subheadline.weight(.semibold))
                    Text("Adapters appear as selectable Apple local models.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    store.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Refresh adapters")

                Button {
                    isImporterPresented = true
                } label: {
                    Label("Load Adapter", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isImporting)
            }

            if store.isImporting {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(store.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if !store.statusMessage.isEmpty {
                Text(store.statusMessage)
                    .font(.caption)
                    .foregroundStyle(store.statusIsError ? .red : .green)
            }

            if store.adapters.isEmpty {
                emptyState
            } else {
                VStack(spacing: 8) {
                    ForEach(store.adapters) { adapter in
                        adapterRow(adapter)
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: adapterContentTypes,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task {
                    await store.importAdapters(from: urls)
                }
            case .failure(let error):
                store.statusMessage = error.localizedDescription
                store.statusIsError = true
            }
        }
        .onAppear {
            store.refresh()
        }
    }

    private var emptyState: some View {
        HStack(spacing: 10) {
            Image(systemName: "shippingbox")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("No adapters loaded")
                    .font(.subheadline)
                Text("Choose a .fmadapter file to add one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(12)
        .background(Color(NSColor.textBackgroundColor))
        .cornerRadius(8)
    }

    private func adapterRow(_ adapter: FoundationModelAdapterRecord) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "brain.head.profile")
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(adapter.displayName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)

                Text(adapter.ollamaModelName)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Spacer()

            Button {
                copyModelName(adapter.ollamaModelName)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Copy model name for \(adapter.displayName)")

            Button(role: .destructive) {
                store.remove(adapter)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove \(adapter.displayName)")
        }
        .padding(10)
        .background(Color(NSColor.textBackgroundColor))
        .cornerRadius(8)
    }

    private func copyModelName(_ modelName: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(modelName, forType: .string)
        #endif
        store.statusMessage = "Model name copied."
        store.statusIsError = false
    }
}

#Preview {
    FoundationModelAdapterSettingsView()
        .padding()
        .frame(width: 520)
}
