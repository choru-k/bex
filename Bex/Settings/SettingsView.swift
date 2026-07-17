import SwiftUI

struct SettingsView: View {
  @ObservedObject var viewModel: SettingsViewModel

  var body: some View {
    Form {
      Section("Provider") {
        Picker("Provider", selection: providerBinding) {
          ForEach(LLMProvider.allCases, id: \.self) { provider in
            Text(provider.displayName).tag(provider)
          }
        }
        .accessibilityIdentifier("settings-provider")

        HStack {
          Picker("Model", selection: modelBinding) {
            ForEach(viewModel.models) { model in
              Text(model.name).tag(model.id)
            }
          }
          .accessibilityIdentifier("settings-model")
          if viewModel.isFetchingModels {
            ProgressView()
              .controlSize(.small)
          }
        }

        Picker("Effort", selection: effortBinding) {
          ForEach(ReasoningEffort.allCases) { effort in
            Text(effort.displayName).tag(effort)
          }
        }
        .accessibilityIdentifier("settings-effort")

        Text("Controls provider reasoning or thinking depth. Ollama applies it only to thinking models.")
          .font(.caption)
          .foregroundStyle(.secondary)

        if let modelFetchError = viewModel.modelFetchError {
          HStack {
            Text(modelFetchError)
              .font(.caption)
              .foregroundStyle(.secondary)
            Spacer()
            Button("Retry") {
              viewModel.retryModels()
            }
          }
        }
      }

      if viewModel.showsCredential {
        Section("Credential") {
          if viewModel.credentialStored {
            Label("Stored in Keychain", systemImage: "key.fill")
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
            Button("Save Credential") {
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
        }
      }

      if viewModel.provider == .openAICodex {
        Section("OpenAI Codex") {
          HStack {
            Label(
              viewModel.codexStatus,
              systemImage: viewModel.codexConnected
                ? "checkmark.circle.fill"
                : "person.badge.key"
            )
            if viewModel.oauthInProgress {
              ProgressView()
                .controlSize(.small)
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

          Text("Uses your ChatGPT Codex subscription. Tokens remain in Keychain.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      if viewModel.provider == .ollama {
        Section("Ollama") {
          TextField("Ollama URL", text: ollamaBinding)
            .accessibilityIdentifier("settings-ollama-url")
          if let ollamaError = viewModel.ollamaError {
            Text(ollamaError)
              .font(.caption)
              .foregroundStyle(.red)
              .accessibilityIdentifier("settings-ollama-error")
          }
          Text("Requests are processed locally by your Ollama server.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Section("Appearance") {
        Picker("Appearance", selection: appearanceBinding) {
          ForEach(AppearancePreference.allCases, id: \.self) { appearance in
            Text(appearance.displayName).tag(appearance)
          }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("settings-appearance")
      }

      if let error = viewModel.userVisibleError {
        Section {
          Label(error, systemImage: "exclamationmark.circle")
            .foregroundStyle(.red)
            .textSelection(.enabled)
            .accessibilityIdentifier("settings-error")
        }
      }
    }
    .formStyle(.grouped)
    .padding()
    .task {
      await viewModel.load()
    }
    .onDisappear {
      viewModel.close()
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

  private var appearanceBinding: Binding<AppearancePreference> {
    Binding(
      get: { viewModel.appearance },
      set: { viewModel.selectAppearance($0) }
    )
  }
}
