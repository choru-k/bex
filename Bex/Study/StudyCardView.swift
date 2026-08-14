import SwiftUI

extension StudyCardSource {
  /// The one tint token per source (design 3b): where a card came from, said with colour
  /// on the category label alone — never the whole card.
  var tint: Color {
    switch self {
    case .correction: return .blue
    case .pick: return .purple
    case .ask: return .yellow
    }
  }
}

/// How large a card is drawn. Only type scale and padding change between these — the
/// geometry never does, which is the whole point of one template (design 3b).
enum StudyCardScale {
  /// The menu-bar popover, 320pt wide.
  case compact
  /// A card sharing the window with chrome around it.
  case regular
  /// A drill that has taken the window over. Nothing else is on screen, so the sentence
  /// gets the room — the single biggest thing the takeover buys.
  case takeover

  var promptSize: CGFloat {
    switch self {
    case .compact: return 15
    case .regular: return 21
    case .takeover: return 28
    }
  }

  var answerSize: CGFloat {
    switch self {
    case .compact: return 13
    case .regular: return 16
    case .takeover: return 18
    }
  }

  var categorySize: CGFloat {
    switch self {
    case .compact: return 9
    case .regular, .takeover: return 10
    }
  }

  var spacing: CGFloat {
    switch self {
    case .compact: return 10
    case .regular: return 18
    case .takeover: return 26
    }
  }

  /// Width of the answer control. Compact fills the popover; the others stay narrow enough
  /// that the answer reads as one short thing rather than a paragraph field.
  var answerWidth: CGFloat? {
    switch self {
    case .compact: return nil
    case .regular: return 320
    case .takeover: return 360
    }
  }

  var isCompact: Bool { self == .compact }
}

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
  var scale: StudyCardScale = .regular
  /// Trailing half of the category line, e.g. "card 3 of 5". Empty hides it.
  var subtitle: String = ""
  /// Whether the answered state carries the template's own Next/overflow row. The
  /// post-send micro-drill turns this off and supplies its own exits — one card per
  /// send, with a quiet opt-in for more (v3 decision 1).
  var showsAnsweredControls: Bool = true

  /// Autofocuses the typed-answer field the moment a `.typed` card appears so the owner
  /// can start typing with no click. That is the whole reason typed mode exists for
  /// someone who lives in a terminal all day.
  @FocusState private var answerFocused: Bool

  var body: some View {
    VStack(spacing: scale.spacing) {
      categoryLine
      Text(card.promptWithBlank)
        .font(.system(size: scale.promptSize, weight: .medium))
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
      .font(.system(size: scale.categorySize, weight: .semibold))
      .textCase(.uppercase)
      .kerning(0.9)
      .foregroundStyle(card.source.tint)
      .accessibilityIdentifier("study-category")
  }

  @ViewBuilder
  private var answerControl: some View {
    switch card.answerMode {
    case .typed:
      TextField(
        scale.isCompact ? "Type it…" : "Type the correction…",
        text: $viewModel.typedAnswer
      )
      .textFieldStyle(.roundedBorder)
      .font(.system(size: scale.answerSize))
      .multilineTextAlignment(.leading)
      .frame(maxWidth: scale.answerWidth ?? .infinity)
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
      .frame(maxWidth: scale.answerWidth ?? .infinity)
    }
  }

  /// The answer, its verdict, and the key that moves on — the three things worth showing
  /// once a card is graded, in one row so a compact popover does not have to grow.
  private var revealed: some View {
    VStack(spacing: scale.isCompact ? 6 : 10) {
      HStack(spacing: 8) {
        Text(submittedAnswer)
          .font(.system(size: scale.answerSize, weight: .medium))
          .lineLimit(1)
          .truncationMode(.tail)
        Spacer(minLength: 8)
        Label(
          viewModel.lastAnswerWasCorrect ? "Correct" : "It's “\(card.correct)”",
          systemImage: viewModel.lastAnswerWasCorrect
            ? "checkmark.circle.fill" : "xmark.circle.fill"
        )
        .labelStyle(.titleAndIcon)
        .font(.system(size: scale.isCompact ? 12 : 14, weight: .medium))
        .foregroundStyle(viewModel.lastAnswerWasCorrect ? Color.green : Color.red)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, scale.isCompact ? 7 : 9)
      .background(
        RoundedRectangle(cornerRadius: 8)
          .strokeBorder(viewModel.lastAnswerWasCorrect ? Color.green : Color.red, lineWidth: 1.5)
      )
      .frame(maxWidth: scale.answerWidth ?? .infinity)
      .accessibilityIdentifier("study-feedback")

      if !card.reason.isEmpty {
        Text(card.reason)
          .font(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 420)
          .accessibilityIdentifier("study-reason")
      }

      if showsAnsweredControls {
        answeredControls
      }
    }
  }

  /// Move on — and, only where the question is real, say this card should never have
  /// existed.
  ///
  /// The paired Keep/Toss came off every card (v2, design turn 4): without agent-proposed
  /// cards there is no provenance to judge on every answer, and a permanent quality
  /// verdict next to the happy-path key overweights it. "Toss — not a gap" stays a
  /// visible control exactly once — a card's first-ever exposure, where junk is caught —
  /// and lives in the per-card overflow (⌘⌫) forever after. The deck is built
  /// automatically from logged corrections, and `docs/purpose.md` names a deck of junk
  /// cards as worse than a thin one; this is still where the owner draws that line.
  private var answeredControls: some View {
    HStack(spacing: 10) {
      Button("Next ⏎") {
        viewModel.advance()
      }
      .keyboardShortcut(.defaultAction)
      .accessibilityIdentifier("study-next")

      if viewModel.currentCardIsFirstExposure {
        Button("Toss — not a gap") {
          Task { await viewModel.toss() }
        }
        .buttonStyle(.link)
        .accessibilityIdentifier("study-toss")
      }

      Menu {
        Button("Toss — not a gap") {
          Task { await viewModel.toss() }
        }
        .keyboardShortcut(.delete, modifiers: .command)
        .accessibilityIdentifier("study-toss-overflow")
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .accessibilityLabel("Card actions")
      .accessibilityIdentifier("study-card-overflow")
    }
    .controlSize(scale.isCompact ? .small : .regular)
    .font(scale.isCompact ? .caption : .body)
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
      .padding(.vertical, scale.isCompact ? 6 : 9)
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

/// The current card with the rest of the stack peeking out behind it.
///
/// Design 1b's card pile. It is doing one job: showing that the deck is *finite* without
/// putting a number on it. The dots below say how far along the session is; this says there
/// is a small pile, not a stream.
struct StudyCardStack<Content: View>: View {
  /// Cards left including the one on top. Two layers is the cap — a third reads as texture
  /// rather than as "there are more".
  let remaining: Int
  var cornerRadius: CGFloat = 14
  @ViewBuilder var content: () -> Content

  var body: some View {
    // The layers live in a `.background`, not beside the content in a `ZStack`.
    // A `RoundedRectangle` is infinitely flexible, so as a ZStack sibling it grew to fill
    // whatever space was offered and the "pile" ballooned to the size of the pane instead of
    // sitting behind the card. In a background it is handed the content's own size, which is
    // the only size that makes it read as the same card repeated.
    content()
      .padding(28)
      .background(alignment: .center) {
        ZStack {
          if remaining > 2 {
            layer.offset(x: 14, y: 14).opacity(0.5)
          }
          if remaining > 1 {
            layer.offset(x: 7, y: 7).opacity(0.75)
          }
          RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color(nsColor: .controlBackgroundColor))
            .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
            .overlay(
              RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            )
        }
      }
  }

  private var layer: some View {
    RoundedRectangle(cornerRadius: cornerRadius)
      .fill(.quaternary)
      .overlay(
        RoundedRectangle(cornerRadius: cornerRadius)
          .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
      )
  }
}

/// Fits the session dashes to a bounded host without changing their count.
///
/// The menu-bar session can contain 20 cards. At the preferred 20pt dash width plus
/// spacing, that row is 476pt wide and forces the entire 320pt popover's content off-center.
/// Window-hosted drills leave `maximumWidth` unset and retain their larger dashes.
enum StudyPileDotsLayout {
  static let preferredSpacing: CGFloat = 4
  static let minimumVisibleDotWidth: CGFloat = 2

  struct Metrics: Equatable {
    let dotWidth: CGFloat
    let spacing: CGFloat

    func width(for total: Int) -> CGFloat {
      guard total > 0 else { return 0 }
      return CGFloat(total) * dotWidth + CGFloat(max(total - 1, 0)) * spacing
    }
  }

  static func metrics(
    total: Int,
    preferredDotWidth: CGFloat,
    maximumWidth: CGFloat?
  ) -> Metrics {
    guard total > 0, let maximumWidth else {
      return Metrics(dotWidth: preferredDotWidth, spacing: preferredSpacing)
    }

    let availableWidth = max(0, maximumWidth)
    let count = CGFloat(total)
    guard total > 1 else {
      return Metrics(dotWidth: min(preferredDotWidth, availableWidth), spacing: 0)
    }

    // Preserve a visible mark before preserving the preferred gap. If even 2pt per card
    // cannot fit, the gap reaches zero and every card still receives an equal share.
    let minimumDotWidth = min(minimumVisibleDotWidth, availableWidth / count)
    let maximumSpacing = max(
      0,
      (availableWidth - minimumDotWidth * count) / CGFloat(total - 1)
    )
    let spacing = min(preferredSpacing, maximumSpacing)
    let dotWidth = min(
      preferredDotWidth,
      max(0, (availableWidth - spacing * CGFloat(total - 1)) / count)
    )
    return Metrics(dotWidth: dotWidth, spacing: spacing)
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
  /// Optional host constraint. When set, dash width and then spacing contract so the
  /// indicator cannot increase its parent's ideal width beyond this value.
  var maximumWidth: CGFloat? = nil

  var body: some View {
    let metrics = StudyPileDotsLayout.metrics(
      total: total,
      preferredDotWidth: dotWidth,
      maximumWidth: maximumWidth
    )
    HStack(spacing: metrics.spacing) {
      ForEach(0..<max(total, 0), id: \.self) { index in
        Capsule()
          .fill(fill(for: index))
          .frame(width: metrics.dotWidth, height: dotHeight)
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
