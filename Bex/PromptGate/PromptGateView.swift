import AppKit
import Combine
import SwiftUI

struct PromptGateView: View {
  @ObservedObject var viewModel: PromptGateViewModel
  @FocusState private var keyboardFocus: PromptGateKeyboardFocus?
  @AccessibilityFocusState private var accessibilityFocus: PromptGateAccessibilityFocus?

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        content
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(16)
      }
      Divider()
      footer
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }
    .frame(minWidth: 620, minHeight: 500)
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
  private var content: some View {
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
      review
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

      GroupBox("Masked payload sent for correction") {
        Text(viewModel.outboundPayload)
          .font(.body.monospaced())
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityLabel("Masked Prompt Gate payload")
          .accessibilityIdentifier("prompt-gate-outbound-payload")
      }

      Text(viewModel.protectedSpanDisclosure)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("prompt-gate-protected-span-disclosure")

      permissionSection
    }
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

  @ViewBuilder
  private var review: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      if let review = viewModel.review {
        if viewModel.isNoChangeReview {
          noChangeReview(review)
        } else {
          changedReview(review)
        }
      }
      targetGuidance
      if let action = viewModel.primaryDeliveryAction {
        Text(viewModel.deliveryEffectDescription(for: action))
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("prompt-gate-delivery-effect")
      }
      error
    }
  }

  private func noChangeReview(_ review: PromptGateReview) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("No Changes")
        .font(.title3.bold())
        .accessibilityAddTraits(.isHeader)
        .accessibilityFocused($accessibilityFocus, equals: .noChangesHeading)
      Text("Bex found no grammar changes. You can still edit the final text before delivery.")
        .foregroundStyle(.secondary)
      correctedEditor(review.corrected, minimumHeight: 260)
    }
    .accessibilityIdentifier("prompt-gate-no-changes")
  }

  private func changedReview(_ review: PromptGateReview) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Changes")
          .font(.title3.bold())
          .accessibilityAddTraits(.isHeader)
          .accessibilityFocused($accessibilityFocus, equals: .changesHeading)
        Text(viewModel.accessibleDiffSummary)
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("prompt-gate-diff-summary")
        DiffText(segments: review.diff, changesOnly: false)
          .frame(maxWidth: .infinity, alignment: .leading)
          .textSelection(.enabled)
          .accessibilityHidden(true)
          .accessibilityIdentifier("prompt-gate-diff")
      }

      HStack(alignment: .top, spacing: 12) {
        VStack(alignment: .leading, spacing: 5) {
          Text("Original — read only").font(.headline)
          ScrollView {
            Text(review.original)
              .frame(maxWidth: .infinity, alignment: .leading)
              .textSelection(.enabled)
              .padding(8)
          }
          .frame(minHeight: 170)
          .background(Color(nsColor: .textBackgroundColor))
          .clipShape(RoundedRectangle(cornerRadius: 7))
          .accessibilityLabel("Original prompt, read only")
          .accessibilityIdentifier("prompt-gate-original")
        }
        VStack(alignment: .leading, spacing: 5) {
          Text("Corrected — editable").font(.headline)
          correctedEditor(review.corrected, minimumHeight: 170)
        }
      }

      if !review.explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        VStack(alignment: .leading, spacing: 5) {
          Text("Explanation")
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
          Text(review.explanation)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .accessibilityIdentifier("prompt-gate-explanation")
        }
      }
    }
  }

  private func correctedEditor(_ value: String, minimumHeight: CGFloat) -> some View {
    TextEditor(
      text: Binding(
        get: { viewModel.review?.corrected ?? value },
        set: { viewModel.updateCorrected($0) }
      )
    )
    .padding(5)
    .frame(minHeight: minimumHeight)
    .background(Color(nsColor: .textBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 7))
    .overlay {
      RoundedRectangle(cornerRadius: 7)
        .stroke(Color(nsColor: .separatorColor))
    }
    .disabled(viewModel.phase != .reviewing)
    .focused($keyboardFocus, equals: .correctedEditor)
    .accessibilityLabel("Corrected prompt, editable")
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
      Spacer()
      Picker(
        "Prompt client",
        selection: Binding(
          get: { viewModel.selectedClient },
          set: { viewModel.setSelectedClient($0) }
        )
      ) {
        ForEach(PromptClient.focusedPickerClients) { client in
          Text(client.displayName).tag(client)
        }
      }
      .labelsHidden()
      .frame(width: 150)
      .disabled(
        viewModel.clientIsLocked || viewModel.phase == .checking || viewModel.phase == .delivering
      )
      .accessibilityLabel("Prompt client")
      .accessibilityIdentifier("prompt-gate-client")
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
        viewModel.selectedClientStatus.permitsReceipt
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
        if viewModel.hasTerminalDeliveryFailure {
          Spacer()
          deliveryButtons
        } else {
          cancelButton
          Button("Back") { viewModel.backToEdit() }
            .keyboardShortcut("[", modifiers: .command)
            .accessibilityIdentifier("prompt-gate-back")
          Spacer()
          deliveryButtons
        }
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
      ForEach(target.availableDeliveryActions.filter { $0 != primary }, id: \.self) { action in
        Button(viewModel.deliveryActionLabel(action)) {
          viewModel.performDelivery(action)
        }
        .disabled(!viewModel.canApprove)
        .accessibilityIdentifier("prompt-gate-delivery-\(action.rawValue)")
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
