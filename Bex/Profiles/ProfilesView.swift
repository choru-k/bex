import SwiftUI

struct ProfilesView: View {
  @ObservedObject var viewModel: ProfilesViewModel
  @State private var pendingDelete: Profile?

  var body: some View {
    VStack(spacing: 0) {
      content

      if !viewModel.showWizard, let error = viewModel.userVisibleError {
        Divider()
        Label(error, systemImage: "exclamationmark.circle")
          .font(.caption)
          .foregroundStyle(.red)
          .textSelection(.enabled)
          .padding(10)
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityLabel("Writing Style error")
          .accessibilityValue(error)
          .accessibilityIdentifier("writing-styles-error")
      }
    }
    .toolbar {
      ToolbarItem {
        Button {
          viewModel.createProfile()
        } label: {
          Label(WritingStyleCopy.newAction, systemImage: "plus")
        }
        .accessibilityIdentifier("writing-styles-new")
      }
    }
    .task {
      await viewModel.load()
    }
    .onDisappear {
      viewModel.close()
    }
    .sheet(isPresented: $viewModel.showWizard) {
      wizard
    }
    .alert(
      "Discard unsaved changes?",
      isPresented: Binding(
        get: { viewModel.showsDiscardChangesConfirmation },
        set: { if !$0 { viewModel.keepEditing() } }
      )
    ) {
      Button("Keep Editing", role: .cancel) {
        viewModel.keepEditing()
      }
      Button("Discard Changes", role: .destructive) {
        viewModel.discardChangesAndSelectPending()
      }
    } message: {
      Text("Your unsaved Writing Style edits will be lost.")
    }
    .alert(
      "Delete Writing Style?",
      isPresented: Binding(
        get: { pendingDelete != nil },
        set: { if !$0 { pendingDelete = nil } }
      ),
      presenting: pendingDelete
    ) { profile in
      Button("Delete", role: .destructive) {
        viewModel.delete(id: profile.id)
        pendingDelete = nil
      }
      Button("Cancel", role: .cancel) {
        pendingDelete = nil
      }
    } message: { profile in
      Text("Delete “\(profile.name)”? This cannot be undone.")
    }
  }

  @ViewBuilder
  private var content: some View {
    switch viewModel.contentState {
    case .loading:
      ProgressView("Loading Writing Styles…")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("writing-styles-loading")
    case .empty:
      emptyState
    case .bexStandard, .editing:
      HSplitView {
        sidebar
          .frame(minWidth: 210)
        editor
          .frame(minWidth: 360)
      }
    }
  }

  private var emptyState: some View {
    VStack(spacing: 12) {
      Image(systemName: "textformat")
        .font(.largeTitle)
        .foregroundStyle(.secondary)
      Text(WritingStyleCopy.emptyTitle)
        .font(.title2.bold())
      Text(WritingStyleCopy.emptyMessage)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 420)
      Button(WritingStyleCopy.newAction) {
        viewModel.createProfile()
      }
      .accessibilityIdentifier("writing-styles-empty-new")
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var sidebar: some View {
    List(selection: sidebarSelection) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text(WritingStyleCopy.defaultName)
          Text("Bex’s built-in grammar guidance")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if viewModel.defaultProfileID == nil {
          Image(systemName: "star.fill")
            .foregroundStyle(.yellow)
            .accessibilityLabel("Default Writing Style")
            .help("Default Writing Style")
        }
      }
      .tag(WritingStyleSidebarSelection.bexStandard)
      .accessibilityIdentifier("writing-style-bex-standard")

      ForEach(viewModel.profiles) { profile in
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text(profile.name)
            Text(profile.prompt)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          Spacer()
          if viewModel.defaultProfileID == profile.id {
            Image(systemName: "star.fill")
              .foregroundStyle(.yellow)
              .accessibilityLabel("Default Writing Style")
              .help("Default Writing Style")
          }
        }
        .tag(WritingStyleSidebarSelection.profile(profile.id))
        .accessibilityIdentifier("writing-style-row-\(profile.id.uuidString)")
      }
    }
    .listStyle(.sidebar)
  }

  private var sidebarSelection: Binding<WritingStyleSidebarSelection?> {
    Binding(
      get: { viewModel.sidebarSelection },
      set: { viewModel.selectSidebar($0) }
    )
  }

  @ViewBuilder
  private var editor: some View {
    if viewModel.hasEditor {
      Form {
        Section("Writing Style") {
          TextField("Name", text: $viewModel.name)
            .accessibilityLabel("Writing Style name")
            .accessibilityIdentifier("writing-style-name")
          VStack(alignment: .leading, spacing: 5) {
            Text("Grammar guidance")
              .font(.caption)
              .foregroundStyle(.secondary)
            TextEditor(text: $viewModel.prompt)
              .frame(minHeight: 150)
              .accessibilityLabel("Writing Style grammar guidance")
              .accessibilityIdentifier("writing-style-prompt")
          }
          Toggle("Use as default Writing Style", isOn: $viewModel.isDefault)
            .accessibilityIdentifier("writing-style-default")
        }

        Section {
          HStack {
            Button("Generate with AI…") {
              viewModel.openWizard()
            }
            .accessibilityIdentifier("writing-style-wizard-open")
            Spacer()
            if let editingID = viewModel.editingID,
              let profile = viewModel.profiles.first(where: { $0.id == editingID })
            {
              Button("Delete", role: .destructive) {
                pendingDelete = profile
              }
            }
            Button("Save Writing Style") {
              viewModel.save()
            }
            .keyboardShortcut("s", modifiers: .command)
            .accessibilityIdentifier("writing-style-save")
          }
        }
      }
      .formStyle(.grouped)
      .padding()
    } else {
      VStack(spacing: 10) {
        Image(systemName: "textformat")
          .font(.largeTitle)
          .foregroundStyle(.secondary)
        Text(WritingStyleCopy.defaultName)
          .font(.title2.bold())
        Text(
          "Bex Standard uses Bex’s built-in grammar guidance. "
            + "Create a Writing Style when you want guidance tailored to your tone or audience."
        )
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 420)
        Button(WritingStyleCopy.newAction) {
          viewModel.createProfile()
        }
      }
      .padding(24)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("writing-style-bex-standard-detail")
    }
  }

  private var wizard: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Text("Writing Style AI Wizard")
          .font(.title2.bold())
          .accessibilityAddTraits(.isHeader)
        Text("Add context to guide Bex’s grammar and expression choices.")
          .foregroundStyle(.secondary)

        if let summary = viewModel.outboundSummary {
          outboundConfirmation(summary)
        } else {
          wizardField("Role", text: $viewModel.wizardContext.role, identifier: "wizard-role")
          wizardField(
            "Audience",
            text: $viewModel.wizardContext.audience,
            identifier: "wizard-audience"
          )
          wizardField("Tone", text: $viewModel.wizardContext.tone, identifier: "wizard-tone")
          wizardField(
            "Formality",
            text: $viewModel.wizardContext.formality,
            identifier: "wizard-formality"
          )
          wizardField(
            "Domain",
            text: $viewModel.wizardContext.domain,
            identifier: "wizard-domain"
          )
          wizardField(
            "Additional Notes",
            text: $viewModel.wizardContext.notes,
            identifier: "wizard-notes"
          )

          wizardStatus

          HStack {
            Button("Cancel") {
              viewModel.cancelWizard()
            }
            .keyboardShortcut(.cancelAction)
            Spacer()
            Button("Generate Guidance") {
              viewModel.generatePrompt()
            }
            .disabled(viewModel.isGenerating)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("wizard-generate")
          }
        }
      }
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(
      minWidth: 360,
      idealWidth: 500,
      minHeight: 360,
      idealHeight: 560
    )
  }

  private func wizardField(
    _ label: String,
    text: Binding<String>,
    identifier: String
  ) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(label)
        .font(.headline)
      TextField(label, text: text)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
  }

  private func outboundConfirmation(_ summary: WritingStyleOutboundSummary) -> some View {
    GroupBox("Confirm what will be sent") {
      VStack(alignment: .leading, spacing: 10) {
        confirmationRow(label: "Provider", value: summary.provider)
        confirmationRow(label: "Model", value: summary.model)
        VStack(alignment: .leading, spacing: 4) {
          Text("Labeled context")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(summary.payload)
            .font(.body.monospaced())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("writing-style-wizard-outbound-payload")
        }
        Text(summary.disclosure)
          .font(.caption)
          .foregroundStyle(.secondary)
        HStack {
          Button("Cancel") {
            viewModel.cancelOutbound()
          }
          .keyboardShortcut(.cancelAction)
          Spacer()
          Button("Generate with \(summary.provider)") {
            viewModel.confirmOutbound()
          }
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("writing-style-wizard-confirm")
        }
      }
      .padding(.vertical, 4)
    }
    .accessibilityLabel("Outbound request confirmation")
    .accessibilityIdentifier("writing-style-wizard-outbound-summary")
  }

  private func confirmationRow(label: String, value: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(label)
        .foregroundStyle(.secondary)
      Spacer()
      Text(value)
        .textSelection(.enabled)
    }
  }

  @ViewBuilder
  private var wizardStatus: some View {
    switch viewModel.wizardStatus {
    case .idle:
      EmptyView()
    case let .generating(message):
      ProgressView(message)
        .accessibilityLabel(message)
        .accessibilityIdentifier("writing-style-wizard-status")
    case let .error(message):
      Label(message, systemImage: "exclamationmark.circle")
        .font(.caption)
        .foregroundStyle(.red)
        .textSelection(.enabled)
        .accessibilityLabel("Writing Style generation error")
        .accessibilityValue(message)
        .accessibilityIdentifier("writing-style-wizard-error")
    }
  }
}
