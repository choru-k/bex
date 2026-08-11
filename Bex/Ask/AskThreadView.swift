import SwiftUI

/// "Ask about this — never blocks Send."
///
/// Design 2a. The reason this belongs on the review sheet rather than in a separate window:
/// the moment the owner is looking at a correction is the moment they have a question about
/// it, and `docs/purpose.md` records what happens to a surface they have to go to — the
/// original read-only Learning window taught nothing because it was never opened.
///
/// Everything about the layout defers to the sheet's primary action. It starts collapsed to
/// one input, it never grows a scroll view of its own, and a question in flight leaves Send
/// entirely usable (non-negotiable 2).
struct AskThreadView: View {
  @ObservedObject var viewModel: AskThreadViewModel
  /// Placeholder for the input. The surfaces word it differently — a correction invites
  /// questions about a change, a card invites questions about the card.
  var prompt: String = "Ask about an expression, a change, a word…"

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      header
      ForEach(viewModel.messages) { message in
        bubble(message)
      }
      if viewModel.isAnswering {
        HStack(spacing: 6) {
          ProgressView().controlSize(.small)
          Text("Thinking…")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("ask-thinking")
      }
      if let errorMessage = viewModel.errorMessage {
        Text(errorMessage)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("ask-error")
      }
      input
    }
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Text("Ask about this")
        .font(.subheadline.weight(.semibold))
      Text("— never blocks Send")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .accessibilityIdentifier("ask-thread")
  }

  private func bubble(_ message: AskMessage) -> some View {
    VStack(alignment: message.role == .owner ? .trailing : .leading, spacing: 6) {
      Text(message.text)
        .font(.callout)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(bubbleBackground(message.role))
        .foregroundStyle(message.role == .owner ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
      if let card = message.card {
        saveCardButton(for: message, card: card)
      }
    }
    .frame(
      maxWidth: .infinity,
      alignment: message.role == .owner ? .trailing : .leading
    )
    .accessibilityIdentifier("ask-message-\(message.role == .owner ? "you" : "bex")")
  }

  private func bubbleBackground(_ role: AskMessage.Role) -> some ShapeStyle {
    role == .owner
      ? AnyShapeStyle(Color.accentColor)
      : AnyShapeStyle(.quaternary)
  }

  /// Only rendered when the answer actually offered a drillable pair. A "save this" button
  /// that sometimes makes a nonsense card would be worse than no button — the deck already
  /// has a junk problem worth protecting (`docs/purpose.md`).
  private func saveCardButton(for message: AskMessage, card: AskAnswer.Card) -> some View {
    let isSaved = viewModel.savedCardMessageIDs.contains(message.id)
    return Button {
      Task { await viewModel.saveCard(from: message) }
    } label: {
      Label(
        isSaved ? "Saved as a Study card" : "Save as Study card — “\(card.better)”",
        systemImage: isSaved ? "checkmark.circle.fill" : "plus.circle"
      )
      .font(.caption)
    }
    .buttonStyle(.link)
    .disabled(isSaved)
    .accessibilityIdentifier("ask-save-card")
  }

  private var input: some View {
    HStack(spacing: 8) {
      TextField(prompt, text: $viewModel.question)
        .textFieldStyle(.roundedBorder)
        .font(.callout)
        .onSubmit { viewModel.ask() }
        .accessibilityIdentifier("ask-input")
      Button("Ask") { viewModel.ask() }
        .disabled(!viewModel.canAsk)
        .accessibilityIdentifier("ask-send")
    }
  }
}
