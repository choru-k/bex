import SwiftUI

/// Geometry for the card's final-message editor: sized to its content, never less than a
/// few lines, never more than its share of the panel (v3 decision 4). Pure, so the clamp
/// is unit-testable without a view.
enum ReviewCardLayout {
  /// Roughly three lines of body text plus the editor's insets — enough to read a short
  /// message and see that it is editable, without a one-liner floating in empty space.
  static let minimumEditorHeight: CGFloat = 64
  /// The editor's ceiling as a share of the panel's content height; past it, it scrolls.
  static let maximumEditorFraction: CGFloat = 0.6

  static func editorHeight(measuredText: CGFloat, availableHeight: CGFloat) -> CGFloat {
    let maximum = max(minimumEditorHeight, availableHeight * maximumEditorFraction)
    return min(max(measuredText, minimumEditorHeight), maximum)
  }
}

private struct ReviewCardEditorTextHeight: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

/// The one review card: editable final message, one-line redline, unranked alternatives,
/// ask thread, and a single collapsed Details disclosure.
///
/// Extracted from Prompt Gate so Quick Check and Fix & Send are literally the same card
/// (design 4a) — hands that hit ⇧⌘G all day never re-learn a layout. Everything that
/// differs between the two surfaces stays with the host: the target/provenance header
/// rows, the footer, and anything delivery-shaped arrives through `detailsExtra`.
///
/// `idPrefix` keeps each surface's existing accessibility identifiers intact
/// ("prompt-gate-corrected" vs "quick-check-corrected") — the ids are contract with the
/// UI tests and with anyone driving the app through accessibility.
struct ReviewCardView<DetailsExtra: View>: View {
  let idPrefix: String
  let review: PromptGateReview
  /// Two-way binding into the host's canonical corrected text (the host owns edits so
  /// its checkpoint/discard logic keeps working unchanged).
  let corrected: Binding<String>
  /// The panel's content height — the editor sizes itself to its text within
  /// `ReviewCardLayout`'s bounds of it.
  let availableHeight: CGFloat
  let canEditCorrection: Bool
  /// Full accessibility label for the final-message editor, e.g.
  /// "Final message for Codex, editable".
  let correctedFieldLabel: String
  let errorMessage: String?
  let alternatives: [PromptGateAlternative]
  let alternativesPhrase: String
  let pickedAlternativeID: String?
  let onChooseAlternative: (PromptGateAlternative) -> Void
  /// The true statement of what the primary key does to unpicked alternatives, worded by
  /// the host ("⌘⏎ sends as-is" / "⏎ copies as-is") — a shared string lied on one surface.
  let primaryActionHint: String
  /// e.g. "Subject–verb agreement, Spelling" beside the redline. May be empty.
  let changeCategorySummary: String
  let accessibleDiffSummary: String
  /// The collapsed Details label, host-worded ("… · nothing sent yet").
  let detailsSummary: String
  /// Owned by the host so it can reset the disclosure when a new session begins.
  @Binding var isDetailsExpanded: Bool
  @ObservedObject var askThread: AskThreadViewModel
  var keyboardFocus: FocusState<PromptGateKeyboardFocus?>.Binding
  var accessibilityFocus: AccessibilityFocusState<PromptGateAccessibilityFocus?>.Binding
  /// Extra reference sections inside Details, after the original message and grammar
  /// notes — Fix & Send puts its delivery guidance here; Quick Check has nothing.
  @ViewBuilder let detailsExtra: () -> DetailsExtra

  /// What the corrected text measures at the editor's width, reported by the invisible
  /// mirror under the editor. Drives the auto-sizing height.
  @State private var measuredTextHeight: CGFloat = 0

  var body: some View {
    let changes = DiffChange.make(from: review.diff)
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Final message · editable")
          .font(.caption.weight(.semibold))
          .textCase(.uppercase)
          .foregroundStyle(.secondary)
          .accessibilityAddTraits(.isHeader)
          .accessibilityFocused(accessibilityFocus, equals: .finalMessageHeading)
          .accessibilityIdentifier("\(idPrefix)-final-message-heading")
        correctedEditor
        // The redline sits directly under the message it describes, one line, so "what
        // did it change" is answered without reading a second panel.
        if changes.isEmpty {
          Text("No grammar changes. You can still edit the final message.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("\(idPrefix)-no-changes")
        } else {
          DiffRedline(changes: changes, categorySummary: changeCategorySummary)
            .accessibilityHidden(true)
            .overlay {
              DiffSummaryAccessibilityElement(
                changeCount: changes.count,
                summary: accessibleDiffSummary,
                identifier: "\(idPrefix)-diff-summary"
              )
            }
        }
      }

      error

      alternativesPanel

      AskThreadView(viewModel: askThread)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        // Keyed on the original rather than the corrected text: editing the final message
        // must not throw away a question the owner already asked about it.
        .onAppear { askThread.reset(context: review.original) }
        .onChange(of: review.original) { original in
          askThread.reset(context: original)
        }

      details
    }
  }

  private var correctedEditor: some View {
    TextEditor(text: corrected)
      .font(.body)
      .padding(5)
      .frame(
        height: ReviewCardLayout.editorHeight(
          measuredText: measuredTextHeight,
          availableHeight: availableHeight
        )
      )
      .background(Color(nsColor: .textBackgroundColor))
      .clipShape(RoundedRectangle(cornerRadius: 7))
      .overlay {
        RoundedRectangle(cornerRadius: 7)
          .stroke(Color(nsColor: .separatorColor))
      }
      .overlay(alignment: .topLeading) { editorSizingMirror }
      .onPreferenceChange(ReviewCardEditorTextHeight.self) { measuredTextHeight = $0 }
      .disabled(!canEditCorrection)
      .focused(keyboardFocus, equals: .correctedEditor)
      .accessibilityLabel(correctedFieldLabel)
      .accessibilityIdentifier("\(idPrefix)-corrected")
  }

  /// An invisible copy of the corrected text at the editor's own width, so the editor's
  /// height can follow its content — SwiftUI's `TextEditor` will not report one itself.
  /// The zero-width space makes a trailing newline count as a line.
  // ponytail: the insets approximate the editor's; a few points off only moves the
  // moment scrolling starts, never the text itself.
  private var editorSizingMirror: some View {
    Text(corrected.wrappedValue + "\u{200B}")
      .font(.body)
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .background(
        GeometryReader { proxy in
          Color.clear.preference(
            key: ReviewCardEditorTextHeight.self,
            value: proxy.size.height
          )
        }
      )
      .opacity(0)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }

  @ViewBuilder
  private var error: some View {
    if let errorMessage {
      Label(errorMessage, systemImage: "exclamationmark.circle")
        .font(.caption)
        .foregroundStyle(.red)
        .textSelection(.enabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(errorMessage)
        .accessibilityValue(errorMessage)
        .accessibilityAddTraits(.isHeader)
        .accessibilityFocused(accessibilityFocus, equals: .errorHeading)
        .accessibilityIdentifier("\(idPrefix)-error")
    }
  }

  /// The unranked alternatives, given the most visual weight on the card.
  ///
  /// This used to be a grey bullet list under the diff, which had it exactly backwards:
  /// `docs/purpose.md` says correcting and teaching are separate jobs and *teaching is the
  /// higher priority*, and this panel is the only teaching on the card. The grammar fixes
  /// are already applied and need no decision; this is the one thing asking the owner to
  /// think.
  @ViewBuilder
  private var alternativesPanel: some View {
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
          if !alternativesPhrase.isEmpty {
            Text("for “\(alternativesPhrase)”")
              .font(.caption)
              .foregroundStyle(.tertiary)
          }
        }
        .accessibilityIdentifier("\(idPrefix)-better-expression")

        ForEach(Array(alternatives.enumerated()), id: \.element.id) { index, alternative in
          alternativeRow(alternative, index: index)
        }

        Text("Unranked — pick what you would actually say, or skip; \(primaryActionHint).")
          .font(.caption)
          .foregroundStyle(.tertiary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("\(idPrefix)-alternatives-unranked-note")
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

  private func alternativeRow(_ alternative: PromptGateAlternative, index: Int) -> some View {
    let isPicked = pickedAlternativeID == alternative.id
    return Button {
      onChooseAlternative(alternative)
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
        if index < 9 {
          Text("⌘\(index + 1)")
            .font(.caption.monospaced())
            .foregroundStyle(.tertiary)
        }
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
    // ⌘-digit rather than the drill's bare digits: the corrected editor usually holds
    // focus on this card, and an unmodified key would be swallowed as typing. Without
    // SOME key the pick is the only mouse-required act in a keyboard app — and the pick
    // is the one measured expression signal (docs/purpose.md).
    .keyboardShortcut(Self.pickKey(for: index), modifiers: .command)
    .accessibilityAddTraits(isPicked ? [.isSelected] : [])
    .accessibilityIdentifier("\(idPrefix)-alternative-\(alternative.id)")
  }

  /// Digit key for the nth alternative, mirroring `StudyCardView.choiceKey`. Falls back
  /// to a harmless unmatched key past the 9th — the prompt contract offers 2–3.
  private static func pickKey(for index: Int) -> KeyEquivalent {
    guard index < 9, let digit = "\(index + 1)".first else { return KeyEquivalent("\u{0}") }
    return KeyEquivalent(digit)
  }

  /// Everything that used to have its own heading: the original message, the model's
  /// grammar notes, and whatever the host adds through `detailsExtra`.
  ///
  /// One disclosure instead of four sections. None of it is a decision — it is all there
  /// to be checked when something looks wrong, and four open panels of reference material
  /// was what pushed the actual choice off the bottom of the sheet.
  private var details: some View {
    DisclosureGroup(isExpanded: $isDetailsExpanded) {
      VStack(alignment: .leading, spacing: 12) {
        ReviewCardDetailSection(title: "Original message") {
          Text(review.original)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Original message, read only")
            .accessibilityValue(review.original)
            .accessibilityIdentifier("\(idPrefix)-original")
        }

        let grammarNotes = LearningAggregator.explanationWithoutConsider(
          from: review.explanation
        )
        if !grammarNotes.isEmpty {
          ReviewCardDetailSection(title: "Grammar notes") {
            VStack(alignment: .leading, spacing: 6) {
              Text(grammarNotes)
                .textSelection(.enabled)
                .accessibilityIdentifier("\(idPrefix)-explanation")
              if review.hasHumanEdits {
                Text(
                  "This AI note describes the original suggestion and may not reflect your edits."
                )
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("\(idPrefix)-ai-note-stale")
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
        }

        detailsExtra()
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
      .accessibilityIdentifier("\(idPrefix)-details-disclosure")
    }
  }
}

/// A reference section inside the Details disclosure, styled like the card's own
/// sections. Public shape for hosts building their `detailsExtra`.
struct ReviewCardDetailSection<Content: View>: View {
  let title: String
  @ViewBuilder let content: () -> Content

  var body: some View {
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
}
