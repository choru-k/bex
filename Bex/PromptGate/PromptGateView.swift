import AppKit
import Combine
import SwiftUI

enum PromptGateLayout {
  static func finalEditorHeight(for availableHeight: CGFloat) -> CGFloat {
    min(320, max(180, availableHeight * 0.4))
  }
}

struct PromptGateView: View {
  @ObservedObject var viewModel: PromptGateViewModel
  @FocusState private var keyboardFocus: PromptGateKeyboardFocus?
  @AccessibilityFocusState private var accessibilityFocus: PromptGateAccessibilityFocus?
  @State private var isDetailsExpanded = false
  @State private var isMaskingExpanded = false

  var body: some View {
    GeometryReader { geometry in
      VStack(spacing: 0) {
        ScrollView {
          content(availableHeight: geometry.size.height)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        Divider()
        footer
          .padding(.horizontal, 16)
          .padding(.vertical, 12)
          .background(.bar)
      }
    }
    .frame(
      minWidth: PromptGatePanelLayout.minimumContentSize.width,
      minHeight: PromptGatePanelLayout.minimumContentSize.height
    )
    .onChange(of: viewModel.session?.id) { _ in
      isDetailsExpanded = false
      isMaskingExpanded = false
    }
    .onExitCommand { viewModel.cancel() }
    .onReceive(viewModel.$focusRequest.compactMap { $0 }) { request in
      DispatchQueue.main.async {
        keyboardFocus = request.keyboard
        accessibilityFocus = request.accessibility
      }
    }
    .onReceive(viewModel.$accessibilityAnnouncement.compactMap { $0 }) { message in
      NSAccessibility.post(
        element: NSApp as Any,
        notification: .announcementRequested,
        userInfo: [.announcement: message]
      )
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in
      viewModel.refreshAccessibilityState()
    }
    .alert(
      "Discard your correction edits?",
      isPresented: Binding(
        get: { viewModel.showsDiscardConfirmation },
        set: { _ in }
      )
    ) {
      Button("Keep Editing", role: .cancel) { viewModel.keepEditing() }
        .accessibilityFocused($accessibilityFocus, equals: .discardAlert)
        .accessibilityIdentifier("prompt-gate-keep-correction-edits")
      Button("Discard Edits", role: .destructive) { viewModel.confirmDiscard() }
    } message: {
      Text(
        "Your edits to the AI correction have not been delivered. The AI output alone does not require a discard warning."
      )
    }
    .alert(
      "Replace edited correction?",
      isPresented: Binding(
        get: { viewModel.showsCheckpointReplacementConfirmation },
        set: { _ in }
      )
    ) {
      Button("Keep Editing", role: .cancel) { viewModel.keepCheckpoint() }
        .accessibilityFocused($accessibilityFocus, equals: .discardAlert)
        .accessibilityIdentifier("prompt-gate-keep-checkpoint")
      Button("Replace Checkpoint", role: .destructive) {
        viewModel.confirmCheckpointReplacement()
      }
    } message: {
      Text(
        "Checking the changed source will replace the checkpoint containing your correction edits.")
    }
  }

  @ViewBuilder
  private func content(availableHeight: CGFloat) -> some View {
    switch viewModel.phase {
    case .onboarding:
      if viewModel.isLoadingSession {
        ProgressView("Preparing Prompt Gate…")
          .frame(maxWidth: .infinity, minHeight: 220, alignment: .center)
          .accessibilityIdentifier("prompt-gate-loading")
      } else {
        outboundConfirmation
      }
    case .composing, .checking:
      composer
    case .reviewing, .delivering:
      review(availableHeight: availableHeight)
    case .invalidated:
      invalidated
    case .closed:
      EmptyView()
    }
  }

  private var outboundConfirmation: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label("Review outbound Prompt Gate payload", systemImage: "checkmark.shield")
        .font(.title2.bold())
        .accessibilityAddTraits(.isHeader)
        .accessibilityFocused($accessibilityFocus, equals: .disclosureHeading)
        .accessibilityIdentifier("prompt-gate-disclosure")

      Text(viewModel.providerDisclosure)

      // The payload with every withheld span drawn as a chip rather than as a
      // `[[[BEX_PROTECTED_…]]]` placeholder. Same guarantee, but now readable in one look:
      // this is the sentence that leaves, and those are the pieces that do not.
      Text(maskedPayloadText)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
          RoundedRectangle(cornerRadius: 8)
            .stroke(Color(nsColor: .separatorColor))
        }
        .accessibilityLabel("Masked Prompt Gate payload")
        .accessibilityValue(viewModel.outboundPayload)
        .accessibilityIdentifier("prompt-gate-outbound-payload")

      Text(viewModel.maskedSpanSummary)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("prompt-gate-masked-span-summary")

      DisclosureGroup(isExpanded: $isMaskingExpanded) {
        Text(viewModel.protectedSpanDisclosure)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, 6)
          .accessibilityIdentifier("prompt-gate-protected-span-disclosure")
      } label: {
        Button("What masking covers") { isMaskingExpanded.toggle() }
          .buttonStyle(.plain)
          .accessibilityIdentifier("prompt-gate-masking-disclosure")
      }

      permissionSection
    }
  }

  /// The masked payload as one flowing attributed string: prose in monospace, each withheld
  /// span as a lock chip naming what it was.
  ///
  /// An `AttributedString` rather than real chip views because macOS 13 has no wrapping
  /// stack, and a payload has to wrap — a row of views would either clip or scroll
  /// sideways, and a payload the owner cannot fully read is not a payload they can approve.
  private var maskedPayloadText: AttributedString {
    var result = AttributedString()
    for segment in viewModel.outboundSegments {
      switch segment.content {
      case let .text(text):
        var run = AttributedString(text)
        run.font = .body.monospaced()
        result += run
      case let .masked(kind):
        var run = AttributedString(" 🔒 \(kind) ")
        run.font = .caption.weight(.semibold)
        run.foregroundColor = .green
        run.backgroundColor = .green.opacity(0.16)
        result += run
      }
    }
    return result
  }

  private var composer: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      VStack(alignment: .leading, spacing: 6) {
        Text("Prompt to correct")
          .font(.headline)
          .accessibilityAddTraits(.isHeader)
          .accessibilityFocused($accessibilityFocus, equals: .composerHeading)
        TextEditor(text: $viewModel.draft)
          .font(.body)
          .frame(minHeight: 260)
          .padding(5)
          .background(Color(nsColor: .textBackgroundColor))
          .clipShape(RoundedRectangle(cornerRadius: 7))
          .overlay {
            RoundedRectangle(cornerRadius: 7)
              .stroke(Color(nsColor: .separatorColor))
          }
          .disabled(viewModel.phase == .checking)
          .focused($keyboardFocus, equals: .draftEditor)
          .accessibilityLabel("Prompt to correct, editable")
          .accessibilityIdentifier("prompt-gate-input")
      }
      targetGuidance
      error
    }
  }

  private func review(availableHeight: CGFloat) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text(viewModel.reviewTitle)
          .font(.title2.bold())
          .accessibilityAddTraits(.isHeader)
          .accessibilityIdentifier("prompt-gate-review-title")
        Text(viewModel.reviewContextDescription)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("prompt-gate-review-context")
        Text(viewModel.reviewPendingStatus)
          .font(.callout.weight(.medium))
          .accessibilityIdentifier("prompt-gate-review-pending-status")
      }

      if let review = viewModel.review {
        let changes = DiffChange.make(from: review.diff)
        VStack(alignment: .leading, spacing: 6) {
          Text("Final message · editable")
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
            .accessibilityFocused($accessibilityFocus, equals: .finalMessageHeading)
            .accessibilityIdentifier("prompt-gate-final-message-heading")
          correctedEditor(
            review.corrected,
            height: PromptGateLayout.finalEditorHeight(for: availableHeight)
          )
          // The redline sits directly under the message it describes, one line, so "what
          // did it change" is answered without reading a second panel.
          if changes.isEmpty {
            Text("No grammar changes. You can still edit the final message.")
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("prompt-gate-no-changes")
          } else {
            DiffRedline(changes: changes, categorySummary: viewModel.changeCategorySummary)
              .accessibilityHidden(true)
              .overlay {
                DiffSummaryAccessibilityElement(
                  changeCount: changes.count,
                  summary: viewModel.accessibleDiffSummary
                )
              }
          }
        }

        error

        alternativesPanel

        details(review: review)
      }
    }
  }

  /// The unranked alternatives, given the most visual weight on the sheet.
  ///
  /// This used to be a grey bullet list under the diff, which had it exactly backwards:
  /// `docs/purpose.md` says correcting and teaching are separate jobs and *teaching is the
  /// higher priority*, and this panel is the only teaching on the sheet. The grammar fixes
  /// are already applied and need no decision; this is the one thing asking the owner to
  /// think.
  @ViewBuilder
  private var alternativesPanel: some View {
    let alternatives = viewModel.alternatives
    if !alternatives.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .firstTextBaseline) {
          Text("Which fits?")
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
          Text("— your pick becomes a Study card")
            .font(.subheadline)
            .foregroundStyle(.secondary)
          Spacer(minLength: 8)
          if !viewModel.alternativesPhrase.isEmpty {
            Text("for “\(viewModel.alternativesPhrase)”")
              .font(.caption)
              .foregroundStyle(.tertiary)
          }
        }
        .accessibilityIdentifier("prompt-gate-better-expression")

        ForEach(alternatives) { alternative in
          alternativeRow(alternative)
        }

        Text("Unranked — pick what you would actually say, or skip; ⌘⏎ sends as-is.")
          .font(.caption)
          .foregroundStyle(.tertiary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("prompt-gate-alternatives-unranked-note")
      }
      .padding(14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
      .overlay {
        RoundedRectangle(cornerRadius: 10)
          .strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 1)
      }
    }
  }

  private func alternativeRow(_ alternative: PromptGateAlternative) -> some View {
    let isPicked = viewModel.pickedAlternativeID == alternative.id
    return Button {
      viewModel.choose(alternative)
    } label: {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: isPicked ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(isPicked ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
        VStack(alignment: .leading, spacing: 2) {
          Text(alternative.alternative)
            .fontWeight(.medium)
          if !alternative.reason.isEmpty {
            Text(alternative.reason)
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 9)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      .background(
        RoundedRectangle(cornerRadius: 9)
          .fill(isPicked ? AnyShapeStyle(.tint.opacity(0.16)) : AnyShapeStyle(.quaternary))
      )
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isPicked ? [.isSelected] : [])
    .accessibilityIdentifier("prompt-gate-alternative-\(alternative.id)")
  }

  /// Everything that used to have its own heading: the original message, the model's grammar
  /// notes, the provider, and what each delivery button does.
  ///
  /// One disclosure instead of four sections. None of it is a decision — it is all there to
  /// be checked when something looks wrong, and four open panels of reference material was
  /// what pushed the actual choice off the bottom of the sheet.
  @ViewBuilder
  private func details(review: PromptGateReview) -> some View {
    DisclosureGroup(isExpanded: $isDetailsExpanded) {
      VStack(alignment: .leading, spacing: 12) {
        detailSection("Original message") {
          Text(review.original)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Original message, read only")
            .accessibilityValue(review.original)
            .accessibilityIdentifier("prompt-gate-original")
        }

        let grammarNotes = LearningAggregator.explanationWithoutConsider(from: review.explanation)
        if !grammarNotes.isEmpty {
          detailSection("Grammar notes") {
            VStack(alignment: .leading, spacing: 6) {
              Text(grammarNotes)
                .textSelection(.enabled)
                .accessibilityIdentifier("prompt-gate-explanation")
              if review.hasHumanEdits {
                Text(
                  "This AI note describes the original suggestion and may not reflect your edits."
                )
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("prompt-gate-ai-note-stale")
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
        }

        if let target = viewModel.session?.target {
          detailSection("Delivery") {
            VStack(alignment: .leading, spacing: 6) {
              Text(viewModel.deliveryGuidanceIntroduction)
                .fixedSize(horizontal: false, vertical: true)
              ForEach(target.availableDeliveryActions, id: \.self) { action in
                Text(
                  "\(viewModel.deliveryActionLabel(action)): "
                    + viewModel.deliveryEffectDescription(for: action)
                )
                .fixedSize(horizontal: false, vertical: true)
              }
              if viewModel.session?.hookRequestID != nil,
                viewModel.hookClientStatus.permitsReceipt
              {
                Text(
                  "Approval is acknowledged for this request only and expires after two minutes."
                )
                .fixedSize(horizontal: false, vertical: true)
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("prompt-gate-delivery-guidance")
          }
        }
      }
      .padding(.top, 8)
    } label: {
      Button {
        isDetailsExpanded.toggle()
      } label: {
        // States plainly that nothing has left yet — the reassurance belongs on the label,
        // where it is read, not inside a panel nobody opened.
        Text(detailsSummary)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("prompt-gate-details-disclosure")
    }
  }

  private var detailsSummary: String {
    "Details — original message · grammar notes · checked by "
      + "\(viewModel.selectedProvider.displayName) \(viewModel.selectedModel) · nothing sent yet"
  }

  private func detailSection<Content: View>(
    _ title: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.caption.weight(.semibold))
        .textCase(.uppercase)
        .foregroundStyle(.tertiary)
      content()
    }
    .font(.callout)
    .foregroundStyle(.secondary)
  }

  private func correctedEditor(_ value: String, height: CGFloat) -> some View {
    TextEditor(
      text: Binding(
        get: { viewModel.review?.corrected ?? value },
        set: { viewModel.updateCorrected($0) }
      )
    )
    .padding(5)
    .frame(height: height)
    .background(Color(nsColor: .textBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 7))
    .overlay {
      RoundedRectangle(cornerRadius: 7)
        .stroke(Color(nsColor: .separatorColor))
    }
    .disabled(!viewModel.canEditCorrection)
    .focused($keyboardFocus, equals: .correctedEditor)
    .accessibilityLabel("Final message for \(viewModel.destinationLabel), editable")
    .accessibilityIdentifier("prompt-gate-corrected")
  }

  private var invalidated: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("Prompt review is no longer active", systemImage: "exclamationmark.triangle")
        .font(.title3.bold())
        .accessibilityAddTraits(.isHeader)
        .accessibilityFocused($accessibilityFocus, equals: .statusHeading)
      error
      Text("Return to the prompt client and invoke Fix & Send again.")
        .foregroundStyle(.secondary)
    }
  }

  private var permissionSection: some View {
    GroupBox("Accessibility") {
      VStack(alignment: .leading, spacing: 8) {
        Text(viewModel.permissionGuidance)
        if let status = viewModel.accessibilityStatusMessage {
          Text(status)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("prompt-gate-accessibility-status")
        }
        if !viewModel.isAccessibilityTrusted,
          viewModel.session?.hookRequestID == nil
        {
          Button("Request Accessibility") { viewModel.requestAccessibility() }
            .accessibilityIdentifier("prompt-gate-accessibility")
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var header: some View {
    HStack(spacing: 8) {
      Text(viewModel.selectedProvider.displayName)
      Text("·").foregroundStyle(.secondary)
      Text(viewModel.selectedModel).lineLimit(1)
    }
    .font(.caption)
  }

  private var targetGuidance: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text("Destination: \(viewModel.destinationLabel)")
        .fontWeight(.medium)
      Text(viewModel.session?.target.guidance ?? "")
      Text(viewModel.permissionGuidance)
      if viewModel.session?.hookRequestID != nil,
        viewModel.hookClientStatus.permitsReceipt
      {
        Text("Approval is acknowledged for this request only and expires after two minutes.")
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .accessibilityIdentifier("prompt-gate-target-guidance")
  }

  @ViewBuilder
  private var error: some View {
    if let errorMessage = viewModel.errorMessage {
      Label(errorMessage, systemImage: "exclamationmark.circle")
        .font(.caption)
        .foregroundStyle(.red)
        .textSelection(.enabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(errorMessage)
        .accessibilityValue(errorMessage)
        .accessibilityAddTraits(.isHeader)
        .accessibilityFocused($accessibilityFocus, equals: .errorHeading)
        .accessibilityIdentifier("prompt-gate-error")
    }
  }

  @ViewBuilder
  private var footer: some View {
    HStack(spacing: 10) {
      switch viewModel.phase {
      case .closed:
        EmptyView()
      case .onboarding:
        cancelButton
        Spacer()
        Button(viewModel.confirmationActionLabel) { viewModel.acceptDisclosure() }
          .keyboardShortcut(.return, modifiers: .command)
          .disabled(viewModel.isLoadingSession)
          .focused($keyboardFocus, equals: .primaryAction)
          .accessibilityIdentifier("prompt-gate-confirm-outbound")
      case .composing:
        cancelButton
        Spacer()
        if viewModel.needsProviderSetup {
          Button("Open Settings") { viewModel.openSettings() }
            .keyboardShortcut(.return, modifiers: .command)
            .focused($keyboardFocus, equals: .recoveryAction)
            .accessibilityIdentifier("prompt-gate-open-settings")
        } else {
          Button(viewModel.composerPrimaryActionLabel) { viewModel.check() }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!viewModel.canReview)
            .focused($keyboardFocus, equals: .primaryAction)
            .accessibilityIdentifier("prompt-gate-review")
        }
      case .checking:
        cancelButton
        Spacer()
        ProgressView().controlSize(.small)
        Text("Checking…").foregroundStyle(.secondary)
        if viewModel.canSkipHookCheck {
          Button("Skip & Send Original") { viewModel.skipCheckAndSendOriginal() }
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityIdentifier("prompt-gate-skip-check")
        }
      case .reviewing:
        reviewFooter
          .frame(maxWidth: .infinity)
      case .delivering:
        Spacer()
        ProgressView().controlSize(.small)
        Text("Delivering…").foregroundStyle(.secondary)
      case .invalidated:
        Spacer()
        Button("Close", role: .cancel) { viewModel.cancel() }
          .keyboardShortcut(.return, modifiers: .command)
          .focused($keyboardFocus, equals: .recoveryAction)
          .accessibilityIdentifier("prompt-gate-close-invalidated")
      }
    }
  }

  @ViewBuilder
  private var reviewFooter: some View {
    if viewModel.hasTerminalDeliveryFailure {
      HStack(spacing: 10) {
        Spacer()
        deliveryButtons
      }
    } else {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 10) {
          cancelButton
          editOriginalButton
          Spacer()
          deliveryButtons
        }
        VStack(alignment: .trailing, spacing: 8) {
          HStack(spacing: 10) {
            cancelButton
            editOriginalButton
            Spacer()
          }
          HStack(spacing: 10) {
            Spacer()
            deliveryButtons
          }
        }
      }
    }
  }

  private var editOriginalButton: some View {
    Button("Edit Original & Recheck") { viewModel.backToEdit() }
      .keyboardShortcut("[", modifiers: .command)
      .accessibilityIdentifier("prompt-gate-back")
  }

  private var cancelButton: some View {
    Button("Cancel", role: .cancel) { viewModel.cancel() }
      .accessibilityIdentifier("prompt-gate-cancel")
  }

  @ViewBuilder
  private var deliveryButtons: some View {
    if let effect = viewModel.deliveryFailureEffect, !effect.isFullRetrySafe {
      Button("Close") { viewModel.finishAfterPartialDelivery() }
        .keyboardShortcut(.return, modifiers: .command)
        .focused($keyboardFocus, equals: .recoveryAction)
        .accessibilityIdentifier("prompt-gate-delivery-done")
    } else if let target = viewModel.session?.target,
      let primary = viewModel.primaryDeliveryAction
    {
      ForEach(target.availableDeliveryActions, id: \.self) { action in
        if action != primary {
          Button(viewModel.deliveryActionLabel(action)) {
            viewModel.performDelivery(action)
          }
          .disabled(!viewModel.canApprove)
          .accessibilityIdentifier("prompt-gate-delivery-\(action.rawValue)")
        }
      }
      Button(viewModel.deliveryActionLabel(primary)) {
        viewModel.performDelivery(primary)
      }
      .keyboardShortcut(.return, modifiers: .command)
      .disabled(!viewModel.canApprove)
      .focused(
        $keyboardFocus,
        equals: viewModel.deliveryFailureEffect == nil ? .primaryAction : .recoveryAction
      )
      .accessibilityIdentifier("prompt-gate-delivery-\(primary.rawValue)")
    }
  }
}
