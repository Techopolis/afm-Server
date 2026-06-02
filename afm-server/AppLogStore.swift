import Combine
import Foundation
import OSLog

enum AppLogSeverity: String, CaseIterable, Sendable {
    case debug
    case info
    case warning
    case error

    var label: String {
        rawValue.uppercased()
    }

    var osLogType: OSLogType {
        switch self {
        case .debug:
            return .debug
        case .info:
            return .info
        case .warning:
            return .default
        case .error:
            return .error
        }
    }
}

struct AppLogEntry: Identifiable, Sendable {
    let id = UUID()
    let timestamp: Date
    let severity: AppLogSeverity
    let source: String
    let message: String
}

@MainActor
final class AppLogStore: ObservableObject {
    static let shared = AppLogStore()

    @Published private(set) var entries: [AppLogEntry] = []

    private let maxEntries = 500
    private let copyDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private init() {}

    func append(_ message: String, severity: AppLogSeverity, source: String) {
        let entry = AppLogEntry(
            timestamp: Date(),
            severity: severity,
            source: source,
            message: message
        )
        entries.append(entry)

        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    func clear() {
        entries.removeAll()
    }

    func exportText() -> String {
        entries.map { entry in
            let stamp = copyDateFormatter.string(from: entry.timestamp)
            return "[\(stamp)] [\(entry.severity.label)] [\(entry.source)] \(entry.message)"
        }
        .joined(separator: "\n")
    }
}

nonisolated enum AppLog {
    private static let logger = Logger(subsystem: "online.techopolis.afm-server", category: "AppLog")

    static func debug(_ message: String, source: String = "app") {
        write(message, severity: .debug, source: source)
    }

    static func info(_ message: String, source: String = "app") {
        write(message, severity: .info, source: source)
    }

    static func warning(_ message: String, source: String = "app") {
        write(message, severity: .warning, source: source)
    }

    static func error(_ message: String, source: String = "app") {
        write(message, severity: .error, source: source)
    }

    private static func write(_ message: String, severity: AppLogSeverity, source: String) {
        switch severity {
        case .debug:
            logger.debug("[\(source, privacy: .public)] \(message, privacy: .public)")
        case .info:
            logger.info("[\(source, privacy: .public)] \(message, privacy: .public)")
        case .warning:
            logger.notice("[\(source, privacy: .public)] \(message, privacy: .public)")
        case .error:
            logger.error("[\(source, privacy: .public)] \(message, privacy: .public)")
        }

        Task { @MainActor in
            AppLogStore.shared.append(message, severity: severity, source: source)
        }
    }
}
