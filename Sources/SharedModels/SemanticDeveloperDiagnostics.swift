import Foundation

public enum SemanticDeveloperDiagnostics {
    private static let queue = DispatchQueue(label: "SemanticDeveloperDiagnostics")

    public static func log(_ message: @autoclosure () -> String) {
        let line = "[\(timestamp())] \(message())\n"

        #if DEBUG
        writeDebugLine(line)
        #endif

        queue.async {
            guard let url = logFileURL() else {
                return
            }

            do {
                let directoryURL = url.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

                if !FileManager.default.fileExists(atPath: url.path) {
                    _ = FileManager.default.createFile(atPath: url.path, contents: nil)
                }

                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                if let data = line.data(using: .utf8) {
                    try handle.write(contentsOf: data)
                }
            } catch {
                #if DEBUG
                writeDebugLine("[SemanticDeveloperDiagnostics] failed to write log: \(String(describing: error))\n")
                #endif
            }
        }
    }

    public static func logPathDescription() -> String {
        logFileURL()?.path ?? "unavailable"
    }

    private static func logFileURL() -> URL? {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first

        return baseURL?
            .appendingPathComponent("SemanticDeveloper", isDirectory: true)
            .appendingPathComponent("debug.log", isDirectory: false)
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    #if DEBUG
    private static func writeDebugLine(_ line: String) {
        guard let data = line.data(using: .utf8) else {
            return
        }

        try? FileHandle.standardError.write(contentsOf: data)
    }
    #endif
}
