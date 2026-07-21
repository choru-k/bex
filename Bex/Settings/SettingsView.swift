import AppKit
import Carbon.HIToolbox
import SwiftUI

struct SettingsView: View {
  private enum Category: Hashable {
    case general
    case provider
    case fixAndSend
    case privacy
  }

  @ObservedObject var viewModel: SettingsViewModel
  @State private var selectedCategory: Category
  @State private var confirmDeleteSavedDraft = false
  @State private var confirmClearHistory = false

  init(viewModel: SettingsViewModel) {
    self.viewModel = viewModel
    _selectedCategory = State(
      initialValue: viewModel.setupOrigin == nil ? .general : .provider
    )
  }

  var body: some View {
    VStack(spacing: 0) {
      TabView(selection: $selectedCategory) {
        generalCategory
          .tag(Category.general)
          .tabItem {
            Label("General", systemImage: "gearshape")
              .accessibilityIdentifier("settings-category-general")
          }

        providerCategory
          .tag(Category.provider)
          .tabItem {
            Label("Provider", systemImage: "network")
              .accessibilityIdentifier("settings-category-provider")
          }

        fixAndSendCategory
          .tag(Category.fixAndSend)
          .tabItem {
            Label("Fix & Send", systemImage: "paperplane")
              .accessibilityIdentifier("settings-category-fix-and-send")
          }

        privacyCategory
          .tag(Category.privacy)
          .tabItem {
            Label("Privacy", systemImage: "hand.raised")
              .accessibilityIdentifier("settings-category-privacy")
          }
      }
      .tabViewStyle(.automatic)

      rootErrors
    }
    .task {
      await viewModel.load()
    }
    .onChange(of: viewModel.setupOrigin) { origin in
      selectedCategory = origin == nil ? .general : .provider
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) {
      _ in
      viewModel.refreshAccessibilityState()
    }
    .onDisappear {
      viewModel.close()
    }
    .alert("Delete Saved Draft?", isPresented: $confirmDeleteSavedDraft) {
      Button("Delete Saved Draft", role: .destructive) {
        viewModel.deleteSavedDraft()
      }
      Button("Cancel", role: .cancel) {}
        .keyboardShortcut(.defaultAction)
    } message: {
      Text(
        "This deletes the draft saved for restoration. "
          + "Your current in-memory Quick Check draft remains unchanged."
      )
    }
    .alert("Clear History?", isPresented: $confirmClearHistory) {
      Button("Clear History", role: .destructive) {
        viewModel.clearHistory()
      }
      Button("Cancel", role: .cancel) {}
        .keyboardShortcut(.defaultAction)
    } message: {
      Text(
        "This permanently deletes all History entries. "
          + "It does not delete Writing Styles, credentials, or your current work."
      )
    }
  }

  private var generalCategory: some View {
    Form {
        Section("Appearance") {
          Picker("Appearance", selection: appearanceBinding) {
            ForEach(AppearancePreference.allCases, id: \.self) { appearance in
              Text(appearance.displayName).tag(appearance)
            }
          }
          .pickerStyle(.segmented)
          .accessibilityIdentifier("settings-appearance")
        }

        Section("Shortcuts") {
          LabeledContent("Quick Check") {
            ShortcutRecorder(
              chord: viewModel.quickCheckKeyChord,
              accessibilityLabel: "Quick Check shortcut"
            ) {
              viewModel.updateKeyChord($0, for: .quickCheck)
            }
          }
          if let error = viewModel.shortcutError(for: .quickCheck) {
            Text(error)
              .font(.caption)
              .foregroundStyle(.red)
              .accessibilityIdentifier("settings-quick-check-shortcut-error")
          }

          LabeledContent("Fix & Send") {
            ShortcutRecorder(
              chord: viewModel.fixAndSendKeyChord,
              accessibilityLabel: "Fix & Send shortcut"
            ) {
              viewModel.updateKeyChord($0, for: .fixAndSend)
            }
          }
          if let error = viewModel.shortcutError(for: .fixAndSend) {
            Text(error)
              .font(.caption)
              .foregroundStyle(.red)
              .accessibilityIdentifier("settings-fix-and-send-shortcut-error")
          }
          Text("Changes take effect immediately. If macOS or another app rejects a shortcut, Bex keeps the previous working shortcut.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
    .formStyle(.grouped)
    .padding()
    .frame(maxWidth: .infinity)
  }

  private var providerCategory: some View {
    Form {
        Section("Provider Connection") {
          Picker("Provider", selection: providerBinding) {
            ForEach(LLMProvider.allCases, id: \.self) { provider in
              Text(provider.displayName).tag(provider)
            }
          }
          .accessibilityIdentifier("settings-provider")

          Label(
            viewModel.providerConnectionLabel,
            systemImage: {
              switch viewModel.providerConnectionState {
              case .notConfigured: "person.badge.key"
              case .validating: "arrow.trianglehead.2.clockwise.rotate.90"
              case .ready: "checkmark.circle.fill"
              case .failed: "exclamationmark.triangle.fill"
              }
            }()
          )
          .foregroundStyle(
            viewModel.providerConnectionState == .ready
              ? Color.green
              : viewModel.providerConnectionState == .failed ? Color.red : Color.secondary
          )
          .accessibilityIdentifier("settings-provider-connection")

          if viewModel.showsCredential {
            if viewModel.credentialStored {
              Label("Credential stored in Keychain", systemImage: "key.fill")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("settings-credential-stored")
            }
            SecureField(
              viewModel.credentialStored
                ? "Enter a replacement credential"
                : viewModel.credentialLabel,
              text: $viewModel.credentialInput
            )
            .accessibilityIdentifier("settings-credential-input")
            HStack {
              Button(viewModel.credentialStored ? "Replace Credential" : "Connect") {
                viewModel.saveCredential()
              }
              .accessibilityIdentifier("settings-save-credential")
              if viewModel.credentialStored {
                Button("Remove Credential", role: .destructive) {
                  viewModel.removeCredential()
                }
              }
            }
            Text("Credentials are stored only in the macOS Keychain.")
              .font(.caption)
              .foregroundStyle(.secondary)
          } else if viewModel.provider == .openAICodex {
            HStack {
              Label(
                viewModel.codexStatus,
                systemImage: viewModel.codexConnected
                  ? "checkmark.circle.fill"
                  : "person.badge.key"
              )
              if viewModel.oauthInProgress {
                ProgressView().controlSize(.small)
              }
              Spacer()
            }
            .accessibilityIdentifier("settings-codex-status")
            if let expiry = viewModel.codexExpiry {
              Text("Session expires \(expiry, style: .relative).")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            HStack {
              Button(viewModel.codexConnected ? "Reconnect" : "Connect") {
                viewModel.connectCodex()
              }
              .disabled(viewModel.oauthInProgress)
              .accessibilityIdentifier("settings-codex-connect")
              if viewModel.codexConnected {
                Button("Disconnect", role: .destructive) {
                  viewModel.disconnectCodex()
                }
                .accessibilityIdentifier("settings-codex-disconnect")
              }
            }
            if viewModel.manualCallbackRequired {
              TextField("Complete callback URL", text: $viewModel.callbackURL)
                .accessibilityIdentifier("settings-codex-callback")
              Button("Complete Login") {
                viewModel.completeManualCallback()
              }
              .disabled(viewModel.oauthInProgress)
              .accessibilityIdentifier("settings-codex-complete")
            }
            Text("Uses your ChatGPT Codex account. Tokens remain in Keychain.")
              .font(.caption)
              .foregroundStyle(.secondary)
          } else if viewModel.provider == .ollama {
            TextField("Ollama URL", text: ollamaBinding)
              .accessibilityIdentifier("settings-ollama-url")
            if let ollamaError = viewModel.ollamaError {
              Text(ollamaError)
                .font(.caption)
                .foregroundStyle(.red)
                .accessibilityIdentifier("settings-ollama-error")
            }
          }

          if let routeTitle = viewModel.setupRouteTitle {
            Button(routeTitle) {
              Task {
                await viewModel.requestSetupRoute()
              }
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isRequestingSetupRoute)
            .accessibilityIdentifier("settings-setup-route")
          }
        }

        Section("Model & Effort") {
          HStack {
            Picker("Model", selection: modelBinding) {
              ForEach(viewModel.models) { model in
                Text(model.name).tag(model.id)
              }
            }
            .accessibilityIdentifier("settings-model")
            if viewModel.isFetchingModels {
              ProgressView().controlSize(.small)
            }
          }
          Picker("Effort", selection: effortBinding) {
            ForEach(ReasoningEffort.allCases) { effort in
              Text(effort.displayName).tag(effort)
            }
          }
          .accessibilityIdentifier("settings-effort")
          Text("Model and effort tune provider behavior; they are not required to connect Bex.")
            .font(.caption)
            .foregroundStyle(.secondary)
          if let modelFetchError = viewModel.modelFetchError {
            HStack {
              Text(modelFetchError)
                .font(.caption)
                .foregroundStyle(.secondary)
              Spacer()
              Button("Retry") { viewModel.retryModels() }
            }
          }
        }
    }
    .formStyle(.grouped)
    .padding()
    .frame(maxWidth: .infinity)
  }

  private var fixAndSendCategory: some View {
    Form {
        Section("Delivery") {
          Picker("After Fix & Send approval", selection: promptDeliveryBinding) {
            ForEach(PromptDeliveryMode.allCases) { mode in
              Text(mode.displayName).tag(mode)
            }
          }
          .accessibilityIdentifier("settings-prompt-delivery")

          Picker("Before sending text", selection: outboundConfirmationBinding) {
            ForEach(OutboundConfirmationPolicy.allCases, id: \.self) { policy in
              Text(outboundConfirmationTitle(policy)).tag(policy)
            }
          }
          .accessibilityIdentifier("settings-outbound-confirmation")

          Text(viewModel.providerDisclosure)
            .font(.caption)
            .foregroundStyle(.secondary)
          Text("Bex always asks for confirmation for ambiguous captures and app-hook requests. Skipping confirmation applies only to unambiguous actions you invoke manually after the provider disclosure is accepted.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Section("Accessibility") {
          Label(
            viewModel.accessibilityTrusted
              ? "Accessibility access is enabled"
              : "Accessibility access is not enabled",
            systemImage: viewModel.accessibilityTrusted
              ? "checkmark.circle.fill"
              : "exclamationmark.triangle"
          )
          .accessibilityIdentifier("settings-accessibility-status")

          if viewModel.showsAccessibilityRequest {
            Button("Request Access") {
              viewModel.requestAccessibility()
            }
            .accessibilityIdentifier("settings-prompt-accessibility")
          }

          Text("macOS Accessibility is a broad system grant that can inspect and control other apps. Bex uses it only when you manually invoke Fix & Send to capture the focused editable field and deliver a correction you approve.")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text("Without Accessibility access, manual Fix & Send uses copy-only fallback: Bex copies the approved correction so you can paste it yourself. You can revoke the grant at any time in System Settings.")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text("Enabled app hooks can still supply prompts to Bex when Accessibility access is off; the macOS grant is not required for hook intake.")
            .font(.caption)
            .foregroundStyle(.secondary)

          if let status = viewModel.accessibilityStatusMessage {
            Text(status)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        DisclosureGroup("Advanced") {
          GroupBox("App Integrations") {
            VStack(alignment: .leading, spacing: 10) {
              ForEach(PromptClient.allCases) { client in
                VStack(alignment: .leading, spacing: 5) {
                  HStack {
                    VStack(alignment: .leading, spacing: 2) {
                      Text(client.displayName).font(.headline)
                      Text(viewModel.hookStatusLabel(for: client))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if viewModel.promptOperationClient == client {
                      ProgressView().controlSize(.small)
                    }
                    Button(viewModel.hookActionLabel(for: client)) {
                      viewModel.performHookAction(for: client)
                    }
                    .disabled(viewModel.promptOperationClient != nil)
                    .accessibilityIdentifier("settings-prompt-hook-\(client.rawValue)")
                  }
                  Text(viewModel.hookConfigPath(for: client))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                  if client == .codex {
                    Text("After installation, open /hooks in Codex and explicitly trust the Bex handler.")
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                }
              }
              Text("Hook hosts can fail open if they terminate the helper before its one-hour timeout. Bex returns a valid block for every recoverable helper error and marks an integration active only after a heartbeat.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          .padding(.top, 8)
        }
    }
    .formStyle(.grouped)
    .padding()
    .frame(maxWidth: .infinity)
  }

  private var privacyCategory: some View {
    Form {
        Section("Privacy & Local Data") {
          Picker("Quick Check drafts", selection: draftRetentionBinding) {
            ForEach(RetentionChoice.allCases, id: \.self) { choice in
              Text(retentionTitle(choice)).tag(choice)
            }
          }
          .accessibilityIdentifier("settings-draft-retention")
          Text(SettingsViewModel.draftRetentionDisclosure)
            .font(.caption)
            .foregroundStyle(.secondary)

          Button("Delete Saved Draft", role: .destructive) {
            confirmDeleteSavedDraft = true
          }
          .accessibilityIdentifier("settings-delete-saved-draft")
          .disabled(viewModel.isDeletingSavedDraft)

          if viewModel.isDeletingSavedDraft {
            HStack {
              ProgressView().controlSize(.small)
              Text("Deleting saved draft…")
            }
          }

          Divider()

          Picker("Correction history", selection: historyRetentionBinding) {
            ForEach(RetentionChoice.allCases, id: \.self) { choice in
              Text(retentionTitle(choice)).tag(choice)
            }
          }
          .accessibilityIdentifier("settings-history-retention")
          Text(SettingsViewModel.historyRetentionDisclosure)
            .font(.caption)
            .foregroundStyle(.secondary)

          Button("Clear History", role: .destructive) {
            confirmClearHistory = true
          }
          .accessibilityIdentifier("settings-clear-history")
          .disabled(viewModel.isClearingHistory)
        }
    }
    .formStyle(.grouped)
    .padding()
    .frame(maxWidth: .infinity)
  }

  @ViewBuilder
  private var rootErrors: some View {
    if viewModel.promptGateError != nil
      || viewModel.userVisibleError != nil
      || viewModel.savedDraftDeletionError != nil
    {
      VStack(alignment: .leading, spacing: 6) {
        if let error = viewModel.promptGateError {
          Text(error)
            .font(.caption)
            .foregroundStyle(.red)
            .textSelection(.enabled)
            .accessibilityIdentifier("settings-prompt-error")
        }
        if let error = viewModel.userVisibleError {
          Label(error, systemImage: "exclamationmark.circle")
            .foregroundStyle(.red)
            .textSelection(.enabled)
            .accessibilityIdentifier("settings-error")
        }
        if let error = viewModel.savedDraftDeletionError {
          Label(error, systemImage: "exclamationmark.circle")
            .foregroundStyle(.red)
            .textSelection(.enabled)
            .accessibilityIdentifier("settings-delete-saved-draft-error")
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding()
      .background(.bar)
    }
  }

  private var providerBinding: Binding<LLMProvider> {
    Binding(
      get: { viewModel.provider },
      set: { viewModel.selectProvider($0) }
    )
  }

  private var modelBinding: Binding<String> {
    Binding(
      get: { viewModel.model },
      set: { viewModel.selectModel($0) }
    )
  }

  private var effortBinding: Binding<ReasoningEffort> {
    Binding(
      get: { viewModel.effort },
      set: { viewModel.selectEffort($0) }
    )
  }

  private var ollamaBinding: Binding<String> {
    Binding(
      get: { viewModel.ollamaURL },
      set: { viewModel.updateOllamaURL($0) }
    )
  }

  private var promptDeliveryBinding: Binding<PromptDeliveryMode> {
    Binding(
      get: { viewModel.promptDeliveryMode },
      set: { viewModel.selectPromptDeliveryMode($0) }
    )
  }

  private var draftRetentionBinding: Binding<RetentionChoice> {
    Binding(
      get: { viewModel.draftRetentionChoice },
      set: { viewModel.selectDraftRetentionChoice($0) }
    )
  }

  private var historyRetentionBinding: Binding<RetentionChoice> {
    Binding(
      get: { viewModel.historyRetentionChoice },
      set: { viewModel.selectHistoryRetentionChoice($0) }
    )
  }

  private var outboundConfirmationBinding: Binding<OutboundConfirmationPolicy> {
    Binding(
      get: { viewModel.outboundConfirmationPolicy },
      set: { viewModel.selectOutboundConfirmationPolicy($0) }
    )
  }

  private func retentionTitle(_ choice: RetentionChoice) -> String {
    switch choice {
    case .undecided: "Not Decided"
    case .enabled: "Save"
    case .disabled: "Don’t Save"
    }
  }

  private func outboundConfirmationTitle(_ policy: OutboundConfirmationPolicy) -> String {
    switch policy {
    case .alwaysConfirm: "Always Confirm"
    case .skipUnambiguousManual: "Skip for Unambiguous Manual Actions"
    }
  }

  private var appearanceBinding: Binding<AppearancePreference> {
    Binding(
      get: { viewModel.appearance },
      set: { viewModel.selectAppearance($0) }
    )
  }
}

private struct ShortcutRecorder: NSViewRepresentable {
  let chord: KeyChord
  let accessibilityLabel: String
  let onChange: (KeyChord) -> ShortcutUpdateOutcome

  func makeNSView(context: Context) -> ShortcutRecorderButton {
    ShortcutRecorderButton(
      chord: chord,
      accessibilityLabel: accessibilityLabel,
      onChange: onChange
    )
  }

  func updateNSView(_ button: ShortcutRecorderButton, context: Context) {
    button.update(chord: chord, onChange: onChange)
  }
}

private final class ShortcutRecorderButton: NSButton {
  private static let recordingInstructions =
    "Click, then type a shortcut that includes Command, Option, or Control. Press Escape to cancel."

  private var chord: KeyChord
  private var recordsNextKey = false
  private var changeHandler: (KeyChord) -> ShortcutUpdateOutcome
  private var pendingAnnouncements: [String] = []
  private var isPostingAnnouncement = false

  init(
    chord: KeyChord,
    accessibilityLabel: String,
    onChange: @escaping (KeyChord) -> ShortcutUpdateOutcome
  ) {
    self.chord = chord
    changeHandler = onChange
    super.init(frame: .zero)
    title = chord.displayString
    bezelStyle = .rounded
    font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    target = self
    action = #selector(beginRecording)
    setAccessibilityLabel(accessibilityLabel)
    setAccessibilityValue(chord.displayString)
    setAccessibilityHelp(Self.recordingInstructions)
    toolTip = Self.recordingInstructions
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var acceptsFirstResponder: Bool { true }

  func update(
    chord: KeyChord,
    onChange: @escaping (KeyChord) -> ShortcutUpdateOutcome
  ) {
    self.chord = chord
    changeHandler = onChange
    setAccessibilityValue(chord.displayString)
    if !recordsNextKey {
      title = chord.displayString
    }
  }

  @objc private func beginRecording() {
    recordsNextKey = true
    title = "Type shortcut…"
    window?.makeFirstResponder(self)
    announce(
      "Shortcut recording started. \(Self.recordingInstructions)"
    )
  }

  override func resignFirstResponder() -> Bool {
    if recordsNextKey {
      cancelRecording()
    }
    return super.resignFirstResponder()
  }

  override func keyDown(with event: NSEvent) {
    guard recordsNextKey else {
      super.keyDown(with: event)
      return
    }
    if Int(event.keyCode) == kVK_Escape {
      cancelRecording()
      window?.makeFirstResponder(self)
      return
    }

    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    var modifiers: UInt32 = 0
    if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
    if flags.contains(.option) { modifiers |= UInt32(optionKey) }
    if flags.contains(.control) { modifiers |= UInt32(controlKey) }
    if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
    let updatedChord = KeyChord(keyCode: UInt32(event.keyCode), modifiers: modifiers)

    switch changeHandler(updatedChord) {
    case .accepted:
      chord = updatedChord
      recordsNextKey = false
      title = updatedChord.displayString
      setAccessibilityValue(updatedChord.displayString)
      announce("Shortcut accepted: \(updatedChord.displayString).")
    case .rejected:
      title = "Type shortcut…"
      announce(
        "Shortcut rejected. Current shortcut remains \(chord.displayString)."
      )
    }
    window?.makeFirstResponder(self)
  }

  private func cancelRecording() {
    recordsNextKey = false
    title = chord.displayString
    setAccessibilityValue(chord.displayString)
    announce("Shortcut recording canceled. Current shortcut is \(chord.displayString).")
  }

  private func announce(_ message: String) {
    pendingAnnouncements.append(message)
    postNextAnnouncement()
  }

  private func postNextAnnouncement() {
    guard !isPostingAnnouncement, !pendingAnnouncements.isEmpty else { return }
    isPostingAnnouncement = true
    let message = pendingAnnouncements.removeFirst()
    NSAccessibility.post(
      element: self,
      notification: .announcementRequested,
      userInfo: [
        .announcement: message,
        .priority: NSAccessibilityPriorityLevel.high.rawValue,
      ]
    )
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      isPostingAnnouncement = false
      postNextAnnouncement()
    }
  }
}
