import SwiftUI

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
  let editorHeight: CGFloat
  let canEditCorrection: Bool
  /// Full accessibility label for the final-message editor, e.g.
  /// "Final message for Codex, editable".
  let correctedFieldLabel: String
  let errorMessage: String?
  let alternatives: [PromptGateAlternative]
  let alternativesPhrase: String
  let pickedAlternativeID: String?
  let onChooseAlternative: (PromptGateAlternative) -> Void
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
                summary: accessibleDiffSummary
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
      .padding(5)
      .frame(height: editorHeight)
      .background(Color(nsColor: .textBackgroundColor))
      .clipShape(RoundedRectangle(cornerRadius: 7))
      .overlay {
        RoundedRectangle(cornerRadius: 7)
          .stroke(Color(nsColor: .separatorColor))
      }
      .disabled(!canEditCorrection)
      .focused(keyboardFocus, equals: .correctedEditor)
      .accessibilityLabel(correctedFieldLabel)
      .accessibilityIdentifier("\(idPrefix)-corrected")
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

        ForEach(alternatives) { alternative in
          alternativeRow(alternative)
        }

        Text("Unranked — pick what you would actually say, or skip; ⌘⏎ sends as-is.")
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

  private func alternativeRow(_ alternative: PromptGateAlternative) -> some View {
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
    .accessibilityIdentifier("\(idPrefix)-alternative-\(alternative.id)")
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
