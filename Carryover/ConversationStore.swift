import AppKit
import Foundation
import Observation

@Observable
final class ConversationStore {
    var containers: [Container] = []
    var selection = Set<ConversationRef>()
    var destinationID: String?
    var dryRun = true
    var logLines: [String] = []

    let userDataRoot = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Developer/Xcode/UserData/CodingAssistant")
    let agentStore = AgentStore()

    var isXcodeRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dt.Xcode").isEmpty
    }

    var destination: Container? {
        containers.first { $0.id == destinationID }
    }

    var selectedConversations: [Conversation] {
        containers.flatMap { container in
            container.conversations.filter {
                selection.contains(ConversationRef(containerID: container.id, conversationID: $0.id))
            }
        }
    }

    func log(_ message: String) {
        logLines.append(message)
    }

    // MARK: - Scanning

    func scan() {
        let fm = FileManager.default
        var result: [Container] = []
        let dirs = (try? fm.contentsOfDirectory(at: userDataRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for dir in dirs.sorted(by: { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }) {
            let manifestURL = dir.appending(path: "CodingAssistantManifest.plist")
            guard fm.fileExists(atPath: manifestURL.path) else { continue }
            guard let manifest = try? PlistIO.read(manifestURL),
                  let entries = manifest.root as? [[String: Any]] else {
                log("⚠️ Could not read manifest in \(dir.lastPathComponent)")
                continue
            }
            var conversations: [Conversation] = []
            for entry in entries {
                guard let id = entry["id"] as? String else { continue }
                let conversationDir = dir.appending(path: id)
                conversations.append(Conversation(
                    id: id,
                    containerID: dir.lastPathComponent,
                    name: entry["name"] as? String ?? "Untitled",
                    startDate: entry["startDate"] as? Date,
                    lastActivityDate: entry["lastActivityDate"] as? Date,
                    sizeOnDisk: Self.directorySize(conversationDir),
                    sessionID: Self.sessionID(inConversationDir: conversationDir),
                    rawManifestEntry: entry))
            }
            result.append(Container(
                id: dir.lastPathComponent,
                displayName: Self.displayName(forContainerDirName: dir.lastPathComponent),
                url: dir,
                projectPath: projectPath(for: conversations),
                conversations: conversations))
        }
        containers = result

        // Drop selection/destination entries that no longer exist on disk.
        selection = selection.filter { ref in
            containers.contains { container in
                container.id == ref.containerID
                    && container.conversations.contains { $0.id == ref.conversationID }
            }
        }
        if let destinationID, !containers.contains(where: { $0.id == destinationID }) {
            self.destinationID = nil
        }

        let total = containers.reduce(0) { $0 + $1.conversations.count }
        log("Scanned \(containers.count) project container(s), \(total) conversation(s).")
        verifySlugRule()
    }

    /// Sanity-check the cwd → slug rule against every session actually on disk; a mismatch
    /// means computed destination slugs can't be trusted for empty destination containers.
    private func verifySlugRule() {
        for container in containers {
            for conversation in container.conversations {
                guard let sessionID = conversation.sessionID,
                      let location = agentStore.locateSession(sessionID),
                      let cwd = agentStore.cwd(ofSessionFile: location.jsonl) else { continue }
                let computed = AgentStore.slug(forPath: cwd)
                if computed != location.slugDir.lastPathComponent {
                    log("⚠️ Slug rule mismatch for \(cwd): computed \(computed), on disk \(location.slugDir.lastPathComponent)")
                }
            }
        }
    }

    // MARK: - Transfer

    func performTransfer(move: Bool) {
        guard let destination else {
            log("No destination selected.")
            return
        }
        let conversations = selectedConversations.filter { $0.containerID != destination.id }
        if conversations.count != selectedConversations.count {
            log("Skipping \(selectedConversations.count - conversations.count) conversation(s) already in \(destination.displayName).")
        }
        guard !conversations.isEmpty else {
            log("Nothing to transfer.")
            return
        }

        // Resolve the agent-side destination once per transfer: infer it from an existing
        // destination conversation, else ask for the destination project folder.
        var agentDestination: TransferEngine.AgentDestination?
        if conversations.contains(where: { $0.sessionID != nil }) {
            agentDestination = inferAgentDestination(for: destination) ?? askForAgentDestination(container: destination)
            if agentDestination == nil {
                log("⚠️ No agent-side destination resolved — agent session files will not be copied.")
            }
        }

        let engine = TransferEngine(agentStore: agentStore) { [weak self] in self?.log($0) }
        let containersByID = Dictionary(uniqueKeysWithValues: containers.map { ($0.id, $0) })
        do {
            try engine.transfer(conversations: conversations,
                                containersByID: containersByID,
                                destination: destination,
                                agentDestination: agentDestination,
                                move: move,
                                dryRun: dryRun)
        } catch {
            log("❌ Transfer failed: \(error.localizedDescription)")
        }
        if !dryRun {
            scan()
        }
    }

    /// The container-name hash isn't reversible, but any agent-backed conversation
    /// reveals the project's real folder via its session transcript's cwd.
    private func projectPath(for conversations: [Conversation]) -> String? {
        for conversation in conversations {
            guard let sessionID = conversation.sessionID,
                  let location = agentStore.locateSession(sessionID),
                  let cwd = agentStore.cwd(ofSessionFile: location.jsonl) else { continue }
            return cwd
        }
        return nil
    }

    /// The container-name hash isn't reversible, but any existing conversation in the
    /// destination reveals the project's slug directory and real cwd.
    private func inferAgentDestination(for destination: Container) -> TransferEngine.AgentDestination? {
        for conversation in destination.conversations {
            guard let sessionID = conversation.sessionID,
                  let location = agentStore.locateSession(sessionID),
                  let cwd = agentStore.cwd(ofSessionFile: location.jsonl) else { continue }
            return TransferEngine.AgentDestination(slugDir: location.slugDir, cwd: cwd)
        }
        return nil
    }

    private func askForAgentDestination(container: Container) -> TransferEngine.AgentDestination? {
        let panel = NSOpenPanel()
        panel.message = "“\(container.displayName)” has no existing agent sessions. Pick the folder the project is opened from so agent sessions land in the right place."
        panel.prompt = "Use This Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let cwd = url.standardizedFileURL.path
        let slugDir = agentStore.projectsRoot.appending(path: AgentStore.slug(forPath: cwd))
        log("Destination project folder: \(cwd) → \(slugDir.lastPathComponent)/")
        return TransferEngine.AgentDestination(slugDir: slugDir, cwd: cwd)
    }

    // MARK: - Helpers

    static func displayName(forContainerDirName name: String) -> String {
        if let range = name.range(of: "-[a-z]{28}$", options: .regularExpression) {
            return String(name[..<range.lowerBound]).replacingOccurrences(of: "_", with: " ")
        }
        return name
    }

    static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    static func sessionID(inConversationDir dir: URL) -> String? {
        // assistantConfiguration is a Data value holding JSON like
        // {"agent":{"_0":{"sessionID":"<uuid>"}}} — search it defensively.
        guard let file = try? PlistIO.read(dir.appending(path: "conversation.plist")),
              let root = file.root as? [String: Any],
              let configData = root["assistantConfiguration"] as? Data,
              let json = try? JSONSerialization.jsonObject(with: configData) else {
            return nil
        }
        return findSessionID(in: json)
    }

    private static func findSessionID(in value: Any) -> String? {
        guard let dict = value as? [String: Any] else { return nil }
        if let id = dict["sessionID"] as? String {
            return id
        }
        for (_, sub) in dict {
            if let found = findSessionID(in: sub) {
                return found
            }
        }
        return nil
    }
}
