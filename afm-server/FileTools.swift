//
//  FileTools.swift
//  afm-server
//
//  File operation tools for Apple Foundation Models
//

import Foundation
import OSLog
#if canImport(Darwin)
import Darwin
#endif

#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - File Tools Manager

/// Manages file operation tools that can be used by the Foundation Models framework.
/// Provides read, write, edit, delete, move, and list operations on files and directories.
nonisolated final class FileToolsManager: @unchecked Sendable {
    static let shared = FileToolsManager()
    
    private let logger = Logger(subsystem: "online.techopolis.afm-server", category: "FileTools")
    private let fm = FileManager.default
    
    /// The allowed root directories for file operations.
    /// Operations outside these directories will be rejected for security.
    private var allowedRoots: [URL] = []
    
    /// The app's sandbox container directory - always writable
    private(set) var containerDirectory: URL?
    
    /// Whether to allow operations anywhere (dangerous, for development only)
    private var allowAllPaths: Bool = false
    
    private init() {
        // Get the app's sandbox container (Documents directory is always writable)
        if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            containerDirectory = docs
            allowedRoots.append(docs)
            logger.log("[FileTools] Container directory: \(docs.path, privacy: .public)")
        }
        
        // Also allow Desktop and Downloads if accessible
        if let desktop = fm.urls(for: .desktopDirectory, in: .userDomainMask).first {
            allowedRoots.append(desktop)
        }
        if let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            allowedRoots.append(downloads)
        }
        
        // Try home directory (may work with entitlements)
        let home = fm.homeDirectoryForCurrentUser
        allowedRoots.append(home)
        
        // Check environment variable for additional allowed roots
        if let roots = ProcessInfo.processInfo.environment["PI_ALLOWED_ROOTS"] {
            for path in roots.split(separator: ":") {
                let url = URL(fileURLWithPath: String(path))
                if fm.fileExists(atPath: url.path) {
                    allowedRoots.append(url)
                }
            }
        }
        
        // Development mode: allow all paths if explicitly set
        if ProcessInfo.processInfo.environment["PI_ALLOW_ALL_PATHS"] == "1" {
            allowAllPaths = true
            logger.warning("[FileTools] WARNING: All paths allowed - development mode only!")
        }
        
        logger.log("[FileTools] Initialized with \(self.allowedRoots.count) allowed roots")
    }
    
    // MARK: - Path Resolution
    
    /// Resolves a path to an absolute URL, handling ~ expansion and relative paths
    func resolvePath(_ path: String) -> URL {
        var resolvedPath = path
        let trimmedPath = resolvedPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowerPath = trimmedPath.lowercased()
        let developerExactMatches = ["developer", "~/developer", "~/desktop/developer"]
        let developerPrefixes = ["developer/", "~/developer/", "~/desktop/developer/"]

        for prefix in developerExactMatches where lowerPath == prefix {
            let developerURL = fm.homeDirectoryForCurrentUser.appendingPathComponent("Developer")
            return developerURL.standardized
        }

        for prefix in developerPrefixes where lowerPath.hasPrefix(prefix) {
            let suffixStart = trimmedPath.index(trimmedPath.startIndex, offsetBy: min(prefix.count, trimmedPath.count))
            let suffix = String(trimmedPath[suffixStart...]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            var developerURL = fm.homeDirectoryForCurrentUser.appendingPathComponent("Developer")
            if !suffix.isEmpty {
                developerURL.appendPathComponent(suffix)
            }
            return developerURL.standardized
        }
        
        // Expand ~ to home directory
        if resolvedPath.hasPrefix("~/") {
            let home = fm.homeDirectoryForCurrentUser.path
            resolvedPath = home + String(resolvedPath.dropFirst(1))
        } else if resolvedPath == "~" {
            resolvedPath = fm.homeDirectoryForCurrentUser.path
        }
        
        // If it's now an absolute path, use it directly
        if resolvedPath.hasPrefix("/") {
            return URL(fileURLWithPath: resolvedPath).standardized
        }
        
        // For relative paths or just filenames, put them in the container directory (Documents)
        if let container = containerDirectory {
            logger.log("[FileTools] Resolving relative path '\(path, privacy: .public)' to container: \(container.path, privacy: .public)")
            return container.appendingPathComponent(resolvedPath).standardized
        }
        
        // Fallback to current directory
        return URL(fileURLWithPath: resolvedPath).standardized
    }
    
    // MARK: - Path Validation
    
    nonisolated enum FileToolError: Error, LocalizedError {
        case pathNotAllowed(String)
        case pathNotFound(String)
        case isDirectory(String)
        case isNotDirectory(String)
        case ioError(String)
        case invalidArguments(String)
        
        var errorDescription: String? {
            switch self {
            case .pathNotAllowed(let p): return "Path not in allowed directories: \(p). Try using ~/Documents/filename.txt or just filename.txt"
            case .pathNotFound(let p): return "Path not found: \(p)"
            case .isDirectory(let p): return "Expected file but found directory: \(p)"
            case .isNotDirectory(let p): return "Expected directory but found file: \(p)"
            case .ioError(let m): return "I/O error: \(m)"
            case .invalidArguments(let m): return "Invalid arguments: \(m)"
            }
        }
    }
    
    /// Validates that a path is within allowed directories
    func validatePath(_ path: String) throws -> URL {
        // First resolve the path (handle relative paths)
        let url = resolvePath(path)
        
        if allowAllPaths {
            return url
        }
        
        for root in allowedRoots {
            if url.path.hasPrefix(root.standardized.path) {
                return url
            }
        }
        
        throw FileToolError.pathNotAllowed(path)
    }
    
    // MARK: - File Operations
    
    /// Read the contents of a file
    func readFile(path: String, maxBytes: Int = 1024 * 1024) throws -> FileReadResult {
        let url = try validatePath(path)
        
        guard fm.fileExists(atPath: url.path) else {
            throw FileToolError.pathNotFound(path)
        }
        
        var isDir: ObjCBool = false
        fm.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue {
            throw FileToolError.isDirectory(path)
        }
        
        let data = try Data(contentsOf: url)
        let truncated = data.count > maxBytes
        let slice = data.prefix(maxBytes)
        let content = String(decoding: slice, as: UTF8.self)
        
        let attrs = try fm.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? Int) ?? data.count
        
        return FileReadResult(
            path: path,
            content: content,
            size: size,
            truncated: truncated
        )
    }
    
    /// Write content to a file (creates parent directories if needed)
    func writeFile(path: String, content: String, createDirectories: Bool = true) throws -> FileWriteResult {
        let url = try validatePath(path)
        
        if createDirectories {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        
        guard let data = content.data(using: .utf8) else {
            throw FileToolError.ioError("Failed to encode content as UTF-8")
        }
        
        try data.write(to: url, options: .atomic)
        
        return FileWriteResult(
            path: path,
            bytesWritten: data.count,
            created: true
        )
    }
    
    /// Edit a file by replacing text or inserting at a line
    func editFile(path: String, oldText: String?, newText: String, lineNumber: Int? = nil) throws -> FileEditResult {
        let url = try validatePath(path)
        
        guard fm.fileExists(atPath: url.path) else {
            throw FileToolError.pathNotFound(path)
        }
        
        var content = try String(contentsOf: url, encoding: .utf8)
        var changes = 0
        
        if let oldText = oldText, !oldText.isEmpty {
            // Replace mode: find and replace oldText with newText
            let occurrences = content.components(separatedBy: oldText).count - 1
            if occurrences == 0 {
                return FileEditResult(path: path, success: false, message: "Text to replace not found", changesCount: 0)
            }
            content = content.replacingOccurrences(of: oldText, with: newText)
            changes = occurrences
        } else if let line = lineNumber {
            // Insert mode: insert newText at specified line
            var lines = content.components(separatedBy: "\n")
            let insertIndex = max(0, min(line - 1, lines.count))
            lines.insert(newText, at: insertIndex)
            content = lines.joined(separator: "\n")
            changes = 1
        } else {
            // Append mode: append newText to end of file
            if !content.hasSuffix("\n") && !content.isEmpty {
                content += "\n"
            }
            content += newText
            changes = 1
        }
        
        try content.data(using: .utf8)?.write(to: url, options: .atomic)
        
        return FileEditResult(path: path, success: true, message: "File edited successfully", changesCount: changes)
    }
    
    /// Delete a file or directory
    func deleteFile(path: String, recursive: Bool = false) throws -> FileDeleteResult {
        let url = try validatePath(path)
        
        guard fm.fileExists(atPath: url.path) else {
            throw FileToolError.pathNotFound(path)
        }
        
        var isDir: ObjCBool = false
        fm.fileExists(atPath: url.path, isDirectory: &isDir)
        
        if isDir.boolValue && !recursive {
            // Check if directory is empty
            let contents = try fm.contentsOfDirectory(atPath: url.path)
            if !contents.isEmpty {
                throw FileToolError.ioError("Directory is not empty. Use recursive=true to delete non-empty directories.")
            }
        }
        
        try fm.removeItem(at: url)
        
        return FileDeleteResult(path: path, deleted: true, wasDirectory: isDir.boolValue)
    }
    
    /// Move or rename a file or directory
    func moveFile(sourcePath: String, destinationPath: String) throws -> FileMoveResult {
        let sourceURL = try validatePath(sourcePath)
        let destURL = try validatePath(destinationPath)
        
        guard fm.fileExists(atPath: sourceURL.path) else {
            throw FileToolError.pathNotFound(sourcePath)
        }
        
        // Create parent directories for destination if needed
        try fm.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        
        try fm.moveItem(at: sourceURL, to: destURL)
        
        return FileMoveResult(sourcePath: sourcePath, destinationPath: destinationPath, success: true)
    }
    
    /// Copy a file or directory
    func copyFile(sourcePath: String, destinationPath: String) throws -> FileCopyResult {
        let sourceURL = try validatePath(sourcePath)
        let destURL = try validatePath(destinationPath)
        
        guard fm.fileExists(atPath: sourceURL.path) else {
            throw FileToolError.pathNotFound(sourcePath)
        }
        
        // Create parent directories for destination if needed
        try fm.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        
        try fm.copyItem(at: sourceURL, to: destURL)
        
        return FileCopyResult(sourcePath: sourcePath, destinationPath: destinationPath, success: true)
    }
    
    /// List contents of a directory
    func listDirectory(path: String, recursive: Bool = false, includeHidden: Bool = false) throws -> DirectoryListResult {
        let url = try validatePath(path)
        
        guard fm.fileExists(atPath: url.path) else {
            throw FileToolError.pathNotFound(path)
        }
        
        var isDir: ObjCBool = false
        fm.fileExists(atPath: url.path, isDirectory: &isDir)
        if !isDir.boolValue {
            throw FileToolError.isNotDirectory(path)
        }
        
        var items: [DirectoryItem] = []
        
        if recursive {
            if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]) {
                while let itemURL = enumerator.nextObject() as? URL {
                    if !includeHidden && itemURL.lastPathComponent.hasPrefix(".") {
                        continue
                    }
                    let relativePath = itemURL.path.replacingOccurrences(of: url.path + "/", with: "")
                    let isDir = (try? itemURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    let size = (try? itemURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    items.append(DirectoryItem(name: relativePath, isDirectory: isDir, size: size))
                }
            }
        } else {
            let contents = try fm.contentsOfDirectory(atPath: url.path)
            for name in contents {
                if !includeHidden && name.hasPrefix(".") {
                    continue
                }
                let itemURL = url.appendingPathComponent(name)
                var itemIsDir: ObjCBool = false
                fm.fileExists(atPath: itemURL.path, isDirectory: &itemIsDir)
                let attrs = try? fm.attributesOfItem(atPath: itemURL.path)
                let size = (attrs?[.size] as? Int) ?? 0
                items.append(DirectoryItem(name: name, isDirectory: itemIsDir.boolValue, size: size))
            }
        }
        
        return DirectoryListResult(path: path, items: items, count: items.count)
    }
    
    /// Create a directory
    func createDirectory(path: String, createIntermediates: Bool = true) throws -> DirectoryCreateResult {
        let url = try validatePath(path)
        
        if fm.fileExists(atPath: url.path) {
            var isDir: ObjCBool = false
            fm.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue {
                return DirectoryCreateResult(path: path, created: false, alreadyExists: true)
            }
            throw FileToolError.ioError("A file already exists at this path")
        }
        
        try fm.createDirectory(at: url, withIntermediateDirectories: createIntermediates)
        
        return DirectoryCreateResult(path: path, created: true, alreadyExists: false)
    }
    
    /// Check if a path exists and get its type
    func checkPath(path: String) throws -> PathCheckResult {
        let url = try validatePath(path)
        
        let exists = fm.fileExists(atPath: url.path)
        var isDir: ObjCBool = false
        if exists {
            fm.fileExists(atPath: url.path, isDirectory: &isDir)
        }
        
        var size: Int? = nil
        if exists && !isDir.boolValue {
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            size = attrs?[.size] as? Int
        }
        
        return PathCheckResult(
            path: path,
            exists: exists,
            isDirectory: isDir.boolValue,
            isFile: exists && !isDir.boolValue,
            size: size
        )
    }
}

// MARK: - Result Types

nonisolated struct FileReadResult: Codable, Sendable {
    let path: String
    let content: String
    let size: Int
    let truncated: Bool
}

nonisolated struct FileWriteResult: Codable, Sendable {
    let path: String
    let bytesWritten: Int
    let created: Bool
}

nonisolated struct FileEditResult: Codable, Sendable {
    let path: String
    let success: Bool
    let message: String
    let changesCount: Int
}

nonisolated struct FileDeleteResult: Codable, Sendable {
    let path: String
    let deleted: Bool
    let wasDirectory: Bool
}

nonisolated struct FileMoveResult: Codable, Sendable {
    let sourcePath: String
    let destinationPath: String
    let success: Bool
}

nonisolated struct FileCopyResult: Codable, Sendable {
    let sourcePath: String
    let destinationPath: String
    let success: Bool
}

nonisolated struct DirectoryItem: Codable, Sendable {
    let name: String
    let isDirectory: Bool
    let size: Int
}

nonisolated struct DirectoryListResult: Codable, Sendable {
    let path: String
    let items: [DirectoryItem]
    let count: Int
}

nonisolated struct DirectoryCreateResult: Codable, Sendable {
    let path: String
    let created: Bool
    let alreadyExists: Bool
}

nonisolated struct PathCheckResult: Codable, Sendable {
    let path: String
    let exists: Bool
    let isDirectory: Bool
    let isFile: Bool
    let size: Int?
}

nonisolated struct TerminalCommandResult: Codable, Sendable {
    let command: String
    let workingDirectory: String
    let exitCode: Int32?
    let timedOut: Bool
    let durationSeconds: Double
    let output: String
    let truncated: Bool
    let fullOutputPath: String?
}

nonisolated enum TerminalCommandRunner {
    private static let maxOutputBytes = 64 * 1024

    static func run(command: String, workingDirectory: URL, timeoutSeconds: Int) async throws -> TerminalCommandResult {
        try await Task.detached(priority: .utility) {
            let timeout = min(max(timeoutSeconds, 1), 120)
            let fm = FileManager.default
            let outputURL = fm.temporaryDirectory
                .appendingPathComponent("afm-terminal-\(UUID().uuidString).log")

            fm.createFile(atPath: outputURL.path, contents: nil)
            let outputHandle = try FileHandle(forWritingTo: outputURL)
            defer {
                try? outputHandle.close()
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]
            process.currentDirectoryURL = workingDirectory
            process.standardOutput = outputHandle
            process.standardError = outputHandle

            let startedAt = Date()
            try process.run()

            let deadline = Date().addingTimeInterval(TimeInterval(timeout))
            var timedOut = false

            while process.isRunning {
                if Date() >= deadline {
                    timedOut = true
                    process.terminate()
                    break
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }

            if timedOut {
                let killDeadline = Date().addingTimeInterval(2)
                while process.isRunning && Date() < killDeadline {
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                #if canImport(Darwin)
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
                #endif
            }

            process.waitUntilExit()
            try? outputHandle.close()

            let duration = Date().timeIntervalSince(startedAt)
            let attrs = try? fm.attributesOfItem(atPath: outputURL.path)
            let fileSize = attrs?[.size] as? UInt64 ?? 0
            let truncated = fileSize > UInt64(maxOutputBytes)
            let outputData: Data

            let readHandle = try FileHandle(forReadingFrom: outputURL)
            defer {
                try? readHandle.close()
            }

            if truncated {
                try readHandle.seek(toOffset: fileSize - UInt64(maxOutputBytes))
                outputData = readHandle.readDataToEndOfFile()
            } else {
                outputData = readHandle.readDataToEndOfFile()
                try? fm.removeItem(at: outputURL)
            }

            let output = String(data: outputData, encoding: .utf8)
                ?? String(decoding: outputData, as: UTF8.self)

            return TerminalCommandResult(
                command: command,
                workingDirectory: workingDirectory.path,
                exitCode: timedOut ? nil : process.terminationStatus,
                timedOut: timedOut,
                durationSeconds: duration,
                output: output.isEmpty ? "(no output)" : output,
                truncated: truncated,
                fullOutputPath: truncated ? outputURL.path : nil
            )
        }.value
    }
}

// MARK: - Foundation Models Tool Definitions

#if canImport(FoundationModels)
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
nonisolated struct ReadFileTool: Tool {
    let name = "read_file"
    let description = "Read the contents of a file. Use ~/Documents/file.txt, ~/Desktop/file.txt, or just filename.txt"
    
    @Generable
    struct Arguments {
        @Guide(description: "Path to the file: use ~/Documents/file.txt or just filename.txt")
        let path: String
        
        @Guide(description: "Maximum bytes to read (default 1MB)")
        let maxBytes: Int?
    }
    
    func call(arguments: Arguments) async throws -> String {
        let result = try FileToolsManager.shared.readFile(
            path: arguments.path,
            maxBytes: arguments.maxBytes ?? 1024 * 1024
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(result)
        return String(data: data, encoding: .utf8) ?? ""
    }
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
nonisolated struct WriteFileTool: Tool {
    let name = "write_file"
    let description = "Write content to a file. Use ~/Documents/file.txt, ~/Desktop/file.txt, or just filename.txt (saves to Documents)"
    
    @Generable
    struct Arguments {
        @Guide(description: "Path to write: use ~/Documents/hello.txt, ~/Desktop/hello.txt, or just hello.txt")
        let path: String
        
        @Guide(description: "The content to write to the file")
        let content: String
    }
    
    func call(arguments: Arguments) async throws -> String {
        // Log that the tool was called
        let logger = Logger(subsystem: "online.techopolis.afm-server", category: "WriteFileTool")
        logger.log("[WriteFileTool] CALLED with path=\(arguments.path, privacy: .public)")
        
        let result = try FileToolsManager.shared.writeFile(
            path: arguments.path,
            content: arguments.content
        )
        
        logger.log("[WriteFileTool] SUCCESS: wrote \(result.bytesWritten) bytes to \(arguments.path, privacy: .public)")
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(result)
        return String(data: data, encoding: .utf8) ?? ""
    }
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
nonisolated struct EditFileTool: Tool {
    let name = "edit_file"
    let description = "Edit a file by replacing text. Provide oldText to find and replace, or lineNumber to insert at a specific line."
    
    @Generable
    struct Arguments {
        @Guide(description: "The absolute path to the file to edit")
        let path: String
        
        @Guide(description: "The text to find and replace (leave empty to insert)")
        let oldText: String?
        
        @Guide(description: "The new text to insert or use as replacement")
        let newText: String
        
        @Guide(description: "Line number to insert at (1-based, only used if oldText is empty)")
        let lineNumber: Int?
    }
    
    func call(arguments: Arguments) async throws -> String {
        let result = try FileToolsManager.shared.editFile(
            path: arguments.path,
            oldText: arguments.oldText,
            newText: arguments.newText,
            lineNumber: arguments.lineNumber
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(result)
        return String(data: data, encoding: .utf8) ?? ""
    }
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
nonisolated struct DeleteFileTool: Tool {
    let name = "delete_file"
    let description = "Delete a file or directory"
    
    @Generable
    struct Arguments {
        @Guide(description: "The absolute path to delete")
        let path: String
        
        @Guide(description: "If true, delete directories recursively (default false)")
        let recursive: Bool?
    }
    
    func call(arguments: Arguments) async throws -> String {
        let result = try FileToolsManager.shared.deleteFile(
            path: arguments.path,
            recursive: arguments.recursive ?? false
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(result)
        return String(data: data, encoding: .utf8) ?? ""
    }
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
nonisolated struct MoveFileTool: Tool {
    let name = "move_file"
    let description = "Move or rename a file or directory"
    
    @Generable
    struct Arguments {
        @Guide(description: "The source path")
        let sourcePath: String
        
        @Guide(description: "The destination path")
        let destinationPath: String
    }
    
    func call(arguments: Arguments) async throws -> String {
        let result = try FileToolsManager.shared.moveFile(
            sourcePath: arguments.sourcePath,
            destinationPath: arguments.destinationPath
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(result)
        return String(data: data, encoding: .utf8) ?? ""
    }
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
nonisolated struct ListDirectoryTool: Tool {
    let name = "list_directory"
    let description = "List contents of a local directory. Use ~/Developer for the user's Developer folder."
    
    @Generable
    struct Arguments {
        @Guide(description: "Directory path, such as ~/Developer or ~/Downloads")
        let path: String
        
        @Guide(description: "If true, list recursively (default false)")
        let recursive: Bool?
        
        @Guide(description: "If true, include hidden files (default false)")
        let includeHidden: Bool?
    }
    
    func call(arguments: Arguments) async throws -> String {
        let result = try FileToolsManager.shared.listDirectory(
            path: arguments.path,
            recursive: arguments.recursive ?? false,
            includeHidden: arguments.includeHidden ?? false
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(result)
        return String(data: data, encoding: .utf8) ?? ""
    }
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
nonisolated struct CreateDirectoryTool: Tool {
    let name = "create_directory"
    let description = "Create a directory, including parent directories if needed"
    
    @Generable
    struct Arguments {
        @Guide(description: "The absolute path of the directory to create")
        let path: String
    }
    
    func call(arguments: Arguments) async throws -> String {
        let result = try FileToolsManager.shared.createDirectory(path: arguments.path)
        let encoder = JSONEncoder()
        let data = try encoder.encode(result)
        return String(data: data, encoding: .utf8) ?? ""
    }
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
nonisolated struct CheckPathTool: Tool {
    let name = "check_path"
    let description = "Check if a path exists and whether it's a file or directory"
    
    @Generable
    struct Arguments {
        @Guide(description: "The absolute path to check")
        let path: String
    }
    
    func call(arguments: Arguments) async throws -> String {
        let result = try FileToolsManager.shared.checkPath(path: arguments.path)
        let encoder = JSONEncoder()
        let data = try encoder.encode(result)
        return String(data: data, encoding: .utf8) ?? ""
    }
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
nonisolated struct BashTerminalTool: Tool {
    let name = "bash"
    let description = "Execute a short local terminal command and return stdout plus stderr. Use this for real local facts, repo checks, git status, ls, rg, find, build, and test commands."

    @Generable
    struct Arguments {
        @Guide(description: "The shell command to execute, such as pwd, ls -la ~/Developer, git status --short, or rg -n pattern")
        let command: String

        @Guide(description: "Working directory for the command. Use ~/Developer or a project path when relevant. Defaults to the user's home directory.")
        let workingDirectory: String?

        @Guide(description: "Timeout in seconds. Defaults to 10 and is capped at 120.")
        let timeoutSeconds: Int?
    }

    func call(arguments: Arguments) async throws -> String {
        let cwd = try FileToolsManager.shared.validatePath(arguments.workingDirectory ?? "~")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw FileToolsManager.FileToolError.isNotDirectory(cwd.path)
        }

        let result = try await TerminalCommandRunner.run(
            command: arguments.command,
            workingDirectory: cwd,
            timeoutSeconds: arguments.timeoutSeconds ?? 10
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(result)
        return String(data: data, encoding: .utf8) ?? ""
    }
}
#endif
