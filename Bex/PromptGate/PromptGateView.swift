import SwiftUI

struct PromptGateView: View {
  @ObservedObject var viewModel: PromptGateViewModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        switch viewModel.phase {
        case .onboarding:
          onboarding
        case .composing, .checking:
          composer
        case .reviewing, .delivering, .invalidated:
          review
        case .closed:
          EmptyView()
        }
      }
      .padding(16)
    }
    .frame(minWidth: 620, minHeight: 500)
    .onExitCommand { viewModel.cancel() }
  }

  private var onboarding: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label("Review before anything is sent", systemImage: "checkmark.shield")
        .font(.title2.bold())
        .accessibilityIdentifier("prompt-gate-disclosure")
      Text("Bex corrects English grammar, preserves protected technical text, and shows every change. Only the correction you explicitly approve is delivered.")
      GroupBox("Correction provider") {
        VStack(alignment: .leading, spacing: 6) {
          Text("Provider: \(viewModel.selectedProvider.displayName)")
          Text(viewModel.providerDisclosure)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      GroupBox("Accessibility") {
        VStack(alignment: .leading, spacing: 6) {
          Text("Accessibility lets Bex inspect and replace only the focused editable prompt field after approval. Bex never reads terminal scrollback or secure fields.")
          Text(viewModel.isAccessibilityTrusted ? "Accessibility access is enabled." : "Without access, Bex copies the correction for manual replacement.")
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("prompt-gate-accessibility-status")
          Button("Request Accessibility") { viewModel.requestAccessibility() }
            .accessibilityIdentifier("prompt-gate-accessibility")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      HStack {
        Spacer()
        Button("Cancel") { viewModel.cancel() }
          .accessibilityIdentifier("prompt-gate-cancel")
        Button("Continue") { viewModel.acceptDisclosure() }
          .accessibilityIdentifier("prompt-gate-continue")
      }
    }
  }

  private var composer: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      VStack(alignment: .leading, spacing: 6) {
        Text("Prompt to correct").font(.headline)
        TextEditor(text: $viewModel.draft)
          .font(.body)
          .frame(minHeight: 220)
          .padding(5)
          .background(Color(nsColor: .textBackgroundColor))
          .clipShape(RoundedRectangle(cornerRadius: 7))
          .overlay {
            RoundedRectangle(cornerRadius: 7)
              .stroke(Color(nsColor: .separatorColor))
          }
          .disabled(viewModel.phase == .checking)
          .accessibilityIdentifier("prompt-gate-input")
      }
      targetGuidance
      error
      HStack {
        Button("Cancel") { viewModel.cancel() }
          .accessibilityIdentifier("prompt-gate-cancel")
        Spacer()
        if viewModel.phase == .checking {
          ProgressView().controlSize(.small)
          Text("Checking…").foregroundStyle(.secondary)
        }
        Button("Review") { viewModel.check() }
          .disabled(!viewModel.canReview)
          .accessibilityIdentifier("prompt-gate-review")
      }
    }
  }

  private var review: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      if let review = viewModel.review {
        VStack(alignment: .leading, spacing: 6) {
          Text("Changes").font(.headline)
          DiffText(segments: review.diff, changesOnly: false)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .accessibilityIdentifier("prompt-gate-diff")
        }

        HStack(alignment: .top, spacing: 12) {
          VStack(alignment: .leading, spacing: 5) {
            Text("Original").font(.headline)
            ScrollView {
              Text(review.original)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(8)
            }
            .frame(minHeight: 150)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .accessibilityIdentifier("prompt-gate-original")
          }
          VStack(alignment: .leading, spacing: 5) {
            Text("Corrected — editable").font(.headline)
            TextEditor(
              text: Binding(
                get: { viewModel.review?.corrected ?? "" },
                set: { viewModel.updateCorrected($0) }
              )
            )
            .padding(5)
            .frame(minHeight: 150)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay {
              RoundedRectangle(cornerRadius: 7)
                .stroke(Color(nsColor: .separatorColor))
            }
            .disabled(viewModel.phase != .reviewing)
            .accessibilityIdentifier("prompt-gate-corrected")
          }
        }

        VStack(alignment: .leading, spacing: 5) {
          Text("Explanation").font(.headline)
          Text(review.explanation)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .accessibilityIdentifier("prompt-gate-explanation")
        }
      }
      targetGuidance
      error
      HStack {
        Button("Cancel") { viewModel.cancel() }
          .accessibilityIdentifier("prompt-gate-cancel")
        Button("Back") { viewModel.backToEdit() }
          .disabled(viewModel.phase != .reviewing)
          .accessibilityIdentifier("prompt-gate-back")
        Spacer()
        if viewModel.phase == .delivering {
          ProgressView().controlSize(.small)
          Text("Delivering…").foregroundStyle(.secondary)
        }
        Button(sendButtonLabel) { viewModel.approve() }
          .disabled(!viewModel.canApprove)
          .accessibilityIdentifier("prompt-gate-send")
      }
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
        ForEach(PromptClient.allCases) { client in
          Text(client.displayName).tag(client)
        }
      }
      .labelsHidden()
      .frame(width: 150)
      .disabled(viewModel.clientIsLocked || viewModel.phase == .checking || viewModel.phase == .delivering)
      .accessibilityIdentifier("prompt-gate-client")
    }
    .font(.caption)
  }

  private var targetGuidance: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(viewModel.session?.target.guidance ?? "")
      if viewModel.session?.target.kind != .capturedField,
        viewModel.selectedClientStatus.permitsReceipt
      {
        Text("Approval expires after two minutes.")
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  @ViewBuilder
  private var error: some View {
    if let errorMessage = viewModel.errorMessage {
      Label(errorMessage, systemImage: "exclamationmark.circle")
        .font(.caption)
        .foregroundStyle(.red)
        .textSelection(.enabled)
        .accessibilityIdentifier("prompt-gate-error")
    }
  }

  private var sendButtonLabel: String {
    guard let target = viewModel.session?.target else { return "Send Corrected" }
    return switch target.kind {
    case .copyOnly:
      "Copy Corrected"
    case .composerPaste:
      "Paste Corrected"
    case .capturedField:
      viewModel.deliveryMode == .sendAfterApproval ? "Send Corrected" : "Paste Corrected"
    }
  }
}
