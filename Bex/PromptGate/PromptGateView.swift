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
  @State private var isOriginalExpanded = false
  @State private var isAINoteExpanded = false

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
      isOriginalExpanded = false
      isAINoteExpanded = false
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

      GroupBox("Masked payload sent for correction") {
        Text(viewModel.outboundPayload)
          .font(.body.monospaced())
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityLabel("Masked Prompt Gate payload")
          .accessibilityValue(viewModel.outboundPayload)
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
          Text("Final Message — Editable")
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
            .accessibilityFocused($accessibilityFocus, equals: .finalMessageHeading)
            .accessibilityIdentifier("prompt-gate-final-message-heading")
          correctedEditor(
            review.corrected,
            height: PromptGateLayout.finalEditorHeight(for: availableHeight)
          )
        }

        error

        if changes.isEmpty {
          VStack(alignment: .leading, spacing: 3) {
            Text("No Changes")
              .font(.headline)
              .accessibilityIdentifier("prompt-gate-no-changes")
            Text("Bex found no grammar changes. You can still edit the final message.")
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        } else {
          DiffChangeRows(changes: changes)
            .accessibilityHidden(true)
            .overlay {
              DiffSummaryAccessibilityElement(
                changeCount: changes.count,
                summary: viewModel.accessibleDiffSummary
              )
            }
        }

        DisclosureGroup(isExpanded: $isOriginalExpanded) {
          Text(review.original)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .padding(.top, 6)
            .accessibilityLabel("Original message, read only")
            .accessibilityValue(review.original)
            .accessibilityIdentifier("prompt-gate-original")
        } label: {
          Button("Original Message") { isOriginalExpanded.toggle() }
            .buttonStyle(.plain)
            .accessibilityIdentifier("prompt-gate-original-disclosure")
        }

        if !review.explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          DisclosureGroup(isExpanded: $isAINoteExpanded) {
            VStack(alignment: .leading, spacing: 6) {
              Text(review.explanation)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .accessibilityIdentifier("prompt-gate-explanation")
              if review.hasHumanEdits {
                Text("This AI note describes the original suggestion and may not reflect your edits.")
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .fixedSize(horizontal: false, vertical: true)
                  .accessibilityIdentifier("prompt-gate-ai-note-stale")
              }
            }
            .padding(.top, 6)
          } label: {
            Button("AI Note") { isAINoteExpanded.toggle() }
              .buttonStyle(.plain)
              .accessibilityIdentifier("prompt-gate-ai-note-disclosure")
          }
        }
      }

      if let target = viewModel.session?.target {
        GroupBox("Delivery") {
          VStack(alignment: .leading, spacing: 6) {
            Text(viewModel.deliveryGuidanceIntroduction)
              .fixedSize(horizontal: false, vertical: true)
            ForEach(target.availableDeliveryActions, id: \.self) { action in
              Text(
                "\(viewModel.deliveryActionLabel(action)): \(viewModel.deliveryEffectDescription(for: action))"
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
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("prompt-gate-delivery-guidance")
      }
    }
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
