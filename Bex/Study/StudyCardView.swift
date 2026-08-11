import SwiftUI

/// The single drill-card template, shared by every surface that presents a card.
///
/// Design 3b's rule, and the reason this is one view rather than one per surface: every
/// card type gets the same geometry — category label on top, the sentence in the middle,
/// one answer control below — so only the middle ever changes. At card 40 of a long week
/// the owner's hands should not have to re-learn where the answer goes.
///
/// Chrome is deliberately not here. The pile dots, the session counter and the window
/// furniture belong to whichever surface is hosting the card; this view is the card.
struct StudyCardView: View {
  @ObservedObject var viewModel: StudyViewModel
  let card: StudyCard
  /// Popover-sized rather than window-sized. Changes type scale and padding only — the
  /// geometry above stays identical in both, which is the whole point of one template.
  var isCompact: Bool = false
  /// Trailing half of the category line, e.g. "card 3 of 5". Empty hides it.
  var subtitle: String = ""

  /// Autofocuses the typed-answer field the moment a `.typed` card appears so the owner
  /// can start typing with no click. That is the whole reason typed mode exists for
  /// someone who lives in a terminal all day.
  @FocusState private var answerFocused: Bool

  var body: some View {
    VStack(spacing: isCompact ? 10 : 18) {
      categoryLine
      Text(card.promptWithBlank)
        .font(.system(size: isCompact ? 15 : 21, weight: .medium))
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("study-prompt")

      if viewModel.answerRevealed {
        revealed
      } else {
        answerControl
      }
    }
    .frame(maxWidth: .infinity)
    .onChange(of: card.id) { _ in
      answerFocused = card.answerMode == .typed
    }
    .onAppear {
      answerFocused = card.answerMode == .typed
    }
  }

  // MARK: - Card parts

  private var categoryLine: some View {
    Text(subtitle.isEmpty ? card.displayCategory : "\(card.displayCategory) · \(subtitle)")
      .font(.system(size: isCompact ? 9 : 10, weight: .semibold))
      .textCase(.uppercase)
      .kerning(0.9)
      .foregroundStyle(.tint)
      .accessibilityIdentifier("study-category")
  }

  @ViewBuilder
  private var answerControl: some View {
    switch card.answerMode {
    case .typed:
      TextField(isCompact ? "Type it…" : "Type the correction…", text: $viewModel.typedAnswer)
        .textFieldStyle(.roundedBorder)
        .font(.system(size: isCompact ? 13 : 16))
        .multilineTextAlignment(.leading)
        .frame(maxWidth: isCompact ? .infinity : 320)
        .focused($answerFocused)
        .onSubmit {
          Task { await viewModel.submitTypedAnswer() }
        }
        .accessibilityIdentifier("study-answer-field")
    case .choices:
      VStack(spacing: 6) {
        ForEach(Array(viewModel.choices.enumerated()), id: \.offset) { index, choice in
          choiceButton(choice: choice, index: index)
        }
      }
      .frame(maxWidth: isCompact ? .infinity : 320)
    }
  }

  /// The answer, its verdict, and the key that moves on — the three things worth showing
  /// once a card is graded, in one row so a compact popover does not have to grow.
  private var revealed: some View {
    VStack(spacing: isCompact ? 6 : 10) {
      HStack(spacing: 8) {
        Text(submittedAnswer)
          .font(.system(size: isCompact ? 13 : 16, weight: .medium))
          .lineLimit(1)
          .truncationMode(.tail)
        Spacer(minLength: 8)
        Label(
          viewModel.lastAnswerWasCorrect ? "Correct" : "It's “\(card.correct)”",
          systemImage: viewModel.lastAnswerWasCorrect ? "checkmark.circle.fill" : "xmark.circle.fill"
        )
        .labelStyle(.titleAndIcon)
        .font(.system(size: isCompact ? 12 : 14, weight: .medium))
        .foregroundStyle(viewModel.lastAnswerWasCorrect ? Color.green : Color.red)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, isCompact ? 7 : 9)
      .background(
        RoundedRectangle(cornerRadius: 8)
          .strokeBorder(viewModel.lastAnswerWasCorrect ? Color.green : Color.red, lineWidth: 1.5)
      )
      .frame(maxWidth: isCompact ? .infinity : 320)
      .accessibilityIdentifier("study-feedback")

      if !card.reason.isEmpty {
        Text(card.reason)
          .font(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .accessibilityIdentifier("study-reason")
      }

      Button("Next ⏎") {
        viewModel.advance()
      }
      .keyboardShortcut(.defaultAction)
      .controlSize(isCompact ? .small : .regular)
      .accessibilityIdentifier("study-next")
    }
  }

  /// What the owner actually answered, in whichever way this card takes answers.
  private var submittedAnswer: String {
    switch card.answerMode {
    case .typed: return viewModel.typedAnswer
    case .choices: return viewModel.selectedChoice ?? ""
    }
  }

  private func choiceButton(choice: String, index: Int) -> some View {
    Button {
      Task { await viewModel.select(choice) }
    } label: {
      HStack {
        Text(choice)
        Spacer()
        Text("\(index + 1)")
          .font(.caption.monospaced())
          .foregroundStyle(.tertiary)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, isCompact ? 6 : 9)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
    .buttonStyle(.plain)
    // `.buttonStyle(.plain)` buttons aren't Tab-focusable on macOS unless Full Keyboard
    // Access is enabled, so without an explicit digit shortcut the only way to answer is
    // the mouse. Bound with no modifier so answering is a single keystroke.
    .keyboardShortcut(Self.choiceKey(for: index), modifiers: [])
    .accessibilityIdentifier("study-choice-\(index)")
  }

  /// Digit key for the nth choice ("1" for the first, and so on). Falls back to a
  /// harmless unmatched key past the 9th choice — a card never has that many, since
  /// `StudyCardBuilder` caps a card at the correct answer, the original mistake, and two
  /// distractors.
  private static func choiceKey(for index: Int) -> KeyEquivalent {
    guard index < 9, let digit = "\(index + 1)".first else { return KeyEquivalent("\u{0}") }
    return KeyEquivalent(digit)
  }
}

/// The session's remaining stack, one dash per card.
///
/// Replaces the "3 of 5" readout as the primary progress cue for the same reason the hub
/// header shows minutes rather than a count: five dashes with two filled is a glanceable,
/// obviously-finite amount of work, where a fraction invites arithmetic. The text form is
/// kept for VoiceOver, which cannot glance.
struct StudyPileDots: View {
  let total: Int
  let completed: Int
  var dotWidth: CGFloat = 24
  var dotHeight: CGFloat = 4

  var body: some View {
    HStack(spacing: 4) {
      ForEach(0..<max(total, 0), id: \.self) { index in
        Capsule()
          .fill(fill(for: index))
          .frame(width: dotWidth, height: dotHeight)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(completed) of \(total) cards cleared")
    .accessibilityIdentifier("study-pile-dots")
  }

  private func fill(for index: Int) -> AnyShapeStyle {
    if index < completed { return AnyShapeStyle(Color.green) }
    if index == completed { return AnyShapeStyle(.tint) }
    return AnyShapeStyle(.quaternary)
  }
}
