import SwiftUI
import AppKit

enum NewAgentSessionDestination {
    case currentWorkspaceTab
    case newWorkspace

    var title: String {
        switch self {
        case .currentWorkspaceTab: return "New Agent Session"
        case .newWorkspace: return "New Workspace"
        }
    }

    var subtitle: String {
        switch self {
        case .currentWorkspaceTab:
            return "Launch a profile in a persistent tmux session."
        case .newWorkspace:
            return "Choose the first session for a new workspace."
        }
    }

    var createTitle: String {
        switch self {
        case .currentWorkspaceTab: return "Create Session"
        case .newWorkspace: return "Create Workspace"
        }
    }
}

struct NewAgentSessionView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss

    let destination: NewAgentSessionDestination

    @State private var selectedProfileID = ""
    @State private var workingDirectory = FileManager.default.homeDirectoryForCurrentUser.path
    @State private var quickProfileOpen = false

    private var hosts: [HostTarget] { [.local] + SSHConfigHosts.aliases().map { .ssh(alias: $0) } }
    private var profiles: [AgentProfile] { AgentProfileStore.profiles.sorted(by: profileSort) }
    private var selectedProfile: AgentProfile? {
        profiles.first { $0.id == selectedProfileID } ?? profiles.first
    }

    init(destination: NewAgentSessionDestination = .currentWorkspaceTab) {
        self.destination = destination
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(destination.title).font(.system(size: 22, weight: .semibold))
                    Text(destination.subtitle)
                        .font(.system(size: 12)).foregroundStyle(Theme.text3)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
            }
            .padding(24)

            Divider().overlay(Color.white.opacity(0.08))

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    formRow("Launch profile", detail: "Agent, device, command, and config live in profiles.") {
                        HStack(spacing: 8) {
                            Picker("", selection: $selectedProfileID) {
                                ForEach(profiles) { profile in
                                    Text(profile.displayLabel).tag(profile.id)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 270)

                            Button("New Profile") {
                                quickProfileOpen = true
                            }
                            .controlSize(.small)
                        }
                    }

                    if let selectedProfile {
                        profileSummary(selectedProfile)
                    }

                    Divider().overlay(Color.white.opacity(0.06))

                    formRow("Working directory", detail: "Separate from the profile/config folder.") {
                        HStack(spacing: 8) {
                            TextField("~/projects/foo", text: $workingDirectory)
                                .textFieldStyle(.roundedBorder).frame(width: 270)
                            if selectedHost == .local {
                                Button("Choose…", action: chooseDirectory).controlSize(.small)
                            }
                        }
                    }
                }
                .padding(24)
            }

            Divider().overlay(Color.white.opacity(0.08))
            HStack {
                if selectedProfile?.agent == .codex && selectedProfile?.hookMode == .glintOverlay {
                    Label("First launch may require /hooks trust", systemImage: "checkmark.shield")
                        .font(.system(size: 11)).foregroundStyle(Theme.text3)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(destination.createTitle, action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
                    .tint(store.accent)
            }
            .padding(18)
        }
        .frame(width: 680, height: 430)
        .background(Theme.bgWindow)
        .preferredColorScheme(.dark)
        .onAppear { ensureSelectedProfile() }
        .onChange(of: selectedProfileID) { _, _ in
            if selectedHost != .local, workingDirectory.hasPrefix("/") {
                workingDirectory = "~/"
            }
        }
        .sheet(isPresented: $quickProfileOpen) {
            AgentProfileEditorView(
                initialProfile: selectedProfile ?? .defaultProfile(for: .codex),
                editingID: nil,
                saveTitle: "Create Profile"
            ) { profile in
                AgentProfileStore.save(profile)
                selectedProfileID = profile.id
            }
            .environmentObject(store)
        }
    }

    private var canCreate: Bool {
        guard let profile = selectedProfile else { return false }
        return !workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (profile.agent == .terminal || !profile.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @ViewBuilder private func formRow<Content: View>(_ title: String, detail: String,
                                                      @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text1)
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.text4)
            }
            .frame(width: 245, alignment: .leading)
            Spacer()
            content()
        }
    }

    private func fieldRow(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        formRow(title, detail: profileFieldHelp(title)) {
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder).frame(width: 300)
        }
    }

    @ViewBuilder private func profileSummary(_ profile: AgentProfile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(profile.agent.displayName, systemImage: profileIcon(profile.agent))
                Text(profile.deviceLabel)
                if profile.hookMode == .glintOverlay {
                    Text("hooks")
                }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.text3)

            Text(profile.summaryLine)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.text4)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.035))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.05), lineWidth: 0.5)
                )
        )
    }

    private func profileFieldHelp(_ field: String) -> String {
        switch field {
        case "Name": return "A reusable label for this agent profile."
        case "Command": return "Executable name or absolute path."
        case "Config folder": return "Agent account/config state; not the project directory."
        case "Settings file": return "Claude settings to merge with Glint's temporary overlay."
        case "Environment file": return "Optional shell file sourced before launch."
        default: return "Arguments added before one-off command arguments."
        }
    }

    private func create() {
        guard let profile = selectedProfile else { return }
        let host = hostTarget(for: profile)
        switch destination {
        case .currentWorkspaceTab:
            store.createManagedSession(agent: profile.agent, host: host, profile: profile,
                                       workingDirectory: workingDirectory)
        case .newWorkspace:
            store.createManagedSessionInNewWorkspace(agent: profile.agent, host: host, profile: profile,
                                                     workingDirectory: workingDirectory)
        }
        dismiss()
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { workingDirectory = url.path }
    }

    private var selectedHost: HostTarget {
        selectedProfile.map(hostTarget(for:)) ?? .local
    }

    private func ensureSelectedProfile() {
        if !profiles.contains(where: { $0.id == selectedProfileID }) {
            selectedProfileID = profiles.first?.id ?? ""
        }
    }

    private func hostTarget(for profile: AgentProfile) -> HostTarget {
        guard let hostScope = profile.hostScope else { return .local }
        return .ssh(alias: hostScope)
    }

    private func profileSort(_ lhs: AgentProfile, _ rhs: AgentProfile) -> Bool {
        let l = "\(lhs.hostScope ?? "")|\(lhs.agent.rawValue)|\(lhs.label)"
        let r = "\(rhs.hostScope ?? "")|\(rhs.agent.rawValue)|\(rhs.label)"
        return l.localizedCaseInsensitiveCompare(r) == .orderedAscending
    }

    private func profileIcon(_ agent: AgentKind) -> String {
        switch agent {
        case .claude: return "sparkle"
        case .codex: return "terminal"
        case .opencode: return "shippingbox"
        case .terminal: return "apple.terminal"
        }
    }
}

struct AgentProfileEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: WorkspaceStore

    let editingID: String?
    let saveTitle: String
    let onSave: (AgentProfile) -> Void

    @State private var agent: AgentKind
    @State private var hostID: String
    @State private var baseProfileID: String
    @State private var profileName: String
    @State private var command: String
    @State private var configDir: String
    @State private var settingsFile: String
    @State private var envFile: String
    @State private var extraArguments: String
    @State private var injectHooks: Bool

    init(initialProfile: AgentProfile, editingID: String?,
         saveTitle: String, onSave: @escaping (AgentProfile) -> Void) {
        self.editingID = editingID
        self.saveTitle = saveTitle
        self.onSave = onSave
        _agent = State(initialValue: initialProfile.agent)
        _hostID = State(initialValue: initialProfile.hostScope.map { "ssh:\($0)" } ?? "local")
        _baseProfileID = State(initialValue: initialProfile.id)
        _profileName = State(initialValue: initialProfile.label)
        _command = State(initialValue: initialProfile.command)
        _configDir = State(initialValue: initialProfile.configDir ?? "")
        _settingsFile = State(initialValue: initialProfile.settingsFile ?? "")
        _envFile = State(initialValue: initialProfile.envFile ?? "")
        _extraArguments = State(initialValue: initialProfile.args.joined(separator: " "))
        _injectHooks = State(initialValue: initialProfile.hookMode == .glintOverlay)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(editingID == nil ? "New Profile" : "Edit Profile")
                        .font(.system(size: 22, weight: .semibold))
                    Text("Profiles define agent, device, command, and config home.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text3)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
            }
            .padding(24)

            Divider().overlay(Color.white.opacity(0.08))

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if editingID == nil {
                        formRow("Profile", detail: "Start from an existing profile.") {
                            Picker("", selection: $baseProfileID) {
                                ForEach(AgentProfileStore.profiles.sorted(by: profileSort)) { profile in
                                    Text(profile.displayLabel).tag(profile.id)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 300)
                        }
                    }

                    formRow("Agent", detail: "Choose the CLI this profile launches.") {
                        Picker("", selection: $agent) {
                            ForEach(AgentKind.allCases) { kind in
                                Text(kind.displayName).tag(kind)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 300)
                    }

                    formRow("Device", detail: "Remote devices come from ~/.ssh/config.") {
                        Picker("", selection: $hostID) {
                            ForEach(hostOptions, id: \.id) { host in
                                Text(host.label).tag(host.id)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 300)
                    }

                    Divider().overlay(Color.white.opacity(0.06))

                    fieldRow("Name", text: $profileName, placeholder: "Codex VS")
                    if agent != .terminal {
                        fieldRow("Command", text: $command, placeholder: agent.defaultCommand)
                        fieldRow("Config folder", text: $configDir, placeholder: "~/.codex")
                        if agent == .claude {
                            fieldRow("Settings file", text: $settingsFile, placeholder: "~/.claude/settings.json")
                        }
                        fieldRow("Environment file", text: $envFile, placeholder: "Optional shell env file")
                        fieldRow("Extra arguments", text: $extraArguments, placeholder: "--model …")
                        if agent == .claude || agent == .codex {
                            formRow("Status hooks", detail: agent == .codex
                                    ? "Codex asks you to trust generated hooks once with /hooks."
                                    : "Injected only into managed sessions.") {
                                Toggle("Inject Glint hooks", isOn: $injectHooks).labelsHidden()
                            }
                        }
                    }
                }
                .padding(24)
            }

            Divider().overlay(Color.white.opacity(0.08))
            HStack {
                Text(profilePreview)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.text4)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(saveTitle) {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
                .tint(store.accent)
            }
            .padding(18)
        }
        .frame(width: 680, height: 650)
        .background(Theme.bgWindow)
        .preferredColorScheme(.dark)
        .onChange(of: baseProfileID) { _, id in
            guard editingID == nil,
                  let profile = AgentProfileStore.profiles.first(where: { $0.id == id }) else { return }
            load(profile)
        }
        .onChange(of: agent) { oldAgent, newAgent in
            guard editingID == nil else { return }
            let oldDefault = AgentProfile.defaultProfile(for: oldAgent)
            let newDefault = AgentProfile.defaultProfile(for: newAgent)
            if profileName == oldDefault.label {
                profileName = newDefault.label
            }
            if command.isEmpty || command == oldDefault.command {
                command = newDefault.command
            }
            if configDir.isEmpty || configDir == (oldDefault.configDir ?? "") {
                configDir = newDefault.configDir ?? ""
            }
            if settingsFile.isEmpty || settingsFile == (oldDefault.settingsFile ?? "") {
                settingsFile = newDefault.settingsFile ?? ""
            }
            if envFile == (oldDefault.envFile ?? "") {
                envFile = newDefault.envFile ?? ""
            }
            if extraArguments == oldDefault.args.joined(separator: " ") {
                extraArguments = newDefault.args.joined(separator: " ")
            }
            if oldDefault.hookMode == (injectHooks ? .glintOverlay : .disabled) {
                injectHooks = newDefault.hookMode == .glintOverlay
            }
        }
    }

    private var canSave: Bool {
        !profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (agent == .terminal || !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var hostOptions: [(id: String, label: String)] {
        var options = [(id: "local", label: String(localized: "This Mac"))]
        options += SSHConfigHosts.aliases().map { (id: "ssh:\($0)", label: $0) }
        if hostID != "local", !options.contains(where: { $0.id == hostID }) {
            options.append((id: hostID, label: String(hostID.dropFirst("ssh:".count))))
        }
        return options
    }

    private var hostScope: String? {
        guard hostID != "local" else { return nil }
        return String(hostID.dropFirst("ssh:".count))
    }

    private var profilePreview: String {
        let device = hostScope ?? String(localized: "This Mac")
        let config = configDir.trimmingCharacters(in: .whitespacesAndNewlines)
        if config.isEmpty { return "\(agent.displayName) · \(device)" }
        return "\(agent.displayName) · \(device) · \(config)"
    }

    @ViewBuilder private func formRow<Content: View>(_ title: String, detail: String,
                                                      @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text1)
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.text4)
            }
            .frame(width: 245, alignment: .leading)
            Spacer()
            content()
        }
    }

    private func fieldRow(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        formRow(title, detail: profileFieldHelp(title)) {
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
        }
    }

    private func profileFieldHelp(_ field: String) -> String {
        switch field {
        case "Name": return "Reusable label shown when launching sessions."
        case "Command": return "Executable name or absolute path."
        case "Config folder": return "Agent account/config state. Codex uses this as CODEX_HOME."
        case "Settings file": return "Claude settings to merge with Glint's temporary overlay."
        case "Environment file": return "Optional shell file sourced before launch."
        default: return "Arguments added before one-off command arguments."
        }
    }

    private func load(_ profile: AgentProfile, keepDevice: Bool = false) {
        agent = profile.agent
        if !keepDevice {
            hostID = profile.hostScope.map { "ssh:\($0)" } ?? "local"
        }
        profileName = profile.label
        command = profile.command
        configDir = profile.configDir ?? ""
        settingsFile = profile.settingsFile ?? ""
        envFile = profile.envFile ?? ""
        extraArguments = profile.args.joined(separator: " ")
        injectHooks = profile.hookMode == .glintOverlay
    }

    private func save() {
        let id = editingID ?? AgentProfileStore.newProfileID(for: agent)
        let profile = AgentProfile(
            id: id,
            label: profileName.trimmingCharacters(in: .whitespacesAndNewlines),
            agent: agent,
            hostScope: hostScope,
            command: agent == .terminal ? "" : command,
            configDir: agent == .terminal ? nil : nilIfEmpty(configDir),
            settingsFile: agent == .claude ? nilIfEmpty(settingsFile) : nil,
            envFile: agent == .terminal ? nil : nilIfEmpty(envFile),
            args: agent == .terminal ? [] : splitArguments(extraArguments),
            hookMode: injectHooks && (agent == .claude || agent == .codex) ? .glintOverlay : .disabled
        )
        onSave(profile)
        dismiss()
    }

    private func profileSort(_ lhs: AgentProfile, _ rhs: AgentProfile) -> Bool {
        let l = "\(lhs.hostScope ?? "")|\(lhs.agent.rawValue)|\(lhs.label)"
        let r = "\(rhs.hostScope ?? "")|\(rhs.agent.rawValue)|\(rhs.label)"
        return l.localizedCaseInsensitiveCompare(r) == .orderedAscending
    }
}

private func nilIfEmpty(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func splitArguments(_ input: String) -> [String] {
    var result: [String] = [], current = "", quote: Character?, escaped = false
    for ch in input {
        if escaped { current.append(ch); escaped = false; continue }
        if ch == "\\" { escaped = true; continue }
        if let q = quote {
            if ch == q { quote = nil } else { current.append(ch) }
        } else if ch == "'" || ch == "\"" { quote = ch }
        else if ch.isWhitespace { if !current.isEmpty { result.append(current); current = "" } }
        else { current.append(ch) }
    }
    if escaped { current.append("\\") }
    if !current.isEmpty { result.append(current) }
    return result
}
