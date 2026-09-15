import Foundation

/// The Claude Code agent-side store under ClaudeAgentConfig/projects/. Each Xcode
/// conversation's agent session lives at projects/<cwd-slug>/<sessionID>.jsonl, with an
/// optional sidecar directory projects/<cwd-slug>/<sessionID>/ holding subagent transcripts.
struct AgentStore {
    let projectsRoot: URL

    init() {
        projectsRoot = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig/projects")
    }

    /// Claude Code's project-directory naming: every character outside [A-Za-z0-9] becomes "-".
    static func slug(forPath path: String) -> String {
        String(path.map { char in
            char.isASCII && (char.isLetter || char.isNumber) ? char : "-"
        })
    }

    struct SessionLocation {
        let slugDir: URL
        let jsonl: URL
        let sidecar: URL?   // <sessionID>/ directory with subagent transcripts, if present
    }

    /// Finds the slug directory containing <sessionID>.jsonl. `excluding` skips a directory
    /// (the transfer destination) so a freshly copied session is never mistaken for the source.
    func locateSession(_ sessionID: String, excluding excludedDir: URL? = nil) -> SessionLocation? {
        let fm = FileManager.default
        guard let slugDirs = try? fm.contentsOfDirectory(at: projectsRoot, includingPropertiesForKeys: nil) else {
            return nil
        }
        for dir in slugDirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if let excludedDir, dir.standardizedFileURL.path == excludedDir.standardizedFileURL.path {
                continue
            }
            let jsonl = dir.appending(path: "\(sessionID).jsonl")
            guard fm.fileExists(atPath: jsonl.path) else { continue }
            let sidecar = dir.appending(path: sessionID)
            var isDirectory: ObjCBool = false
            let hasSidecar = fm.fileExists(atPath: sidecar.path, isDirectory: &isDirectory) && isDirectory.boolValue
            return SessionLocation(slugDir: dir, jsonl: jsonl, sidecar: hasSidecar ? sidecar : nil)
        }
        return nil
    }

    /// First "cwd" value found in the session transcript.
    func cwd(ofSessionFile url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            if let data = line.data(using: .utf8),
               let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let cwd = object["cwd"] as? String {
                return cwd
            }
        }
        return nil
    }

    /// Copies a session transcript line by line, rewriting every top-level "cwd" to `newCwd`
    /// so resuming from the destination project works. Lines that fail to parse copy unchanged.
    func copyRewritingCwd(from source: URL, to destination: URL, newCwd: String) throws {
        let text = try String(contentsOf: source, encoding: .utf8)
        var outputLines: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  object["cwd"] != nil else {
                outputLines.append(String(line))
                continue
            }
            object["cwd"] = newCwd
            let rewritten = try JSONSerialization.data(withJSONObject: object)
            outputLines.append(String(decoding: rewritten, as: UTF8.self))
        }
        try outputLines.joined(separator: "\n").write(to: destination, atomically: true, encoding: .utf8)
    }
}
