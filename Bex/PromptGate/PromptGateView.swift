import AppKit
import Combine
import SwiftUI

struct PromptGateView: View {
  @ObservedObject var viewModel: PromptGateViewModel
  /// The ask thread for this correction. Owned outside the view so a question in flight
  /// survives the sheet re-rendering around it.
  @ObservedObject var askThread: AskThreadViewModel
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
    // `--dry-run` must survive typing: smart dashes would un-mask a hand-typed flag.
    .background(PlainTextSubstitutionsDisabler().frame(width: 0, height: 0))
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
      // The target row and provenance line stay host-side: they are exactly what design
      // 4a deletes for Quick Check, so they are not part of the shared card.
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
        ReviewCardView(
          idPrefix: "prompt-gate",
          review: review,
          corrected: Binding(
            get: { viewModel.review?.corrected ?? review.corrected },
            set: { viewModel.updateCorrected($0) }
          ),
          availableHeight: availableHeight,
          canEditCorrection: viewModel.canEditCorrection,
          correctedFieldLabel: "Final message for \(viewModel.destinationLabel), editable",
          errorMessage: viewModel.errorMessage,
          alternatives: viewModel.alternatives,
          alternativesPhrase: viewModel.alternativesPhrase,
          pickedAlternativeID: viewModel.pickedAlternativeID,
          onChooseAlternative: { viewModel.choose($0) },
          primaryActionHint: "⌘⏎ sends as-is",
          changeCategorySummary: viewModel.changeCategorySummary,
          accessibleDiffSummary: viewModel.accessibleDiffSummary,
          detailsSummary: detailsSummary,
          isDetailsExpanded: $isDetailsExpanded,
          askThread: askThread,
          keyboardFocus: $keyboardFocus,
          accessibilityFocus: $accessibilityFocus,
          detailsExtra: { deliveryDetails }
        )
      }
    }
  }

  /// What each delivery button does, inside the card's Details disclosure. Delivery is
  /// Fix & Send's business, which is why this rides in through `detailsExtra` rather
  /// than living in the shared card.
  @ViewBuilder
  private var deliveryDetails: some View {
    if let target = viewModel.session?.target {
      ReviewCardDetailSection(title: "Delivery") {
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

  private var detailsSummary: String {
    "Details — original message · grammar notes · checked by "
      + "\(viewModel.selectedProvider.displayName) \(viewModel.selectedModel) · nothing sent yet"
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
