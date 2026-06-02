//
//  FoundationModelAdapterRegistry.swift
//  afm-server
//
//  Tracks user-loaded Foundation Models adapters and exposes stable model IDs.
//

import Foundation
import OSLog
#if canImport(FoundationModels)
import FoundationModels
#endif

nonisolated struct FoundationModelAdapterRecord: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let displayName: String
    let fileName: String
    let originalPath: String
    let addedAt: Date
    let compiledAt: Date?

    var modelID: String {
        "apple.local.adapter.\(id)"
    }

    var ollamaModelName: String {
        "\(modelID):latest"
    }
}

nonisolated enum FoundationModelAdapterRegistry {
    private static let logger = Logger(subsystem: "online.techopolis.afm-server", category: "FoundationModelAdapterRegistry")

    static var adapterDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("afm-server", isDirectory: true)
            .appendingPathComponent("Adapters", isDirectory: true)
    }

    private static var registryURL: URL {
        adapterDirectory.appendingPathComponent("adapters.json")
    }

    static func loadRecords() -> [FoundationModelAdapterRecord] {
        guard FileManager.default.fileExists(atPath: registryURL.path),
              let data = try? Data(contentsOf: registryURL),
              let records = try? JSONDecoder().decode([FoundationModelAdapterRecord].self, from: data) else {
            return []
        }

        return records.filter { FileManager.default.fileExists(atPath: fileURL(for: $0).path) }
    }

    static func fileURL(for record: FoundationModelAdapterRecord) -> URL {
        adapterDirectory.appendingPathComponent(record.fileName)
    }

    static func adapter(forModelID modelID: String) -> FoundationModelAdapterRecord? {
        let normalized = normalizedModelID(modelID)
        return loadRecords().first { record in
            normalized == record.modelID || normalized == record.ollamaModelName
        }
    }

    static func isBaseModelID(_ modelID: String) -> Bool {
        let normalized = normalizedModelID(modelID)
        return normalized == "apple.local" || normalized == "apple.local:latest"
    }

    static func importAdapter(from sourceURL: URL) async throws -> FoundationModelAdapterRecord {
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        try FileManager.default.createDirectory(at: adapterDirectory, withIntermediateDirectories: true)

        let adapterID = uniqueAdapterID(for: sourceURL)
        let destinationFileName = uniqueStoredFileName(for: sourceURL, adapterID: adapterID)
        let destinationURL = adapterDirectory.appendingPathComponent(destinationFileName)

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)

        do {
            let metadata = try await compileAdapter(at: destinationURL)
            let displayName = displayName(for: sourceURL, metadata: metadata)
            let record = FoundationModelAdapterRecord(
                id: adapterID,
                displayName: displayName,
                fileName: destinationFileName,
                originalPath: sourceURL.path,
                addedAt: Date(),
                compiledAt: Date()
            )
            try save(record: record)
            logger.log("Imported adapter \(record.modelID, privacy: .public) from \(sourceURL.lastPathComponent, privacy: .public)")
            AppLog.info("Loaded adapter \(record.displayName)", source: "adapter")
            return record
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            logger.error("Adapter import failed: \(String(describing: error), privacy: .public)")
            AppLog.error("Adapter import failed: \(error.localizedDescription)", source: "adapter")
            throw error
        }
    }

    static func removeAdapter(id: String) throws {
        var records = loadRecords()
        guard let record = records.first(where: { $0.id == id }) else {
            return
        }

        let url = fileURL(for: record)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        records.removeAll { $0.id == id }
        try save(records)

        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) {
            try? SystemLanguageModel.Adapter.removeObsoleteAdapters()
        }
        #endif

        AppLog.info("Removed adapter \(record.displayName)", source: "adapter")
    }

    private static func save(record: FoundationModelAdapterRecord) throws {
        var records = loadRecords()
        records.removeAll { $0.id == record.id || $0.fileName == record.fileName }
        records.append(record)
        records.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        try save(records)
    }

    private static func save(_ records: [FoundationModelAdapterRecord]) throws {
        try FileManager.default.createDirectory(at: adapterDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(records)
        try data.write(to: registryURL, options: [.atomic])
    }

    private static func uniqueAdapterID(for url: URL) -> String {
        let baseName = url.deletingPathExtension().lastPathComponent
        let slug = sanitizedIdentifier(baseName)
        let existing = Set(loadRecords().map(\.id))

        if !existing.contains(slug) {
            return slug
        }

        var suffix = 2
        while existing.contains("\(slug)-\(suffix)") {
            suffix += 1
        }
        return "\(slug)-\(suffix)"
    }

    private static func uniqueStoredFileName(for url: URL, adapterID: String) -> String {
        let extensionPart = url.pathExtension.isEmpty ? "fmadapter" : url.pathExtension
        var candidate = "\(adapterID).\(extensionPart)"
        var index = 2

        while FileManager.default.fileExists(atPath: adapterDirectory.appendingPathComponent(candidate).path) {
            candidate = "\(adapterID)-\(index).\(extensionPart)"
            index += 1
        }

        return candidate
    }

    private static func sanitizedIdentifier(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let lowered = value.lowercased()
        let scalars = lowered.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(scalars)
            .split(separator: "-")
            .joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return collapsed.isEmpty ? "adapter" : collapsed
    }

    private static func normalizedModelID(_ modelID: String) -> String {
        let decoded = modelID.removingPercentEncoding ?? modelID
        return decoded.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func displayName(for sourceURL: URL, metadata: [String: Any]) -> String {
        let metadataName = [
            "displayName",
            "display_name",
            "name",
            "title"
        ]
            .lazy
            .compactMap { metadata[$0] as? String }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        return metadataName ?? sourceURL.deletingPathExtension().lastPathComponent
    }

    private static func compileAdapter(at url: URL) async throws -> [String: Any] {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) {
            let adapter = try SystemLanguageModel.Adapter(fileURL: url)
            try await adapter.compile()
            return adapter.creatorDefinedMetadata
        }
        #endif

        throw NSError(
            domain: "FoundationModelAdapterRegistry",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Foundation Models adapters require macOS 26 or newer."]
        )
    }
}
