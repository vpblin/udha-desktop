import Foundation
import AppKit
import os

enum TmuxError: Error, LocalizedError {
    case tmuxNotFound
    case commandFailed(String, Int32, String)

    var errorDescription: String? {
        switch self {
        case .tmuxNotFound: return "tmux not found. Install via `brew install tmux`."
        case .commandFailed(let cmd, let code, let msg): return "tmux `\(cmd)` failed (\(code)): \(msg)"
        }
    }
}

final class TmuxSession: @unchecked Sendable {
    let id: UUID
    let label: String
    let tmuxName: String
    let logPath: URL
    let directory: String
    let command: String
    let args: [String]

    private var tailProcess: Process?
    private var outHandle: FileHandle?
    private var pollTimer: DispatchSourceTimer?
    private(set) var terminalWindowID: String?

    var onData: ((Data) -> Void)?
    var onSnapshot: ((String) -> Void)?
    var onExit: ((Int32) -> Void)?

    private static let tmuxPath: String = {
        for candidate in ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"] {
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
        }
        return "/opt/homebrew/bin/tmux"
    }()

    init(id: UUID, label: String, directory: String, command: String, args: [String]) {
        self.id = id
        self.label = label
        let shortID = id.uuidString.prefix(8).lowercased()
        let safeLabel = label.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        self.tmuxName = "udha-\(safeLabel.isEmpty ? String(shortID) : safeLabel)-\(shortID)"
        self.logPath = URL(fileURLWithPath: "/tmp/udha/\(tmuxName).log")
        self.directory = directory
        self.command = command
        self.args = args
    }

    func start() throws {
        guard FileManager.default.fileExists(atPath: Self.tmuxPath) else {
            throw TmuxError.tmuxNotFound
        }

        try FileManager.default.createDirectory(
            at: logPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let alreadyRunning = isAlive()
        if alreadyRunning {
            Log.pty.info("tmux session \(self.tmuxName) already exists — reattaching")
            FileManager.default.createFile(atPath: logPath.path, contents: Data())
            _ = try? runTmux(args: ["pipe-pane", "-t", tmuxName])
        } else {
            FileManager.default.createFile(atPath: logPath.path, contents: Data())
            let shellCommand = ([command] + args).map(shellEscape).joined(separator: " ")
            try runTmux(args: ["new-session", "-d", "-s", tmuxName, "-c", directory, shellCommand])
            Log.pty.info("tmux session \(self.tmuxName) created")
        }

        try runTmux(args: ["pipe-pane", "-o", "-t", tmuxName, "cat >> \(logPath.path)"])

        if !alreadyRunning {
            openInTerminal()
        } else if let existing = findExistingWindowID() {
            // Reattach to whichever Terminal window is already showing this session.
            terminalWindowID = existing
            Log.pty.info("session \(self.tmuxName) reclaimed Terminal window \(existing)")
        }
        startTailing()
        startExitWatcher()
        startSnapshotPolling()
    }

    private func startSnapshotPolling() {
        stopSnapshotPolling()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 2.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let content = self.capturePane()
            if !content.isEmpty {
                self.onSnapshot?(content)
            }
        }
        timer.resume()
        pollTimer = timer
    }

    private func stopSnapshotPolling() {
        pollTimer?.cancel()
        pollTimer = nil
    }

    private func capturePane() -> String {
        capturePaneLines(start: 0)
    }

    func captureScrollback(maxLines: Int = 200) -> String {
        capturePaneLines(start: -maxLines)
    }

    private func capturePaneLines(start: Int) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.tmuxPath)
        var args = ["capture-pane", "-p", "-t", tmuxName]
        if start < 0 {
            args += ["-S", "\(start)"]
        }
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
        } catch { return "" }
        if p.terminationStatus != 0 { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    func sendInput(text: String) {
        _ = try? runTmux(args: ["send-keys", "-t", tmuxName, "-l", text])
        _ = try? runTmux(args: ["send-keys", "-t", tmuxName, "Enter"])
    }

    func sendRaw(text: String) {
        try? runTmux(args: ["send-keys", "-t", tmuxName, "-l", text])
    }

    func sendKey(_ key: String) {
        try? runTmux(args: ["send-keys", "-t", tmuxName, key])
    }

    func bringToFront() {
        // Try the cached window id first.
        if let windowID = terminalWindowID, focusWindow(id: windowID) {
            return
        }
        // Otherwise, scan Terminal for any tab already attached to our tmux session.
        if let windowID = findExistingWindowID() {
            terminalWindowID = windowID
            _ = focusWindow(id: windowID)
            return
        }
        // Nothing found — open a fresh one.
        openInTerminal()
    }

    /// Attempts to focus a Terminal window by id. Returns false if the window no longer exists.
    private func focusWindow(id windowID: String) -> Bool {
        let script = """
        tell application "Terminal"
          try
            set idx to index of window id \(windowID)
            activate
            set index of window id \(windowID) to 1
            return "ok"
          on error
            return "missing"
          end try
        end tell
        """
        let result = runAppleScript(script)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return result == "ok"
    }

    /// Asks tmux which tty is attached to this session, then asks Terminal which window owns that tty.
    /// This is the authoritative lookup — no guessing from titles.
    private func findExistingWindowID() -> String? {
        for tty in attachedTTYs() {
            let script = """
            tell application "Terminal"
              set foundID to ""
              repeat with w in windows
                repeat with t in tabs of w
                  try
                    if (tty of t) is "\(tty)" then
                      set foundID to (id of w as string)
                      exit repeat
                    end if
                  end try
                end repeat
                if foundID is not "" then exit repeat
              end repeat
              return foundID
            end tell
            """
            if let raw = runAppleScript(script)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !raw.isEmpty {
                return raw
            }
        }
        return nil
    }

    /// Returns the list of ttys currently attached to this tmux session.
    private func attachedTTYs() -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.tmuxPath)
        p.arguments = ["list-clients", "-t", tmuxName, "-F", "#{client_tty}"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return [] }
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let data = try? pipe.fileHandleForReading.readToEnd(),
              let raw = String(data: data, encoding: .utf8) else { return [] }
        return raw.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    func detach() {
        tailProcess?.terminate()
        tailProcess = nil
        outHandle?.readabilityHandler = nil
        outHandle = nil
        stopSnapshotPolling()
    }

    func kill() {
        try? runTmux(args: ["kill-session", "-t", tmuxName])
        detach()
    }

    func isAlive() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.tmuxPath)
        p.arguments = ["has-session", "-t", tmuxName]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    private func openInTerminal() {
        // Double-check: another entry point may have captured this window in the meantime.
        if let existing = findExistingWindowID() {
            terminalWindowID = existing
            _ = focusWindow(id: existing)
            return
        }
        let script = """
        tell application "Terminal"
          activate
          set newTab to do script "\(Self.tmuxPath) attach -t \(tmuxName)"
          set custom title of newTab to "\(tmuxName)"
          set winID to id of window 1
          return winID as string
        end tell
        """
        if let result = runAppleScript(script) {
            terminalWindowID = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func startTailing() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        p.arguments = ["-F", "-n", "+1", logPath.path]
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = Pipe()

        let handle = outPipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            if !data.isEmpty {
                self?.onData?(data)
            }
        }

        do {
            try p.run()
            self.tailProcess = p
            self.outHandle = handle
        } catch {
            Log.pty.error("tail failed: \(error.localizedDescription)")
        }
    }

    private func startExitWatcher() {
        let name = tmuxName
        let weakHandler = { [weak self] (code: Int32) in
            self?.onExit?(code)
        }
        DispatchQueue.global(qos: .utility).async {
            while true {
                Thread.sleep(forTimeInterval: 1.0)
                let p = Process()
                p.executableURL = URL(fileURLWithPath: Self.tmuxPath)
                p.arguments = ["has-session", "-t", name]
                p.standardOutput = Pipe()
                p.standardError = Pipe()
                do { try p.run() } catch { break }
                p.waitUntilExit()
                if p.terminationStatus != 0 {
                    weakHandler(0)
                    break
                }
            }
        }
    }

    @discardableResult
    private func runTmux(args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.tmuxPath)
        p.arguments = args
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        let outText = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if p.terminationStatus != 0 {
            throw TmuxError.commandFailed(args.joined(separator: " "), p.terminationStatus, errText.isEmpty ? outText : errText)
        }
        return outText
    }

    private func runAppleScript(_ source: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    private func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
