import SwiftUI

/// Stable `ForEach` identity for one ISO week — `WeeklyRate` itself is `Equatable` but
/// not `Hashable`, and (year, week) is already unique per `LearningMetrics.weeklyRates`.
extension WeeklyRate {
  fileprivate var weekIdentifier: String { "\(yearForWeekOfYear)-\(weekOfYear)" }
}

/// Learn: the deck first, everything else behind a tab.
///
/// This is the merge the redesign asks for. Learning and Study used to be two separate
/// windows, which put the numbers *about* studying on equal footing with studying itself
/// — and the numbers are not the point. Here the drill is the landing tab and the stats
/// are one click away, so opening Learn means "answer a card", not "read a report".
struct LearnView: View {
  enum Tab: String, CaseIterable, Identifiable, Hashable {
    case deck
    case suggestions
    case progress

    var id: String { rawValue }

    var title: String {
      switch self {
      case .deck: return "Deck"
      case .suggestions: return "Suggestions"
      case .progress: return "Progress"
      }
    }
  }

  /// Owns the takeover flag and the sidebar state, both of which a drill has to change.
  @ObservedObject var model: MainWindowModel
  /// Observed explicitly rather than reached through `model`: SwiftUI only invalidates on
  /// the objects a view actually observes, and these two are what change while drilling.
  @ObservedObject var study: StudyViewModel
  @ObservedObject var learning: LearningViewModel
  /// Questions asked about the card on screen. Owned by the window so a question in flight
  /// survives the drill re-rendering around it.
  @ObservedObject var askThread: AskThreadViewModel
  @State private var tab: Tab = .deck

  var body: some View {
    Group {
      if model.isDrillTakeover, let card = study.currentCard {
        StudyTakeoverView(viewModel: study, askThread: askThread, card: card, end: endDrill)
      } else {
        chrome
      }
    }
    .task {
      await learning.load()
    }
    .task {
      await study.loadIfNeeded()
      // Opening Learn with cards due drops straight into the drill. `docs/purpose.md`
      // records why: the first version was a read-only surface the owner did not open, and
      // a surface nobody opens teaches nothing. Once they have pressed Esc,
      // `hasLeftDrill` keeps Bex from putting them back.
      startDrillIfDue()
    }
  }

  private var chrome: some View {
    VStack(spacing: 0) {
      header
      Divider()
      page
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  // MARK: - Takeover

  private func startDrillIfDue() {
    guard tab == .deck, !model.hasLeftDrill, study.currentCard != nil else { return }
    startDrill()
  }

  private func startDrill() {
    guard study.currentCard != nil else { return }
    model.isDrillTakeover = true
    model.columnVisibility = .detailOnly
  }

  private func endDrill() {
    model.hasLeftDrill = true
    model.isDrillTakeover = false
    model.columnVisibility = .all
  }

  // MARK: - Header

  private var header: some View {
    HStack {
      Picker("", selection: $tab) {
        ForEach(Tab.allCases) { tab in
          Text(label(for: tab)).tag(tab)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .fixedSize()
      .accessibilityIdentifier("learn-tabs")

      Spacer()

      if learning.medianSentenceLength > 0 {
        Text("typical sentence: \(LearnFormat.number(learning.medianSentenceLength)) words")
          .font(.caption)
          .foregroundStyle(.tertiary)
          .accessibilityIdentifier("learn-typical-sentence")
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
  }

  /// The Suggestions tab carries the number still *waiting for a pick*, not the number
  /// seen. The design mocked the total there, but non-negotiable 6 requires every count
  /// Bex shows to be able to reach zero — a running total of everything ever suggested
  /// never can, and a badge that only grows becomes wallpaper.
  private func label(for tab: Tab) -> String {
    guard tab == .suggestions else { return tab.title }
    let waiting = learning.suggestions.filter { !$0.isTapped }.count
    return waiting > 0 ? "\(tab.title) · \(waiting)" : tab.title
  }

  @ViewBuilder
  private var page: some View {
    switch tab {
    case .deck:
      StudyDeckView(viewModel: study, start: startDrill)
    case .suggestions:
      LearnSuggestionsView(viewModel: learning)
    case .progress:
      LearnProgressView(viewModel: learning)
    }
  }
}

// MARK: - Suggestions

/// The unpicked expression alternatives, grouped by the phrase they were offered for.
///
/// Grouping is the whole design change here. A flat list of `"phrase" → "alternative"`
/// lines makes two alternatives for the same phrase look like two unrelated items, when
/// they are in fact one choice with two answers — and non-negotiable 5 says the choice is
/// the point. Showing the phrase once with its alternatives side by side is what makes it
/// read as a question.
struct LearnSuggestionsView: View {
  @ObservedObject var viewModel: LearningViewModel

  /// One phrase and every alternative offered for it, in the order the log produced them.
  private struct Group: Identifiable {
    let phrase: String
    let alternatives: [ConsiderSuggestion]
    var id: String { phrase }
    var isAnswered: Bool { alternatives.contains(where: \.isTapped) }
  }

  private var groups: [Group] {
    var order: [String] = []
    var byPhrase: [String: [ConsiderSuggestion]] = [:]
    for suggestion in viewModel.suggestions {
      if byPhrase[suggestion.phrase] == nil { order.append(suggestion.phrase) }
      byPhrase[suggestion.phrase, default: []].append(suggestion)
    }
    return order.map { Group(phrase: $0, alternatives: byPhrase[$0] ?? []) }
  }

  var body: some View {
    let groups = groups
    let waiting = groups.filter { !$0.isAnswered }.count

    if groups.isEmpty {
      LearnEmptyState(
        symbol: "quote.bubble",
        headline: "No alternatives waiting",
        detail: "Bex offers these when a phrase has more than one natural form.",
        identifier: "learn-suggestions-empty"
      )
    } else {
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          Text("Waiting for your pick · \(waiting) of \(groups.count)")
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("learn-suggestions-waiting")

          ForEach(groups) { group in
            groupCard(group)
          }

          Text(
            "Bex won't tell you which is better. Pick the one you'd actually say — "
              + "it becomes a Study card."
          )
          .font(.caption)
          .foregroundStyle(.tertiary)
          .padding(.top, 4)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .accessibilityIdentifier("learn-suggestions")
    }
  }

  private func groupCard(_ group: Group) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 4) {
        Text("you wrote")
          .foregroundStyle(.secondary)
        Text("“\(group.phrase)”")
          .italic()
      }

      // `FlowLayout` would be nicer, but macOS 13 has no wrapping stack; a vertical run
      // of chips reads fine at two or three alternatives, which is all a phrase ever has.
      VStack(alignment: .leading, spacing: 6) {
        ForEach(group.alternatives) { alternative in
          chip(alternative)
        }
      }
    }
    .font(.callout)
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    .accessibilityIdentifier("learn-suggestion-group-\(group.phrase)")
  }

  private func chip(_ suggestion: ConsiderSuggestion) -> some View {
    Button {
      Task { await viewModel.chooseSuggestion(suggestion) }
    } label: {
      HStack(spacing: 6) {
        Text(suggestion.alternative)
          .fontWeight(.medium)
        if !suggestion.reason.isEmpty {
          Text("· \(suggestion.reason)")
            .foregroundStyle(.secondary)
        }
        if suggestion.isTapped {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.tint)
        }
      }
      .font(.callout)
      .padding(.horizontal, 12)
      .padding(.vertical, 7)
      .contentShape(RoundedRectangle(cornerRadius: 8))
      .background(
        RoundedRectangle(cornerRadius: 8)
          .fill(suggestion.isTapped ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.quaternary))
      )
    }
    .buttonStyle(.plain)
    .disabled(suggestion.isTapped)
    .accessibilityIdentifier("learn-suggestion-choose-\(suggestion.id)")
  }
}

// MARK: - Progress

/// The read-only aggregation that used to be the whole Learning window: recurring grammar
/// tags and rates, the sentence-length avoidance guard, the weekly trend, and expression
/// uptake. Unchanged in substance — it just no longer competes with the deck for the
/// owner's attention.
struct LearnProgressView: View {
  @ObservedObject var viewModel: LearningViewModel

  var body: some View {
    if viewModel.isLoading {
      ProgressView("Loading Learning…")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("learning-loading")
    } else if viewModel.categoryRates.isEmpty && viewModel.weeklyRates.isEmpty {
      LearnEmptyState(
        symbol: "graduationcap",
        headline: "No corrections yet",
        detail: "Use Bex in Claude Code or Codex and check back after a week.",
        identifier: "learning-empty"
      )
    } else {
      List {
        Section {
          WriterProfilePanel(viewModel: viewModel)
        }
        if !viewModel.categoryRates.isEmpty {
          Section("Grammar mistakes by type") {
            ForEach(viewModel.categoryRates, id: \.category) { item in
              HStack {
                Text(item.displayName)
                Spacer()
                Text("\(item.count) (\(LearnFormat.number(item.ratePer100Words))/100 words)")
                  .foregroundStyle(.secondary)
                  .accessibilityLabel(
                    "\(item.count) times, "
                      + "\(LearnFormat.number(item.ratePer100Words)) per 100 words"
                  )
              }
              .accessibilityIdentifier("learning-mistake-\(item.category)")
            }
          }
          Section {
            VStack(alignment: .leading, spacing: 2) {
              Text(
                "Typical sentence length: "
                  + "\(LearnFormat.number(viewModel.medianSentenceLength)) words"
              )
              .accessibilityIdentifier("learning-median-sentence-length")
              Text("Shown so a drop in mistakes isn't just shorter, simpler sentences.")
                .font(.caption)
                .foregroundStyle(.secondary)
              Text(
                "Sentence-start capitalization is excluded — it's a terminal typing habit, "
                  + "not an English mistake."
              )
              .font(.caption)
              .foregroundStyle(.secondary)
              .accessibilityIdentifier("learning-capitalization-note")
            }
          }
        }
        if !viewModel.weeklyRates.isEmpty {
          Section("By week") {
            ForEach(viewModel.weeklyRates, id: \.weekIdentifier) { week in
              VStack(alignment: .leading, spacing: 2) {
                Text(LearnFormat.weekLabel(week))
                  .font(.subheadline.weight(.medium))
                Text(LearnFormat.topCategoriesSummary(week))
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              .accessibilityIdentifier(
                "learning-week-\(week.yearForWeekOfYear)-\(week.weekOfYear)")
            }
          }
        }
        if viewModel.uptakeSuggested > 0 {
          Section {
            VStack(alignment: .leading, spacing: 2) {
              Text(
                "Expression suggestions chosen: \(viewModel.uptakeAdopted) "
                  + "of \(viewModel.uptakeSuggested)"
              )
              .accessibilityIdentifier("learning-uptake")
              Text("Counts the alternatives you picked — not a guess at whether you reused them.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
      }
      .listStyle(.inset)
    }
  }
}

// MARK: - Writer profile

/// What Bex thinks it knows about the owner's English, and the one part of it they own.
///
/// Design 2c. Until now this profile was computed hourly, injected into every correction
/// prompt, and shown nowhere — Bex held an opinion about the owner that shaped every
/// correction and that the owner could neither read nor argue with. Showing it is the point;
/// "Who you are" being editable, preserved across refreshes, and actually sent to the model
/// is what makes it more than a readout.
struct WriterProfilePanel: View {
  @ObservedObject var viewModel: LearningViewModel
  @State private var isEditingNote = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      if !viewModel.solid.isEmpty {
        group(
          "Solid — never explained again",
          color: .green,
          identifier: "profile-solid"
        ) {
          chipRow(viewModel.solid.map { ($0, nil) }, tinted: false)
        }
      }
      if !viewModel.workingOn.isEmpty {
        group(
          "Working on — explained when they recur",
          color: .yellow,
          identifier: "profile-working-on"
        ) {
          chipRow(
            viewModel.workingOn.map {
              ($0.displayName, "\(LearnFormat.number($0.ratePer100Words))/100w")
            },
            tinted: true
          )
        }
      }
      group("Who you are — tunes suggestion level", color: .secondary, identifier: "profile-note") {
        ownerNoteEditor
      }
      Text(
        "This lives in one local file you can open: "
          + "~/Library/Application Support/Bex/LearningLog/writer-level.json. "
          + "Wrong? Edit it here — a background refresh keeps your words."
      )
      .font(.caption2)
      .foregroundStyle(.tertiary)
      .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.vertical, 4)
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline) {
      Text("Writer profile")
        .font(.headline)
      Spacer(minLength: 8)
      Text(
        [viewModel.profileAgeDescription, "editable"]
          .compactMap { $0 }
          .joined(separator: " · ")
      )
      .font(.caption)
      .foregroundStyle(.tertiary)
    }
    .accessibilityIdentifier("writer-profile")
  }

  @ViewBuilder
  private func group<Content: View>(
    _ title: String,
    color: Color,
    identifier: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(.caption.weight(.semibold))
        .textCase(.uppercase)
        .foregroundStyle(color)
      content()
    }
    .accessibilityIdentifier(identifier)
  }

  /// A vertical run rather than a wrapping one: macOS 13 has no wrapping stack, and three
  /// labels read fine stacked. Not worth a custom layout.
  private func chipRow(_ items: [(String, String?)], tinted: Bool) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(Array(items.enumerated()), id: \.offset) { _, item in
        HStack(spacing: 6) {
          Text(item.0)
          if let trailing = item.1 {
            Text(trailing)
              .foregroundStyle(.secondary)
          }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
          Capsule().fill(tinted ? AnyShapeStyle(Color.yellow.opacity(0.14)) : AnyShapeStyle(.quaternary))
        )
      }
    }
  }

  @ViewBuilder
  private var ownerNoteEditor: some View {
    if isEditingNote {
      VStack(alignment: .leading, spacing: 8) {
        TextEditor(text: $viewModel.ownerNote)
          .font(.callout)
          .frame(minHeight: 70)
          .padding(4)
          .background(Color(nsColor: .textBackgroundColor))
          .clipShape(RoundedRectangle(cornerRadius: 7))
          .overlay {
            RoundedRectangle(cornerRadius: 7)
              .stroke(Color(nsColor: .separatorColor))
          }
          .accessibilityIdentifier("writer-profile-note-editor")
        HStack {
          Button("Save") {
            isEditingNote = false
            Task { await viewModel.saveOwnerNote() }
          }
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("writer-profile-note-save")
          Button("Cancel", role: .cancel) {
            isEditingNote = false
            viewModel.ownerNote = viewModel.profile?.ownerNote ?? ""
          }
        }
      }
    } else {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(
          viewModel.ownerNote.isEmpty
            ? "Nothing yet — tell Bex who is writing, and suggestions get pitched at you rather than at nobody."
            : viewModel.ownerNote
        )
        .font(.callout)
        .foregroundStyle(viewModel.ownerNote.isEmpty ? .tertiary : .secondary)
        .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 8)
        Button(viewModel.ownerNote.isEmpty ? "Write" : "Edit") { isEditingNote = true }
          .buttonStyle(.link)
          .accessibilityIdentifier("writer-profile-note-edit")
      }
    }
  }
}

// MARK: - Shared bits

struct LearnEmptyState: View {
  let symbol: String
  let headline: String
  let detail: String
  let identifier: String

  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: symbol)
        .font(.largeTitle)
        .foregroundStyle(.secondary)
      Text(headline)
        .font(.headline)
      Text(detail)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityIdentifier(identifier)
  }
}

enum LearnFormat {
  /// Trims a trailing ".0" so whole numbers read as "12 words" rather than "12.0 words".
  static func number(_ value: Double) -> String {
    value.truncatingRemainder(dividingBy: 1) == 0
      ? String(format: "%.0f", value)
      : String(format: "%.1f", value)
  }

  static func weekLabel(_ week: WeeklyRate) -> String {
    String(format: "%d, week %02d", week.yearForWeekOfYear, week.weekOfYear)
  }

  /// Top (already rate-sorted) categories for one week, e.g. "Prepositions 20.0/100w ·
  /// Spelling 10.0/100w" — a simple summary line, sparse by design in the first weeks.
  static func topCategoriesSummary(_ week: WeeklyRate) -> String {
    guard !week.categoryRates.isEmpty else { return "No grammar mistakes this week" }
    return week.categoryRates.prefix(3)
      .map { "\($0.displayName) \(number($0.ratePer100Words))/100w" }
      .joined(separator: " · ")
  }
}
