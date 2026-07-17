import SwiftUI

struct ProfilesView: View {
  @ObservedObject var viewModel: ProfilesViewModel
  @State private var pendingDelete: Profile?

  var body: some View {
    HSplitView {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text("Profiles")
            .font(.title2.bold())
          Spacer()
          Button {
            viewModel.createProfile()
          } label: {
            Label("New", systemImage: "plus")
          }
          .accessibilityIdentifier("profiles-new")
        }
        .padding([.top, .horizontal])

        List(viewModel.profiles) { profile in
          Button {
            viewModel.edit(profile)
          } label: {
            HStack {
              VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                  .fontWeight(viewModel.editingID == profile.id ? .semibold : .regular)
                Text(profile.prompt)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
              }
              Spacer()
              if viewModel.defaultProfileID == profile.id {
                Image(systemName: "star.fill")
                  .foregroundStyle(.yellow)
                  .help("Default profile")
              }
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("profile-row-\(profile.id.uuidString)")
        }
        .overlay {
          if viewModel.profiles.isEmpty {
            Text("No profiles yet")
              .foregroundStyle(.secondary)
          }
        }
      }
      .frame(minWidth: 210)

      editor
        .frame(minWidth: 360)
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
      "Delete profile?",
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
  private var editor: some View {
    if viewModel.hasEditor {
      Form {
        Section("Profile") {
          TextField("Name", text: $viewModel.name)
            .accessibilityIdentifier("profile-name")
          VStack(alignment: .leading, spacing: 5) {
            Text("Grammar guidance")
              .font(.caption)
              .foregroundStyle(.secondary)
            TextEditor(text: $viewModel.prompt)
              .frame(minHeight: 150)
              .accessibilityIdentifier("profile-prompt")
          }
          Toggle("Use as default profile", isOn: $viewModel.isDefault)
            .accessibilityIdentifier("profile-default")
        }

        Section {
          HStack {
            Button("Generate with AI…") {
              viewModel.openWizard()
            }
            .accessibilityIdentifier("profile-wizard-open")
            Spacer()
            if let editingID = viewModel.editingID,
              let profile = viewModel.profiles.first(where: { $0.id == editingID })
            {
              Button("Delete", role: .destructive) {
                pendingDelete = profile
              }
            }
            Button("Save Profile") {
              viewModel.save()
            }
            .keyboardShortcut("s", modifiers: .command)
            .accessibilityIdentifier("profile-save")
          }
        }

        if let error = viewModel.userVisibleError {
          Section {
            Label(error, systemImage: "exclamationmark.circle")
              .foregroundStyle(.red)
              .textSelection(.enabled)
              .accessibilityIdentifier("profiles-error")
          }
        }
      }
      .formStyle(.grouped)
      .padding()
    } else {
      VStack(spacing: 10) {
        Image(systemName: "person.crop.rectangle.stack")
          .font(.largeTitle)
          .foregroundStyle(.secondary)
        Text("Select a profile or create a new one.")
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private var wizard: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Profile AI Wizard")
        .font(.title2.bold())
      Text("Add any context that should guide grammar and expression choices.")
        .foregroundStyle(.secondary)

      Form {
        TextField("Role", text: $viewModel.wizardContext.role)
          .accessibilityIdentifier("wizard-role")
        TextField("Audience", text: $viewModel.wizardContext.audience)
          .accessibilityIdentifier("wizard-audience")
        TextField("Tone", text: $viewModel.wizardContext.tone)
          .accessibilityIdentifier("wizard-tone")
        TextField("Formality", text: $viewModel.wizardContext.formality)
          .accessibilityIdentifier("wizard-formality")
        TextField("Domain", text: $viewModel.wizardContext.domain)
          .accessibilityIdentifier("wizard-domain")
        TextField("Additional notes", text: $viewModel.wizardContext.notes)
          .accessibilityIdentifier("wizard-notes")
      }

      if let error = viewModel.userVisibleError {
        Label(error, systemImage: "exclamationmark.circle")
          .font(.caption)
          .foregroundStyle(.red)
      }

      HStack {
        Button("Cancel") {
          viewModel.cancelWizard()
        }
        Spacer()
        Button {
          viewModel.generatePrompt()
        } label: {
          if viewModel.isGenerating {
            ProgressView()
              .controlSize(.small)
          } else {
            Text("Generate Prompt")
          }
        }
        .disabled(viewModel.isGenerating)
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("wizard-generate")
      }
    }
    .padding(20)
    .frame(width: 470, height: 470)
  }
}
