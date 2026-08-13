import AppKit
import SwiftUI

enum QuickCheckLayout {
  static func editorHeight(for availableHeight: CGFloat) -> CGFloat {
    min(280, max(120, availableHeight * 0.3))
  }
}

/// Quick Check: a draft editor that becomes the shared review card once a check runs.
///
/// Design 4a. After a check, this is the same `ReviewCardView` Fix & Send shows —
/// same editable final message, same one-line redline, same alternatives panel and ask
/// thread — differing only in the footer (Cancel / Copy Correction ⏎) and in what is
/// absent: no target row, no provenance line, no Edit Original & Recheck. Hands that hit
/// ⇧⌘G all day never re-learn a layout.
struct QuickCheckView: View {
  @ObservedObject var viewModel: QuickCheckViewModel
  /// Questions about the correction on screen. Owned outside the view so a question in
  /// flight survives re-renders, matching Fix & Send.
  @ObservedObject var askThread: AskThreadViewModel
  let openSettings: () -> Void
  let openWritingStyles: () -> Void
  let openHistory: () -> Void

  @FocusState private var isEditorFocused: Bool
  @FocusState private var keyboardFocus: PromptGateKeyboardFocus?
  @AccessibilityFocusState private var accessibilityFocus: PromptGateAccessibilityFocus?
  @State private var isDetailsExpanded = false

  var body: some View {
    GeometryReader { geometry in
      if let review = viewModel.review {
        reviewLayout(review, availableHeight: geometry.size.height)
      } else {
        draftLayout(geometry: geometry)
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
    .onChange(of: viewModel.review?.original) { _ in
      isDetailsExpanded = false
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

  // MARK: - Post-check: the shared card

  private func reviewLayout(_ review: PromptGateReview, availableHeight: CGFloat) -> some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          contextRow
          ReviewCardView(
            idPrefix: "quick-check",
            review: review,
            corrected: Binding(
              get: { viewModel.review?.corrected ?? review.corrected },
              set: { viewModel.updateCorrected($0) }
            ),
            availableHeight: availableHeight,
            canEditCorrection: true,
            correctedFieldLabel: "Corrected text, editable",
            errorMessage: viewModel.userVisibleError,
            alternatives: viewModel.alternatives,
            alternativesPhrase: viewModel.alternativesPhrase,
            pickedAlternativeID: viewModel.pickedAlternativeID,
            onChooseAlternative: { viewModel.choose($0) },
            changeCategorySummary: viewModel.changeCategorySummary,
            accessibleDiffSummary: viewModel.accessibleDiffSummary,
            detailsSummary: "Details — original message · grammar notes · checked by "
              + "\(viewModel.providerLabel) \(viewModel.modelLabel)",
            isDetailsExpanded: $isDetailsExpanded,
            askThread: askThread,
            keyboardFocus: $keyboardFocus,
            accessibilityFocus: $accessibilityFocus,
            detailsExtra: { EmptyView() }
          )
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      Divider()
      reviewFooter
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }
  }

  private var reviewFooter: some View {
    HStack(spacing: 10) {
      Button("Cancel", role: .cancel) {
        viewModel.dismiss(.explicitCancel)
      }
      .accessibilityIdentifier("quick-check-cancel")
      Spacer()
      Button("Copy Correction ⏎") {
        viewModel.copy(closeAfter: true)
      }
      .keyboardShortcut(.defaultAction)
      .disabled(!viewModel.canCopyCorrection)
      .accessibilityIdentifier("quick-check-copy-correction")
    }
  }

  // MARK: - Draft state

  private func draftLayout(geometry: GeometryProxy) -> some View {
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
        lookupSection
        managementRow
      }
      .padding(16)
      .frame(minHeight: geometry.size.height, alignment: .top)
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

  private var actionRow: some View {
    HStack {
      Button {
        viewModel.check()
      } label: {
        Label("Check", systemImage: "checkmark.circle")
      }
      .keyboardShortcut(.return, modifiers: .command)
      .disabled(!viewModel.canCheck)
      .accessibilityIdentifier("quick-check-check")

      Button {
        viewModel.lookUp()
      } label: {
        Label("Look Up", systemImage: "character.book.closed")
      }
      .keyboardShortcut("d", modifiers: .command)
      .disabled(!viewModel.canLookUp)
      .accessibilityIdentifier("quick-check-look-up")

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
  private var lookupSection: some View {
    if let lookup = viewModel.lookup {
      Divider()
      VStack(alignment: .leading, spacing: 14) {
        Text("Dictionary")
          .font(.title3.bold())
          .accessibilityAddTraits(.isHeader)

        lookupTextSection(
          title: "English",
          text: lookup.english,
          identifier: "quick-check-lookup-english",
          secondary: false
        )
        lookupTextSection(
          title: "Korean",
          text: lookup.korean,
          identifier: "quick-check-lookup-korean",
          secondary: false
        )
        lookupTextSection(
          title: "In simple English",
          text: lookup.simple,
          identifier: "quick-check-lookup-simple",
          secondary: true
        )
        lookupTextSection(
          title: "Example",
          text: lookup.example,
          identifier: "quick-check-lookup-example",
          secondary: true
        )

        HStack {
          Button(viewModel.lookupSavedToStudy ? "Saved to Study" : "Save to Study") {
            viewModel.saveLookupToStudy()
          }
          .disabled(viewModel.lookupSavedToStudy)
          .accessibilityIdentifier("quick-check-lookup-save")
          Spacer()
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Dictionary lookup section")
    }
  }

  private func lookupTextSection(
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

  private func writingStyleMenuLabel(_ title: String, selected: Bool) -> some View {
    HStack {
      Text(title)
      if selected {
        Image(systemName: "checkmark")
      }
    }
  }
}
