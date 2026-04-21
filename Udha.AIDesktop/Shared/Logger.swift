import Foundation
import os

final class FileLogger: @unchecked Sendable {
    static let shared = FileLogger()
    private let queue = DispatchQueue(label: "udha.filelog")
    private let url: URL
    private let formatter: DateFormatter

    init() {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs/Udha.AI", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.url = base.appendingPathComponent("udha.log")
        self.formatter = DateFormatter()
        self.formatter.dateFormat = "HH:mm:ss.SSS"
    }

    func log(_ category: String, _ level: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) \(level) [\(category)] \(message)\n"
        queue.async { [url] in
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}

struct LogCategory {
    let name: String
    let os: Logger

    init(_ name: String) {
        self.name = name
        self.os = Logger(subsystem: "solutions.amk.Udha-AIDesktop", category: name)
    }

    func info(_ message: String) {
        os.info("\(message, privacy: .public)")
        FileLogger.shared.log(name, "INFO", message)
    }

    func debug(_ message: String) {
        os.debug("\(message, privacy: .public)")
        FileLogger.shared.log(name, "DEBUG", message)
    }

    func error(_ message: String) {
        os.error("\(message, privacy: .public)")
        FileLogger.shared.log(name, "ERROR", message)
    }
}

enum Log {
    static let app = LogCategory("app")
    static let pty = LogCategory("pty")
    static let classify = LogCategory("classify")
    static let voice = LogCategory("voice")
    static let agent = LogCategory("agent")
    static let hotkey = LogCategory("hotkey")
    static let net = LogCategory("net")
    static let slack = LogCategory("slack")
}
