import Foundation

nonisolated enum StudioLibrary {
    static let directory = URL.applicationSupportDirectory.appending(path: "Bliss Studio")

    static func migrate(defaults: UserDefaults = .standard,
                        legacy: URL = URL.applicationSupportDirectory.appending(path: "Graft/Music Scene"),
                        destination: URL = directory) throws {
        guard !defaults.bool(forKey: "didImportGraftLibrary") else { return }
        let previous = defaults.persistentDomain(forName: "com.itsasheruwu.graft.mac") ?? [:]
        for key in ["desktop", "player", "showLyrics", "animate", "palette", "width", "glow", "reactive", "beatSync", "display"] {
            if defaults.object(forKey: "studio." + key) == nil, let value = previous["musicScene." + key] {
                defaults.set(value, forKey: "studio." + key)
            }
        }
        let files = FileManager.default
        for folder in ["Imported Lyrics", "Lyric Effects"] {
            let old = legacy.appending(path: folder)
            let entries: [URL]
            do {
                entries = try files.contentsOfDirectory(at: old, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                                                       options: .skipsHiddenFiles)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile { continue }
            let target = destination.appending(path: folder)
            try files.createDirectory(at: target, withIntermediateDirectories: true)
            for entry in entries {
                let kind = try entry.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard kind.isRegularFile == true, kind.isSymbolicLink != true else { continue }
                var file = target.appending(path: entry.lastPathComponent)
                if folder == "Lyric Effects" {
                    guard file.pathExtension.lowercased() == "graft" else { continue }
                    file = file.deletingPathExtension().appendingPathExtension("bliss")
                }
                if !files.fileExists(atPath: file.path) {
                    try Data(contentsOf: entry).write(to: file, options: .atomic)
                }
            }
        }
        defaults.set(true, forKey: "didImportGraftLibrary")
    }
}
