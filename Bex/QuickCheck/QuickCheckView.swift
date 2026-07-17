import SwiftUI

struct QuickCheckView: View {
  @ObservedObject var viewModel: QuickCheckViewModel
  let openSettings: () -> Void
  let openProfiles: () -> Void
  let openHistory: () -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        contextRow
        inputSection
        setupSection
        actionRow
        disclosureSection
        errorSection
        resultSection
        managementRow
      }
      .padding(16)
    }
    .frame(minWidth: 460, minHeight: 360)
    .onExitCommand {
      viewModel.close()
    }
  }

  private var contextRow: some View {
    HStack(spacing: 5) {
      Button(viewModel.providerLabel, action: openSettings)
        .buttonStyle(.link)
        .accessibilityIdentifier("quick-check-provider")
      Text("·").foregroundStyle(.secondary)
      Button(viewModel.modelLabel, action: openSettings)
        .buttonStyle(.link)
        .lineLimit(1)
        .accessibilityIdentifier("quick-check-model")
      Text("·").foregroundStyle(.secondary)
      Menu {
        Button {
          Task { await viewModel.selectProfile(id: nil) }
        } label: {
          profileMenuLabel("No Profile", selected: viewModel.selectedProfileID == nil)
        }
        if !viewModel.availableProfiles.isEmpty {
          Divider()
          ForEach(viewModel.availableProfiles) { profile in
            Button {
              Task { await viewModel.selectProfile(id: profile.id) }
            } label: {
              profileMenuLabel(
                profile.name,
                selected: viewModel.selectedProfileID == profile.id
              )
            }
          }
        }
        Divider()
        Button("Manage Profiles…", action: openProfiles)
      } label: {
        Label(viewModel.profileLabel, systemImage: "person.crop.circle")
          .lineLimit(1)
      }
      .menuStyle(.borderlessButton)
      .accessibilityIdentifier("quick-check-profile")
      Spacer(minLength: 0)
    }
    .font(.caption)
  }

  private var inputSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Text to check")
        .font(.headline)
      ZStack(alignment: .topLeading) {
        TextEditor(text: $viewModel.input)
          .font(.body)
          .scrollContentBackground(.hidden)
          .padding(5)
          .accessibilityIdentifier("quick-check-input")
        if viewModel.input.isEmpty {
          Text("Paste or type English text…")
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
            .allowsHitTesting(false)
        }
      }
      .frame(minHeight: 120, maxHeight: 170)
      .background(Color(nsColor: .textBackgroundColor))
      .clipShape(RoundedRectangle(cornerRadius: 7))
      .overlay {
        RoundedRectangle(cornerRadius: 7)
          .stroke(Color(nsColor: .separatorColor))
      }
    }
  }

  @ViewBuilder
  private var setupSection: some View {
    if let setupError = viewModel.setupError {
      GroupBox {
        HStack(alignment: .top, spacing: 10) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
          VStack(alignment: .leading, spacing: 5) {
            Text("Setup required")
              .font(.headline)
            Text(setupError)
              .font(.caption)
              .foregroundStyle(.secondary)
            Button("Open Settings", action: openSettings)
              .accessibilityIdentifier("quick-check-open-settings")
          }
          Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private var actionRow: some View {
    HStack {
      Button {
        viewModel.check()
      } label: {
        if viewModel.isChecking {
          ProgressView()
            .controlSize(.small)
        } else {
          Label("Check", systemImage: "checkmark.circle")
        }
      }
      .keyboardShortcut(.return, modifiers: .command)
      .disabled(!viewModel.canCheck)
      .accessibilityIdentifier("quick-check-check")

      if viewModel.isChecking {
        Text("Checking…")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else if let intent = viewModel.rewritingIntent {
        Text("Applying \(intent.label)…")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
    }
  }

  private var disclosureSection: some View {
    VStack(alignment: .leading, spacing: 3) {
      Label(
        "AI-generated edits may contain mistakes. Review before sending.",
        systemImage: "exclamationmark.shield"
      )
      Text(viewModel.processingDisclosure)
        .padding(.leading, 20)
    }
    .font(.caption2)
    .foregroundStyle(.secondary)
  }

  @ViewBuilder
  private var errorSection: some View {
    if let error = viewModel.userVisibleError {
      Label(error, systemImage: "exclamationmark.circle")
        .font(.caption)
        .foregroundStyle(.red)
        .textSelection(.enabled)
        .accessibilityIdentifier("quick-check-error")
    }
  }

  @ViewBuilder
  private var resultSection: some View {
    if let result = viewModel.result {
      Divider()
      if result.corrected == viewModel.input {
        VStack(alignment: .leading, spacing: 5) {
          Label("Your text looks good!", systemImage: "checkmark.seal.fill")
            .font(.headline)
            .foregroundStyle(.green)
          Text("No grammar or expression changes needed.")
            .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("quick-check-unchanged")
      } else {
        diffSection
      }

      VStack(alignment: .leading, spacing: 5) {
        Text("Corrected")
          .font(.headline)
        Text(result.corrected)
          .frame(maxWidth: .infinity, alignment: .leading)
          .textSelection(.enabled)
          .accessibilityIdentifier("quick-check-corrected")
          .accessibilityLabel("Corrected text")
          .accessibilityValue(result.corrected)
      }

      VStack(alignment: .leading, spacing: 5) {
        Text("Explanation")
          .font(.headline)
        Text(result.explanation)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .accessibilityIdentifier("quick-check-explanation")
          .accessibilityLabel("Explanation")
          .accessibilityValue(result.explanation)
      }

      rewriteRow
      resultActionRow
    }
  }

  private var diffSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("Changes")
          .font(.headline)
        Spacer()
        Button(viewModel.changesOnly ? "Show full text" : "Show only changes") {
          viewModel.changesOnly.toggle()
        }
        .buttonStyle(.link)
      }
      DiffText(segments: viewModel.diff, changesOnly: viewModel.changesOnly)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .accessibilityIdentifier("quick-check-diff")
        .accessibilityLabel("Changes")
        .accessibilityValue(diffAccessibilityLabel)
    }
  }

  private var diffAccessibilityLabel: String {
    viewModel.diff.compactMap { segment in
      switch segment.kind {
      case .inserted:
        "Inserted: \(segment.text)"
      case .removed:
        "Removed: \(segment.text)"
      case .unchanged:
        nil
      }
    }
    .joined(separator: ", ")
  }

  private var rewriteRow: some View {
    HStack {
      ForEach(RewriteIntent.allCases, id: \.self) { intent in
        Button(intent.label) {
          viewModel.rewrite(intent)
        }
        .keyboardShortcut(rewriteShortcut(for: intent), modifiers: .command)
        .disabled(viewModel.isBusy)
        .accessibilityIdentifier("quick-check-rewrite-\(intent.rawValue)")
      }
      Spacer()
    }
  }

  private var resultActionRow: some View {
    HStack {
      Button("Use as Input") {
        viewModel.useResultAsInput()
      }
      Button("Recheck") {
        viewModel.recheck()
      }
      .keyboardShortcut("r", modifiers: .command)
      Spacer()
      if viewModel.copied {
        Text("Copied")
          .font(.caption)
          .foregroundStyle(.green)
          .accessibilityIdentifier("quick-check-copied")
      }
      Button("Copy") {
        viewModel.copy(closeAfter: false)
      }
      .keyboardShortcut("c", modifiers: [.command, .shift])
      .accessibilityIdentifier("quick-check-copy")
      Button("Copy and Close") {
        viewModel.copy(closeAfter: true)
      }
      .keyboardShortcut(.return, modifiers: [.command, .shift])
      .accessibilityIdentifier("quick-check-copy-close")
    }
  }

  private var managementRow: some View {
    HStack(spacing: 12) {
      Button("History", action: openHistory)
        .accessibilityIdentifier("quick-check-history")
      Button("Profiles", action: openProfiles)
        .accessibilityIdentifier("quick-check-profiles")
      Button("Settings", action: openSettings)
        .accessibilityIdentifier("quick-check-settings")
      Spacer()
    }
    .buttonStyle(.link)
    .font(.caption)
  }

  private func rewriteShortcut(for intent: RewriteIntent) -> KeyEquivalent {
    switch intent {
    case .formal: "1"
    case .friendly: "2"
    case .shorter: "3"
    }
  }

  private func profileMenuLabel(_ title: String, selected: Bool) -> some View {
    HStack {
      Text(title)
      if selected {
        Image(systemName: "checkmark")
      }
    }
  }
}

struct DiffText: View {
  let segments: [DiffSegment]
  let changesOnly: Bool

  var body: some View {
    if visibleSegments.isEmpty {
      Text("No differences")
        .foregroundStyle(.secondary)
    } else {
      Text(attributedText)
    }
  }

  private var visibleSegments: [DiffSegment] {
    changesOnly ? segments.filter { $0.kind != .unchanged } : segments
  }

  private var attributedText: AttributedString {
    var result = AttributedString()
    for segment in visibleSegments {
      var part = AttributedString(segment.text)
      switch segment.kind {
      case .unchanged:
        break
      case .inserted:
        part.foregroundColor = .green
        part.backgroundColor = Color.green.opacity(0.14)
        part.inlinePresentationIntent = .stronglyEmphasized
      case .removed:
        part.foregroundColor = .red
        part.backgroundColor = Color.red.opacity(0.12)
        part.strikethroughStyle = .single
      }
      result.append(part)
    }
    return result
  }
}
