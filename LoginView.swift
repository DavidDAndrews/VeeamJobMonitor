import SwiftUI

struct LoginView: View {
    @ObservedObject var api: VeeamAPIService
    @AppStorage(AppearancePreference.storageKey) private var isDarkModeEnabled = false

    @State private var friendlyName = ""
    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var savedConnections: [SavedConnectionEntry] = []
    @State private var showDeleteConfirmation = false
    @State private var mfaCode = ""
    @State private var vbrToken = ""
    @State private var reachabilityStatus: ReachabilityStatus = .unknown
    @State private var reachabilityDebounceTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: Theme.Spacing.xl) {
            VStack(spacing: Theme.Spacing.md) {
                ZStack {
                    Circle()
                        .fill(Theme.brandTint)
                        .frame(width: 76, height: 76)
                    Image(systemName: "shield.checkered")
                        .font(.system(size: 38, weight: .medium))
                        .foregroundStyle(Theme.brand)
                }
                .help("Security status icon for this connection screen.")

                Text("Veeam Monitor")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.textPrimary)
                    .help("Connect to your Veeam Backup & Replication server.")
            }

            VStack(spacing: Theme.Spacing.md) {
                LabeledServerField(
                    label: "Server IP Address",
                    text: $serverURL,
                    options: savedConnections,
                    placeholder: "https://172.22.18.28:9419",
                    reachabilityStatus: reachabilityStatus,
                    onSelect: applySavedConnection,
                    onAddServer: prepareAddServer
                )
                LabeledTextField(label: "Friendly Server Name", text: $friendlyName, placeholder: "Example: Chicago VBR")
                LabeledTextField(label: "Username", text: $username, placeholder: "veeamadmin")
                LabeledSecureField(label: "Password", text: $password)
            }

            if let error = api.errorMessage {
                VStack(spacing: 6) {
                    Text(error)
                        .foregroundStyle(Theme.statusFailed)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    if error.contains("401") || error.lowercased().contains("denied") {
                        Text("Try username formats: veeamadmin · .\\veeamadmin · DOMAIN\\veeamadmin")
                            .foregroundStyle(.secondary)
                            .font(.caption2)
                            .multilineTextAlignment(.center)
                    }
                }
            }

            if api.mfaRequired {
                VStack(alignment: .leading, spacing: 8) {
                    Text(api.mfaPromptMessage ?? "Multi-factor authentication is required.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    SecureField("MFA verification code", text: $mfaCode)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        let code = mfaCode.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !code.isEmpty else { return }
                        Task { await api.submitMFA(code: code) }
                    } label: {
                        Text("Verify MFA")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(api.isLoading || mfaCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Submit your one-time multi-factor authentication code.")

                    if api.requiresVBRTokenLogin {
                        Text("This Veeam server requires VBR token login for MFA-enabled accounts. Paste a platform token below.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        SecureField("VBR Token", text: $vbrToken)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            let token = vbrToken.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !token.isEmpty else { return }
                            Task { await performVBRTokenLogin(vbrToken: token) }
                        } label: {
                            Text("Sign In with VBR Token")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(api.isLoading || vbrToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help("Use a platform token when MFA login requires token-based authentication.")
                    }
                }
                .padding(.top, 4)
            }

            VStack(spacing: Theme.Spacing.md) {
                Button(action: performLogin) {
                    ZStack {
                        RoundedRectangle(cornerRadius: Theme.Radius.small)
                            .fill(Theme.brand)
                        if api.isLoading {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        } else {
                            Text("Sign In")
                                .font(.headline.weight(.semibold))
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.small))
                }
                .buttonStyle(HoverLiftButtonStyle())
                .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
                .disabled(api.isLoading || serverURL.isEmpty || username.isEmpty || password.isEmpty)
                .keyboardShortcut(.return, modifiers: [])
                .help("Sign in to the selected Veeam server with the credentials above.")

                Button(role: .destructive, action: { showDeleteConfirmation = true }) {
                    Label("Delete Server", systemImage: "trash")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .controlSize(.large)
                .disabled(api.isLoading || serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !savedConnections.contains(where: { $0.serverURL == serverURL }))
                .help("Delete the selected saved server entry and its stored credentials.")
            }
        }
        .padding(28)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.large))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.large)
                .stroke(Theme.separator, lineWidth: 0.5)
        )
        .themeShadow(Theme.shadowSubtle)
        .overlay(alignment: .topTrailing) {
            Button(action: { isDarkModeEnabled.toggle() }) {
                Image(systemName: isDarkModeEnabled ? "sun.max.fill" : "moon.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(Theme.brandTint, in: RoundedRectangle(cornerRadius: Theme.Radius.small))
            }
            .buttonStyle(.plain)
            .help(isDarkModeEnabled ? "Switch to light mode." : "Switch to dark mode.")
            .padding(10)
        }
        .onAppear {
            loadSaved()
            scheduleReachabilityCheck()
        }
        .onChange(of: serverURL) { _, newValue in
            populateCredentials(for: newValue)
            scheduleReachabilityCheck()
        }
        .onDisappear {
            reachabilityDebounceTask?.cancel()
        }
        .onSubmit {
            if api.mfaRequired {
                let code = mfaCode.trimmingCharacters(in: .whitespacesAndNewlines)
                if !code.isEmpty {
                    Task { await api.submitMFA(code: code) }
                }
            } else {
                performLogin()
            }
        }
        .onChange(of: api.mfaRequired) { _, required in
            if !required {
                mfaCode = ""
                vbrToken = ""
            }
        }
        .alert("Delete Server Entry?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                deleteSelectedServerEntry()
            }
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("This will remove the saved server, credentials, and friendly name for this entry.")
        }
    }

    private func performLogin() {
        serverURL = normalizedServerURLForLogin(serverURL)
        guard validateServerIPAddressFormat(showError: true) else {
            return
        }
        reachabilityDebounceTask?.cancel()
        Task {
            reachabilityStatus = .checking
            let status = await api.checkServerReachability(serverURL, definitive: true)
            reachabilityStatus = status
            guard status == .reachable else {
                api.errorMessage = ServerReachability.unreachableMessage(for: serverURL)
                return
            }
            await api.login(serverURL: serverURL, username: username, password: password, friendlyName: friendlyName)
        }
    }

    private func performVBRTokenLogin(vbrToken: String) async {
        serverURL = normalizedServerURLForLogin(serverURL)
        guard validateServerIPAddressFormat(showError: true) else { return }

        reachabilityDebounceTask?.cancel()
        reachabilityStatus = .checking
        let status = await api.checkServerReachability(serverURL, definitive: true)
        reachabilityStatus = status
        guard status == .reachable else {
            api.errorMessage = ServerReachability.unreachableMessage(for: serverURL)
            return
        }
        await api.loginWithVBRToken(
            serverURL: serverURL,
            friendlyName: friendlyName,
            vbrToken: vbrToken
        )
    }

    private func scheduleReachabilityCheck() {
        // Cancel only the debounce wait — never cancel an in-flight URLSession probe.
        reachabilityDebounceTask?.cancel()

        let candidate = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else {
            reachabilityStatus = .unknown
            return
        }

        let normalized = normalizedServerURLForLogin(candidate)
        guard isValidServerIPv4Input(normalized) else {
            reachabilityStatus = .unknown
            return
        }

        reachabilityStatus = .checking
        reachabilityDebounceTask = Task {
            let debounce = UInt64(ServerReachability.debounceInterval * 1_000_000_000)
            try? await Task.sleep(nanoseconds: debounce)
            guard !Task.isCancelled else { return }

            if let status = await ServerReachabilityProbe.shared.check(
                serverURL: candidate,
                normalized: normalized
            ) {
                reachabilityStatus = status
            }
        }
    }

    private func normalizedServerURLForLogin(_ input: String) -> String {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return value }

        if !value.lowercased().hasPrefix("http://") && !value.lowercased().hasPrefix("https://") {
            value = "https://\(value)"
        }

        guard var components = URLComponents(string: value), let host = components.host, !host.isEmpty else {
            return value
        }

        if components.port == nil {
            components.port = 9419
        }
        return components.string ?? value
    }

    private func loadSaved() {
        savedConnections = api.savedConnectionEntries()
        if let saved = api.loadSavedCredentials() {
            serverURL = saved.serverURL
            username  = saved.username
            password  = saved.password
            friendlyName = saved.friendlyName ?? ""
        } else {
            clearAllFields()
        }
    }

    private func applySavedConnection(_ selectedServerURL: String) {
        serverURL = selectedServerURL
        populateCredentials(for: selectedServerURL)
        scheduleReachabilityCheck()
    }

    private func populateCredentials(for serverURL: String) {
        guard let saved = api.loadSavedCredentials(for: serverURL) else { return }
        username = saved.username
        password = saved.password
        friendlyName = saved.friendlyName ?? ""
    }

    private func prepareAddServer() {
        clearAllFields()
        reachabilityStatus = .unknown
        reachabilityDebounceTask?.cancel()
    }

    private func deleteSelectedServerEntry() {
        let target = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return }
        api.deleteSavedConnection(serverURL: target)
        savedConnections = api.savedConnectionEntries()
        if let first = savedConnections.first {
            applySavedConnection(first.serverURL)
        } else {
            clearAllFields()
        }
    }

    private func clearAllFields() {
        friendlyName = ""
        serverURL = ""
        username = ""
        password = ""
        reachabilityStatus = .unknown
    }

    private func validateServerIPAddressFormat(showError: Bool) -> Bool {
        serverURL = normalizedServerURLForLogin(serverURL)
        let isValid = isValidServerIPv4Input(serverURL)
        if !isValid, showError {
            api.errorMessage = "Invalid Server IP Address format. Use XXX.XXX.XXX.XXX with each octet between 0 and 254."
        }
        return isValid
    }

    private func isValidServerIPv4Input(_ input: String) -> Bool {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let host: String
        if let url = URL(string: trimmed), let extracted = url.host {
            host = extracted
        } else if let url = URL(string: "https://\(trimmed)"), let extracted = url.host {
            host = extracted
        } else {
            host = trimmed
        }

        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        for octet in octets {
            guard let value = Int(octet), (0...254).contains(value) else { return false }
        }
        return true
    }
}

// MARK: - Helper Views

private struct LabeledTextField: View {
    let label: String
    @Binding var text: String
    let placeholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .help("\(label).")
        }
    }
}

private struct LabeledServerField: View {
    let label: String
    @Binding var text: String
    let options: [SavedConnectionEntry]
    let placeholder: String
    let reachabilityStatus: ReachabilityStatus
    let onSelect: (String) -> Void
    let onAddServer: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .help("Enter the Veeam server IPv4 address. Port 9419 is used for API access.")

                ReachabilityIndicator(status: reachabilityStatus)

                Menu {
                    if options.isEmpty {
                        Text("No saved servers")
                    } else {
                        ForEach(options, id: \.serverURL) { option in
                            Button(option.friendlyName) {
                                onSelect(option.serverURL)
                            }
                        }
                    }
                    Divider()
                    Button("+ Add Server") {
                        onAddServer()
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .frame(width: 28, height: 28)
                }
                .menuIndicator(.hidden)
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Open saved server entries, or choose Add Server to create a new connection profile.")
            }
        }
    }
}

private struct LabeledSecureField: View {
    let label: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            SecureField("••••••••", text: $text)
                .textFieldStyle(.roundedBorder)
                .help("\(label).")
        }
    }
}

private struct HoverLiftButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverLiftButtonBody(configuration: configuration)
    }
}

private struct HoverLiftButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.small)
                    .fill(Color.white.opacity(isHovered ? 0.10 : 0.0))
            )
            .shadow(color: .black.opacity(isHovered ? 0.20 : 0.12), radius: isHovered ? 8 : 3, x: 0, y: isHovered ? 5 : 2)
            .scaleEffect(configuration.isPressed ? 0.98 : (isHovered ? 1.01 : 1.0))
            .animation(.easeOut(duration: 0.14), value: isHovered)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
            .onHover { hovering in
                isHovered = hovering
            }
    }
}
