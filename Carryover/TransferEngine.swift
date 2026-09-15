import Foundation

/// Copies or moves conversations between workspace containers. File copies happen first and
/// manifest edits last, so a failure mid-way leaves only orphan directories (which Xcode
/// ignores — the manifest is the source of truth), never a corrupt manifest.
final class TransferEngine {
    /// Where the agent-side session files should land for the destination container.
    struct AgentDestination {
        let slugDir: URL
        let cwd: String
    }

    private let fm = FileManager.default
    private let agentStore: AgentStore
    private let log: (String) -> Void

    init(agentStore: AgentStore, log: @escaping (String) -> Void) {
        self.agentStore = agentStore
        self.log = log
    }

    func transfer(conversations: [Conversation],
                  containersByID: [String: Container],
                  destination: Container,
                  agentDestination: AgentDestination?,
                  move: Bool,
                  dryRun: Bool) throws {
        let verb = move ? "Move" : "Copy"
        log("— \(dryRun ? "DRY RUN: " : "")\(verb) \(conversations.count) conversation(s) → \(destination.displayName) —")

        if !dryRun {
            try backUpManifests(for: conversations, destination: destination, containersByID: containersByID)
        }

        var transferred: [Conversation] = []
        for conversation in conversations {
            guard let source = containersByID[conversation.containerID] else { continue }
            do {
                try transferFiles(of: conversation, from: source, to: destination,
                                  agentDestination: agentDestination, dryRun: dryRun)
                transferred.append(conversation)
            } catch {
                log("❌ \(conversation.name): \(error.localizedDescription) — skipped")
            }
        }

        guard !transferred.isEmpty else {
            log("Nothing transferred.")
            return
        }

        try updateManifests(for: transferred, destination: destination,
                            containersByID: containersByID, move: move, dryRun: dryRun)
        if move {
            try deleteSourceFiles(of: transferred, containersByID: containersByID,
                                  agentDestination: agentDestination, dryRun: dryRun)
        }
        log("✅ \(verb) complete: \(transferred.count) conversation(s).\(dryRun ? " (dry run — nothing written)" : "")")
    }

    // MARK: - File copies

    private func transferFiles(of conversation: Conversation,
                               from source: Container,
                               to destination: Container,
                               agentDestination: AgentDestination?,
                               dryRun: Bool) throws {
        let sourceDir = source.url.appending(path: conversation.id)
        let destinationDir = destination.url.appending(path: conversation.id)
        guard fm.fileExists(atPath: sourceDir.path) else {
            throw TransferError("conversation directory missing at \(sourceDir.path)")
        }
        // v1 collision policy: same UUID already present in the destination → refuse.
        if fm.fileExists(atPath: destinationDir.path) {
            throw TransferError("a conversation with id \(conversation.id) already exists in \(destination.displayName)")
        }

        log("\(conversation.name): \(conversation.id)/ → \(destination.id)/")
        if !dryRun {
            try fm.copyItem(at: sourceDir, to: destinationDir)
        }

        try copySnapshots(of: conversation, from: source, to: destination, dryRun: dryRun)
        try copyAgentSession(of: conversation, to: agentDestination, dryRun: dryRun)
    }

    private func copySnapshots(of conversation: Conversation,
                               from source: Container,
                               to destination: Container,
                               dryRun: Bool) throws {
        let snapshotIDs = referencedSnapshotIDs(inConversationDir: source.url.appending(path: conversation.id))
        guard !snapshotIDs.isEmpty else { return }
        if !dryRun {
            try fm.createDirectory(at: destination.snapshotsURL, withIntermediateDirectories: true)
        }
        for id in snapshotIDs.sorted() {
            let snapshotSource = source.snapshotsURL.appending(path: "\(id).plist")
            let snapshotDestination = destination.snapshotsURL.appending(path: "\(id).plist")
            guard fm.fileExists(atPath: snapshotSource.path) else {
                log("  ⚠️ snapshot \(id) missing in source — skipped")
                continue
            }
            guard !fm.fileExists(atPath: snapshotDestination.path) else {
                log("  snapshot \(id) already in destination")
                continue
            }
            log("  snapshot \(id).plist")
            if !dryRun {
                try fm.copyItem(at: snapshotSource, to: snapshotDestination)
            }
        }
    }

    private func copyAgentSession(of conversation: Conversation,
                                  to agentDestination: AgentDestination?,
                                  dryRun: Bool) throws {
        guard let sessionID = conversation.sessionID else {
            log("  no agent session (not an agent-backed conversation)")
            return
        }
        guard let location = agentStore.locateSession(sessionID, excluding: agentDestination?.slugDir) else {
            log("  ⚠️ agent session \(sessionID).jsonl not found — transcript copied without agent context")
            return
        }
        guard let agentDestination else {
            log("  ⚠️ agent session found but destination project unknown — not copied")
            return
        }

        let destinationJsonl = agentDestination.slugDir.appending(path: "\(sessionID).jsonl")
        if fm.fileExists(atPath: destinationJsonl.path) {
            log("  agent session already present in destination")
        } else {
            log("  agent session \(sessionID).jsonl → \(agentDestination.slugDir.lastPathComponent)/ (cwd → \(agentDestination.cwd))")
            if !dryRun {
                try fm.createDirectory(at: agentDestination.slugDir, withIntermediateDirectories: true)
                try agentStore.copyRewritingCwd(from: location.jsonl, to: destinationJsonl, newCwd: agentDestination.cwd)
            }
        }

        if let sidecar = location.sidecar {
            let destinationSidecar = agentDestination.slugDir.appending(path: sessionID)
            if fm.fileExists(atPath: destinationSidecar.path) {
                log("  subagent sidecar already present in destination")
            } else {
                log("  subagent sidecar \(sessionID)/")
                if !dryRun {
                    try fm.copyItem(at: sidecar, to: destinationSidecar)
                }
            }
        }
    }

    // MARK: - Manifests (last, so failures above can't corrupt them)

    private func updateManifests(for transferred: [Conversation],
                                 destination: Container,
                                 containersByID: [String: Container],
                                 move: Bool,
                                 dryRun: Bool) throws {
        log("manifest: add \(transferred.count) entr\(transferred.count == 1 ? "y" : "ies") to \(destination.displayName)")
        if !dryRun {
            var manifest = try PlistIO.read(destination.manifestURL)
            var entries = manifest.root as? [[String: Any]] ?? []
            entries.append(contentsOf: transferred.map(\.rawManifestEntry))
            entries.sort {
                ($0["lastActivityDate"] as? Date ?? .distantPast) > ($1["lastActivityDate"] as? Date ?? .distantPast)
            }
            manifest.root = entries
            try PlistIO.write(manifest, to: destination.manifestURL)
        }

        guard move else { return }
        for (containerID, conversations) in Dictionary(grouping: transferred, by: \.containerID) {
            guard let source = containersByID[containerID] else { continue }
            log("manifest: remove \(conversations.count) entr\(conversations.count == 1 ? "y" : "ies") from \(source.displayName)")
            if !dryRun {
                var manifest = try PlistIO.read(source.manifestURL)
                let removedIDs = Set(conversations.map(\.id))
                var entries = manifest.root as? [[String: Any]] ?? []
                entries.removeAll { entry in
                    (entry["id"] as? String).map(removedIDs.contains) ?? false
                }
                manifest.root = entries
                try PlistIO.write(manifest, to: source.manifestURL)
            }
        }
    }

    // MARK: - Move cleanup

    private func deleteSourceFiles(of transferred: [Conversation],
                                   containersByID: [String: Container],
                                   agentDestination: AgentDestination?,
                                   dryRun: Bool) throws {
        for (containerID, conversations) in Dictionary(grouping: transferred, by: \.containerID) {
            guard let source = containersByID[containerID] else { continue }
            let movedIDs = Set(conversations.map(\.id))

            // Snapshots still referenced by conversations staying behind must survive.
            var retained = Set<String>()
            for other in source.conversations where !movedIDs.contains(other.id) {
                retained.formUnion(referencedSnapshotIDs(inConversationDir: source.url.appending(path: other.id)))
            }

            for conversation in conversations {
                let conversationDir = source.url.appending(path: conversation.id)
                let deletableSnapshots = referencedSnapshotIDs(inConversationDir: conversationDir).subtracting(retained)
                log("\(conversation.name): delete source files (\(deletableSnapshots.count) snapshot(s))")
                guard !dryRun else { continue }
                for id in deletableSnapshots {
                    let snapshot = source.snapshotsURL.appending(path: "\(id).plist")
                    if fm.fileExists(atPath: snapshot.path) {
                        try fm.removeItem(at: snapshot)
                    }
                }
                try fm.removeItem(at: conversationDir)
                if let sessionID = conversation.sessionID,
                   let location = agentStore.locateSession(sessionID, excluding: agentDestination?.slugDir) {
                    try fm.removeItem(at: location.jsonl)
                    if let sidecar = location.sidecar {
                        try fm.removeItem(at: sidecar)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func backUpManifests(for conversations: [Conversation],
                                 destination: Container,
                                 containersByID: [String: Container]) throws {
        let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        let backupDir = fm.temporaryDirectory.appending(path: "ConversationMoverBackups/\(stamp)")
        try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
        var containerIDs = Set(conversations.map(\.containerID))
        containerIDs.insert(destination.id)
        for id in containerIDs {
            guard let container = containersByID[id], fm.fileExists(atPath: container.manifestURL.path) else { continue }
            try fm.copyItem(at: container.manifestURL,
                            to: backupDir.appending(path: "\(id)-CodingAssistantManifest.plist"))
        }
        log("Manifests backed up to \(backupDir.path)")
    }

    private func referencedSnapshotIDs(inConversationDir dir: URL) -> Set<String> {
        guard let file = try? PlistIO.read(dir.appending(path: "conversation.plist")) else { return [] }
        return PlistIO.collectSnapshotIDs(in: file.root)
    }
}
