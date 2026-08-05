import SwiftUI

/// Study Mode's drill window: one multiple-choice cloze card at a time, drawn from the
/// due queue `StudyViewModel` assembles from the learning log. Visual language mirrors
/// `LearningView` (same loading/empty-state shape, same `accessibilityIdentifier`
/// naming convention of `"study-*"` mirroring `"learning-*"`).
struct StudyView: View {
  @ObservedObject var viewModel: StudyViewModel
  /// Autofocuses the typed-answer field the moment a `.typed` card appears (see
  /// `drill(for:)`'s `.onChange(of:)` below) so the owner can start typing immediately
  /// — no click required. That's the whole point of typed mode for someone who lives
  /// in a terminal all day.
  @FocusState private var answerFieldFocused: Bool

  var body: some View {
    content
      .task {
        await viewModel.load()
      }
  }

  @ViewBuilder
  private var content: some View {
    if viewModel.isLoading {
      ProgressView("Loading Study…")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("study-loading")
    } else if viewModel.isEmpty {
      emptyState
    } else if viewModel.isFinished {
      finishedState
    } else if let card = viewModel.currentCard {
      drill(for: card)
    }
  }

  private func drill(for card: StudyCard) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("\(min(viewModel.completedCount + 1, viewModel.sessionTotal)) of \(viewModel.sessionTotal)")
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("study-progress")

      Text(card.displayCategory)
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
        .accessibilityIdentifier("study-category")

      Text(card.promptWithBlank)
        .font(.title3.weight(.medium))
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("study-prompt")

      if card.answerMode == .typed {
        typedAnswerField(card: card)
      } else {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(Array(viewModel.choices.enumerated()), id: \.offset) { index, choice in
            choiceButton(choice: choice, index: index, card: card)
          }
        }
      }
      // The owner works in a terminal all day; a drill he can only answer by reaching
      // for the mouse (or, for typed cards, that doesn't already have the cursor in the
      // field) is a drill he will stop doing.
      Text(keyHint(card: card))
        .font(.caption)
        .foregroundStyle(.tertiary)
        .accessibilityIdentifier("study-key-hint")

      if viewModel.answerRevealed {
        feedback(for: card)
        Button("Next") {
          viewModel.advance()
        }
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("study-next")
      }

      Spacer()
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    // Focus the typed-answer field the instant a new card is presented (including the
    // very first one) so typing can start with no click. Keyed on `card.id` rather than
    // a plain `.onAppear` because `drill(for:)` is re-invoked for every card without the
    // enclosing view actually disappearing and reappearing.
    .onChange(of: card.id) { _ in
      answerFieldFocused = card.answerMode == .typed
    }
    .onAppear {
      answerFieldFocused = card.answerMode == .typed
    }
  }

  private func typedAnswerField(card: StudyCard) -> some View {
    TextField("Type the correction…", text: $viewModel.typedAnswer)
      .textFieldStyle(.roundedBorder)
      .font(.title3)
      .disabled(viewModel.answerRevealed)
      .focused($answerFieldFocused)
      .onSubmit {
        Task { await viewModel.submitTypedAnswer() }
      }
      .accessibilityIdentifier("study-answer-field")
  }

  /// Per-mode key hint, and per-reveal-state within typed mode: before an answer is
  /// submitted, Return checks it; after, Return is bound to "Next" instead (via
  /// `.keyboardShortcut(.defaultAction)` on that button), so the same key never both
  /// submits and advances in one press.
  private func keyHint(card: StudyCard) -> String {
    switch card.answerMode {
    case .typed:
      return viewModel.answerRevealed
        ? "Return for the next card."
        : "Type your answer, Return to check."
    case .choices:
      return viewModel.choices.count > 1
        ? "Press 1-\(viewModel.choices.count) to answer, Return for the next card."
        : "Return for the next card."
    }
  }

  @ViewBuilder
  private func choiceButton(choice: String, index: Int, card: StudyCard) -> some View {
    Button {
      Task { await viewModel.select(choice) }
    } label: {
      HStack {
        Text(choice)
        Spacer()
        if viewModel.answerRevealed && choice == card.correct {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.green)
        } else if viewModel.answerRevealed && choice == viewModel.selectedChoice {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.red)
        }
      }
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(choiceBackground(choice: choice, card: card), in: RoundedRectangle(cornerRadius: 6))
    }
    .buttonStyle(.plain)
    .disabled(viewModel.answerRevealed)
    // `.buttonStyle(.plain)` buttons aren't Tab-focusable on macOS unless Full Keyboard
    // Access is enabled, so without an explicit digit shortcut the only way to answer is
    // the mouse. Bound with no modifier so answering is a single keystroke.
    .keyboardShortcut(choiceKey(for: index), modifiers: [])
    .accessibilityIdentifier("study-choice-\(index)")
  }

  /// Digit key for the nth choice ("1" for the first, and so on). Falls back to a
  /// harmless unmatched key past the 9th choice — a card never has that many, since
  /// `StudyCardBuilder` caps a card at the correct answer, the original mistake, and two
  /// distractors.
  private func choiceKey(for index: Int) -> KeyEquivalent {
    guard index < 9, let digit = "\(index + 1)".first else { return KeyEquivalent("\u{0}") }
    return KeyEquivalent(digit)
  }

  /// Neutral background while unanswered; a soft green/red tint once revealed,
  /// keyed to correctness rather than a hardcoded hex so both appearances stay legible.
  private func choiceBackground(choice: String, card: StudyCard) -> AnyShapeStyle {
    guard viewModel.answerRevealed else { return AnyShapeStyle(.quaternary) }
    if choice == card.correct {
      return AnyShapeStyle(Color.green.opacity(0.15))
    } else if choice == viewModel.selectedChoice {
      return AnyShapeStyle(Color.red.opacity(0.15))
    }
    return AnyShapeStyle(.quaternary)
  }

  /// Shows correct/incorrect, plus context on what the user actually wrote. Reads
  /// `viewModel.lastAnswerWasCorrect` rather than re-deriving correctness here — for
  /// choice cards that could still be `selectedChoice == card.correct`, but typed cards
  /// have no such equality to reuse (they're graded through `StudyAnswerCheck`), so both
  /// modes read the one flag the view model already computed.
  private func feedback(for card: StudyCard) -> some View {
    let isCorrect = viewModel.lastAnswerWasCorrect
    return VStack(alignment: .leading, spacing: 4) {
      Text(isCorrect ? "Correct!" : "Not quite — the answer is \"\(card.correct)\".")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(isCorrect ? .green : .red)
      if card.answerMode == .typed {
        if !isCorrect {
          Text("You typed: \(viewModel.typedAnswer)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      } else {
        Text("You wrote: \(card.wrong)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .accessibilityIdentifier("study-feedback")
  }

  private var emptyState: some View {
    VStack(spacing: 10) {
      Image(systemName: "checkmark.seal")
        .font(.largeTitle)
        .foregroundStyle(.secondary)
      Text("Nothing due right now — come back tomorrow.")
        .font(.headline)
        .multilineTextAlignment(.center)
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityIdentifier("study-empty")
  }

  private var finishedState: some View {
    VStack(spacing: 10) {
      Image(systemName: "party.popper")
        .font(.largeTitle)
        .foregroundStyle(.secondary)
      Text("Done — \(viewModel.completedCount) reviewed")
        .font(.headline)
        .accessibilityIdentifier("study-done-count")
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityIdentifier("study-done")
  }
}
