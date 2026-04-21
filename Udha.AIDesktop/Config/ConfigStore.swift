import Foundation
import Observation
import os

@MainActor
@Observable
final class ConfigStore {
    var config: AppConfig = AppConfig()

    private var directoryURL: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Udha.AI", isDirectory: true)
    }

    private var fileURL: URL {
        directoryURL.appendingPathComponent("config.json")
    }

    func load() {
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } catch {
            Log.app.error("Failed to create config directory: \(error.localizedDescription)")
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            Log.app.info("No config file — starting with defaults")
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try tolerantDecode(data: data)
            self.config = decoded
        } catch {
            Log.app.error("Failed to load config: \(error.localizedDescription). Backing up and resetting.")
            let backup = fileURL.appendingPathExtension("bak.\(Int(Date.now.timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
        }
    }

    // Tolerant decode: merge on-disk JSON onto default struct values so
    // adding new fields doesn't nuke existing user config.
    private func tolerantDecode(data: Data) throws -> AppConfig {
        let defaults = AppConfig()
        let defaultData = try JSONEncoder().encode(defaults)
        guard var merged = try JSONSerialization.jsonObject(with: defaultData) as? [String: Any],
              let onDisk = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return try JSONDecoder().decode(AppConfig.self, from: data)
        }
        Self.deepMerge(&merged, with: onDisk)
        let mergedData = try JSONSerialization.data(withJSONObject: merged)
        return try JSONDecoder().decode(AppConfig.self, from: mergedData)
    }

    private static func deepMerge(_ dst: inout [String: Any], with src: [String: Any]) {
        for (k, v) in src {
            if let nestedSrc = v as? [String: Any], var nestedDst = dst[k] as? [String: Any] {
                deepMerge(&nestedDst, with: nestedSrc)
                dst[k] = nestedDst
            } else {
                dst[k] = v
            }
        }
    }

    func save() {
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.app.error("Failed to save config: \(error.localizedDescription)")
        }
    }

    func mutate(_ block: (inout AppConfig) -> Void) {
        var copy = config
        block(&copy)
        config = copy
        save()
    }

    /// LRU push: most-recent dir first, de-duplicated, capped at 10.
    /// Ignores empty paths and directories that no longer exist.
    func recordRecentDirectory(_ dir: String) {
        let trimmed = dir.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: trimmed, isDirectory: &isDir), isDir.boolValue else { return }
        mutate { cfg in
            cfg.recentDirectories.removeAll { $0 == trimmed }
            cfg.recentDirectories.insert(trimmed, at: 0)
            if cfg.recentDirectories.count > 10 {
                cfg.recentDirectories = Array(cfg.recentDirectories.prefix(10))
            }
        }
    }

    /// Recent dirs for UI, seeded from existing session dirs when empty so
    /// existing users see something on first load.
    var recentDirectoriesForDisplay: [String] {
        if !config.recentDirectories.isEmpty { return config.recentDirectories }
        var seen = Set<String>()
        var seeded: [String] = []
        for s in config.sessions {
            let d = s.directory.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !d.isEmpty, !seen.contains(d) else { continue }
            seen.insert(d)
            seeded.append(d)
            if seeded.count >= 10 { break }
        }
        return seeded
    }
}
