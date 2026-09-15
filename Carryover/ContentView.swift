import SwiftUI

struct ContentView: View {
    @State private var store = ConversationStore()
    @State private var collapsedContainers: Set<String> = []
    @State private var showMoveConfirmation = false
    @State private var showXcodeRunningWarning = false
    @State private var pendingMove = false

    var body: some View {
        VStack(spacing: 0) {
            if store.isXcodeRunning {
                xcodeRunningBanner
            }
            conversationList
            Divider()
            controlBar
            Divider()
            logView
        }
        .frame(minWidth: 780, minHeight: 520)
        .task { store.scan() }
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") {
                store.scan()
            }
        }
        .confirmationDialog("Move conversations?", isPresented: $showMoveConfirmation) {
            Button("Move", role: .destructive) { startTransfer(move: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Moving removes the selected conversations (and their agent sessions) from the source project.")
        }
        .alert("Xcode is running", isPresented: $showXcodeRunningWarning) {
            Button("Proceed Anyway", role: .destructive) { store.performTransfer(move: pendingMove) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Xcode keeps conversation manifests in memory and may overwrite the changes when it quits. Quit Xcode first for a safe transfer.")
        }
    }

    private var xcodeRunningBanner: some View {
        Label("Xcode is running — quit it before a real transfer, or changes may be overwritten.",
              systemImage: "exclamationmark.triangle.fill")
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.yellow.opacity(0.2))
    }

    private var conversationList: some View {
        List {
            ForEach(store.containers) { container in
                DisclosureGroup(isExpanded: expansionBinding(for: container.id)) {
                    if container.conversations.isEmpty {
                        Text("No conversations")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(container.conversations) { conversation in
                        ConversationRow(conversation: conversation,
                                        isSelected: selectionBinding(for: conversation))
                    }
                } label: {
                    HStack {
                        Image(systemName: "folder")
                        Text(container.displayName)
                            .font(.headline)
                        Text("\(container.conversations.count)")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(container.pathLabel)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .help(container.id)
                    }
                }
            }
        }
    }

    private var controlBar: some View {
        HStack(spacing: 16) {
            Picker("Destination:", selection: $store.destinationID) {
                Text("Choose a project…").tag(String?.none)
                ForEach(store.containers) { container in
                    Text(destinationLabel(for: container)).tag(String?.some(container.id))
                }
            }
            .frame(maxWidth: 340)

            Toggle("Dry run", isOn: $store.dryRun)

            Spacer()

            Text("\(store.selection.count) selected")
                .foregroundStyle(.secondary)

            Button("Copy") { startTransfer(move: false) }
                .disabled(!canTransfer)
            Button("Move") { showMoveConfirmation = true }
                .disabled(!canTransfer)
        }
        .padding(10)
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(store.logLines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .padding(8)
                .textSelection(.enabled)
            }
            .frame(height: 150)
            .background(.background.secondary)
            .onChange(of: store.logLines.count) {
                proxy.scrollTo(store.logLines.count - 1, anchor: .bottom)
            }
        }
    }

    private var canTransfer: Bool {
        store.destinationID != nil && !store.selection.isEmpty
    }

    /// Appends the project location whenever another container shares the same display
    /// name, so identically named projects are distinguishable in the picker.
    private func destinationLabel(for container: Container) -> String {
        let isAmbiguous = store.containers.contains {
            $0.id != container.id && $0.displayName == container.displayName
        }
        return isAmbiguous ? "\(container.displayName) — \(container.pathLabel)" : container.displayName
    }

    private func startTransfer(move: Bool) {
        if store.isXcodeRunning && !store.dryRun {
            pendingMove = move
            showXcodeRunningWarning = true
        } else {
            store.performTransfer(move: move)
        }
    }

    private func selectionBinding(for conversation: Conversation) -> Binding<Bool> {
        let ref = ConversationRef(containerID: conversation.containerID, conversationID: conversation.id)
        return Binding(
            get: { store.selection.contains(ref) },
            set: { selected in
                if selected {
                    store.selection.insert(ref)
                } else {
                    store.selection.remove(ref)
                }
            })
    }

    private func expansionBinding(for containerID: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedContainers.contains(containerID) },
            set: { expanded in
                if expanded {
                    collapsedContainers.remove(containerID)
                } else {
                    collapsedContainers.insert(containerID)
                }
            })
    }
}

private struct ConversationRow: View {
    let conversation: Conversation
    @Binding var isSelected: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Toggle("", isOn: $isSelected)
                .labelsHidden()
                .toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.name)
                HStack(spacing: 10) {
                    if let date = conversation.lastActivityDate {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                    }
                    Text(conversation.sizeOnDisk.formatted(.byteCount(style: .file)))
                    if conversation.sessionID == nil {
                        Text("no agent session")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    ContentView()
}
