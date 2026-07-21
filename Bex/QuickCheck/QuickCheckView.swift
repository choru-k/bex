import AppKit
import SwiftUI

enum QuickCheckLayout {
  static func editorHeight(for availableHeight: CGFloat) -> CGFloat {
    min(280, max(120, availableHeight * 0.3))
  }
}

struct QuickCheckView: View {
  @ObservedObject var viewModel: QuickCheckViewModel
  let openSettings: () -> Void
  let openWritingStyles: () -> Void
  let openHistory: () -> Void

  @FocusState private var isEditorFocused: Bool

  var body: some View {
    GeometryReader { geometry in
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          contextRow
          inputSection(height: QuickCheckLayout.editorHeight(for: geometry.size.height))
          retentionSection
          setupSection
          actionRow
          outboundConfirmationSection
          disclosureSection
          errorSection
          resultSection
          managementRow
        }
        .padding(16)
        .frame(minHeight: geometry.size.height, alignment: .top)
      }
    }
    .frame(minWidth: 460, minHeight: 360)
    .onAppear {
      viewModel.sessionDidShow()
      isEditorFocused = true
    }
    .onChange(of: viewModel.editorFocusRequest) { _ in
      isEditorFocused = true
    }
    .onChange(of: viewModel.accessibilityAnnouncement) { announcement in
      guard let announcement else { return }
      NSAccessibility.post(
        element: NSApp as Any,
        notification: .announcementRequested,
        userInfo: [
          .announcement: announcement.message,
          .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ]
      )
    }
    .onExitCommand {
      viewModel.dismiss(.explicitCancel)
    }
  }

  private var contextRow: some View {
    HStack(spacing: 5) {
      Button(viewModel.providerLabel) {
        navigate(openSettings)
      }
      .buttonStyle(.link)
      .accessibilityIdentifier("quick-check-provider")
      Text("·").foregroundStyle(.secondary)
      Button(viewModel.modelLabel) {
        navigate(openSettings)
      }
      .buttonStyle(.link)
      .lineLimit(1)
      .accessibilityIdentifier("quick-check-model")
      Text("·").foregroundStyle(.secondary)
      Menu {
        Button {
          Task { await viewModel.selectWritingStyle(id: nil) }
        } label: {
          writingStyleMenuLabel(
            "Bex Standard",
            selected: viewModel.selectedWritingStyleID == nil
          )
        }
        if !viewModel.availableWritingStyles.isEmpty {
          Divider()
          ForEach(viewModel.availableWritingStyles) { style in
            Button {
              Task { await viewModel.selectWritingStyle(id: style.id) }
            } label: {
              writingStyleMenuLabel(
                style.name,
                selected: viewModel.selectedWritingStyleID == style.id
              )
            }
          }
        }
        Divider()
        Button("Manage Writing Styles…") {
          navigate(openWritingStyles)
        }
      } label: {
        Label(viewModel.writingStyleLabel, systemImage: "text.badge.checkmark")
          .lineLimit(1)
      }
      .menuStyle(.borderlessButton)
      .accessibilityLabel("Writing Style: \(viewModel.writingStyleLabel)")
      .accessibilityIdentifier("quick-check-writing-style")
      Spacer(minLength: 0)
    }
    .font(.caption)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Correction context")
  }

  private func inputSection(height: CGFloat) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Draft")
        .font(.headline)
        .accessibilityAddTraits(.isHeader)
      ZStack(alignment: .topLeading) {
        TextEditor(text: $viewModel.input)
          .focused($isEditorFocused)
          .font(.body)
          .scrollContentBackground(.hidden)
          .padding(5)
          .accessibilityLabel("Draft editor")
          .accessibilityHint("Plain Return inserts a new line. Command Return performs the primary action.")
          .accessibilityIdentifier("quick-check-input")
        if viewModel.input.isEmpty {
          Text("Paste or type English text…")
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
      }
      .frame(minHeight: height)
      .background(Color(nsColor: .textBackgroundColor))
      .clipShape(RoundedRectangle(cornerRadius: 7))
      .overlay {
        RoundedRectangle(cornerRadius: 7)
          .stroke(Color(nsColor: .separatorColor))
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Draft editor section")
  }

  @ViewBuilder
  private var retentionSection: some View {
    if viewModel.draftRetentionChoice == .undecided
      || viewModel.historyRetentionChoice == .undecided
    {
      GroupBox("Local storage choices") {
        VStack(alignment: .leading, spacing: 12) {
          if viewModel.draftRetentionChoice == .undecided {
            retentionChoiceRow(
              title: "Save unfinished drafts?",
              disclosure: QuickCheckViewModel.draftStorageDisclosure,
              enableIdentifier: "quick-check-enable-draft-retention",
              disableIdentifier: "quick-check-disable-draft-retention",
              setChoice: { choice in
                Task { await viewModel.setDraftRetentionChoice(choice) }
              }
            )
          }
          if viewModel.historyRetentionChoice == .undecided {
            retentionChoiceRow(
              title: "Save Quick Check history?",
              disclosure: QuickCheckViewModel.historyStorageDisclosure,
              enableIdentifier: "quick-check-enable-history-retention",
              disableIdentifier: "quick-check-disable-history-retention",
              setChoice: { choice in
                Task { await viewModel.setHistoryRetentionChoice(choice) }
              }
            )
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .accessibilityIdentifier("quick-check-retention-choices")
    }
  }

  private func retentionChoiceRow(
    title: String,
    disclosure: String,
    enableIdentifier: String,
    disableIdentifier: String,
    setChoice: @escaping (RetentionChoice) -> Void
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(.headline)
      Text(disclosure)
        .font(.caption)
        .foregroundStyle(.secondary)
      HStack {
        Button("Enable") { setChoice(.enabled) }
          .accessibilityIdentifier(enableIdentifier)
        Button("Don't Save") { setChoice(.disabled) }
          .accessibilityIdentifier(disableIdentifier)
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
            Button("Open Settings") {
              navigate(openSettings)
            }
            .accessibilityIdentifier("quick-check-open-settings")
          }
          Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  @ViewBuilder
  private var actionRow: some View {
    if viewModel.result == nil {
      HStack {
        Button {
          viewModel.check()
        } label: {
          Label("Check", systemImage: "checkmark.circle")
        }
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!viewModel.canCheck)
        .accessibilityIdentifier("quick-check-check")

        if let busyLabel = viewModel.busyLabel {
          ProgressView()
            .controlSize(.small)
            .accessibilityHidden(true)
          Text(busyLabel)
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("quick-check-busy-label")
        }
        Spacer()
      }
    }
  }

  @ViewBuilder
  private var outboundConfirmationSection: some View {
    if let summary = viewModel.outboundSummary {
      GroupBox("Confirm what will be sent") {
        VStack(alignment: .leading, spacing: 8) {
          summaryRow(label: "Action", value: summary.action)
          summaryRow(label: "Provider", value: summary.provider)
          summaryRow(label: "Model", value: summary.model)
          if let writingStyle = summary.writingStyle {
            summaryRow(label: "Writing Style", value: writingStyle.name)
            VStack(alignment: .leading, spacing: 4) {
              Text("Writing Style guidance")
                .font(.caption.bold())
              Text(writingStyle.guidance)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .accessibilityIdentifier("quick-check-outbound-writing-style-guidance")
            }
          }
          VStack(alignment: .leading, spacing: 4) {
            Text("Full draft")
              .font(.caption.bold())
            Text(summary.fullDraft)
              .frame(maxWidth: .infinity, alignment: .leading)
              .fixedSize(horizontal: false, vertical: true)
              .textSelection(.enabled)
              .padding(8)
              .background(Color(nsColor: .textBackgroundColor))
              .clipShape(RoundedRectangle(cornerRadius: 6))
              .accessibilityIdentifier("quick-check-outbound-full-draft")
          }
          Text(summary.disclosure)
            .font(.caption)
            .foregroundStyle(.secondary)
          HStack {
            Button("Cancel") {
              viewModel.cancelOutboundConfirmation()
            }
            .accessibilityIdentifier("quick-check-outbound-cancel")
            Spacer()
            Button("Send to \(summary.provider)") {
              viewModel.confirmOutbound()
            }
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityIdentifier("quick-check-outbound-confirm")
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Outbound request confirmation")
      .accessibilityIdentifier("quick-check-outbound-summary")
    }
  }

  private func summaryRow(label: String, value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Text("\(label):")
        .font(.caption.bold())
      Text(value)
        .font(.caption)
        .textSelection(.enabled)
    }
  }

  private var disclosureSection: some View {
    VStack(alignment: .leading, spacing: 3) {
      Label(
        "AI-generated edits may contain mistakes. Review before using them.",
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
        .accessibilityLabel("Quick Check error")
        .accessibilityValue(error)
        .accessibilityIdentifier("quick-check-error")
    }
  }

  @ViewBuilder
  private var resultSection: some View {
    if let result = viewModel.result {
      Divider()
      VStack(alignment: .leading, spacing: 14) {
        Text("Result")
          .font(.title3.bold())
          .accessibilityAddTraits(.isHeader)

        if let provenance = viewModel.resultProvenance {
          VStack(alignment: .leading, spacing: 3) {
            Label(
              "\(provenance.provider.displayName) · \(provenance.model)",
              systemImage: "checkmark.shield"
            )
            Text(
              "Writing Style: \(provenance.writingStyleName) · "
                + provenance.completedAt.formatted(date: .abbreviated, time: .shortened)
            )
          }
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityElement(children: .combine)
          .accessibilityLabel("Result provenance")
          .accessibilityValue(
            "\(provenance.provider.displayName), \(provenance.model), "
              + "\(provenance.writingStyleName), "
              + provenance.completedAt.formatted(date: .abbreviated, time: .shortened)
          )
          .accessibilityIdentifier("quick-check-result-provenance")
        }

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

        resultTextSection(
          title: "Corrected",
          text: result.corrected,
          identifier: "quick-check-corrected",
          secondary: false
        )
        resultTextSection(
          title: "Explanation",
          text: result.explanation,
          identifier: "quick-check-explanation",
          secondary: true
        )
        rewriteRow
        resultActionRow
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Quick Check result section")
    }
  }

  private func resultTextSection(
    title: String,
    text: String,
    identifier: String,
    secondary: Bool
  ) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title)
        .font(.headline)
        .accessibilityAddTraits(.isHeader)
      Text(text)
        .foregroundStyle(secondary ? .secondary : .primary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
        .accessibilityLabel(title)
        .accessibilityValue(text)
        .accessibilityIdentifier(identifier)
    }
  }

  private var diffSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("Changes")
          .font(.headline)
          .accessibilityAddTraits(.isHeader)
        Spacer()
        Button(viewModel.changesOnly ? "Show full text" : "Show only changes") {
          viewModel.changesOnly.toggle()
        }
        .buttonStyle(.link)
      }
      DiffText(segments: viewModel.diff, changesOnly: viewModel.changesOnly)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
        .accessibilityHidden(true)
      Color.clear
        .frame(width: 1, height: 1)
        .accessibilityElement()
        .accessibilityLabel("Changes")
        .accessibilityValue(viewModel.diffAccessibilitySummary)
        .accessibilityIdentifier("quick-check-diff")
    }
  }

  private var rewriteRow: some View {
    HStack {
      ForEach(RewriteIntent.allCases, id: \.self) { intent in
        Button(intent.label) {
          viewModel.rewrite(intent)
        }
        .keyboardShortcut(rewriteShortcut(for: intent), modifiers: .command)
        .disabled(viewModel.isBusy || viewModel.outboundSummary != nil)
        .accessibilityIdentifier("quick-check-rewrite-\(intent.rawValue)")
      }
      if let busyLabel = viewModel.busyLabel {
        Text(busyLabel)
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("quick-check-busy-label")
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
      .keyboardShortcut(.return, modifiers: .command)
      .disabled(viewModel.isBusy || viewModel.outboundSummary != nil)
      .accessibilityIdentifier("quick-check-copy-close")
    }
  }

  private var managementRow: some View {
    HStack(spacing: 12) {
      Button("History") {
        navigate(openHistory)
      }
      .accessibilityIdentifier("quick-check-history")
      Button("Writing Styles") {
        navigate(openWritingStyles)
      }
      .accessibilityIdentifier("quick-check-writing-styles")
      Button("Settings") {
        navigate(openSettings)
      }
      .accessibilityIdentifier("quick-check-settings")
      Spacer()
    }
    .buttonStyle(.link)
    .font(.caption)
  }

  private func navigate(_ action: () -> Void) {
    viewModel.dismiss(.auxiliaryNavigation)
    action()
  }

  private func rewriteShortcut(for intent: RewriteIntent) -> KeyEquivalent {
    switch intent {
    case .formal: "1"
    case .friendly: "2"
    case .shorter: "3"
    }
  }

  private func writingStyleMenuLabel(_ title: String, selected: Bool) -> some View {
    HStack {
      Text(title)
      if selected {
        Image(systemName: "checkmark")
      }
    }
  }
}
