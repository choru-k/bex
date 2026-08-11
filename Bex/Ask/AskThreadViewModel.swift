import Foundation

/// A thread of questions about one correction or one card.
///
/// Design 2a. The whole constraint on this thing is the tagline: *never blocks Send*. So it
/// owns its own task, its own error, and its own loading flag, and the surface hosting it
/// keeps working while a question is in flight. Nothing here can make the primary action
/// wait — non-negotiable 2 says blocking the shipping flow is the fastest way to get Bex
/// turned off.
@MainActor
final class AskThreadViewModel: ObservableObject {
  @Published private(set) var messages: [AskMessage] = []
  @Published var question: String = ""
  @Published private(set) var isAnswering = false
  /// Shown inside the thread, never raised as an alert: a failed question is a failed
  /// question, not an interruption of whatever the owner was actually doing.
  @Published private(set) var errorMessage: String?
  /// Cards already kept, by the message they came from, so the button can say so instead of
  /// silently minting a second copy.
  @Published private(set) var savedCardMessageIDs: Set<UUID> = []

  /// The text questions are about. Reset per correction or per card by the host surface.
  private var context: String = ""
  private let grammar: any GrammarServicing
  private let preferences: PreferencesStore
  private let learningLog: LearningLogStore
  private var task: Task<Void, Never>?

  init(
    grammar: any GrammarServicing,
    preferences: PreferencesStore,
    learningLog: LearningLogStore
  ) {
    self.grammar = grammar
    self.preferences = preferences
    self.learningLog = learningLog
  }

  var isEmpty: Bool { messages.isEmpty }

  var canAsk: Bool {
    !isAnswering && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// Points the thread at a new subject, discarding the previous conversation.
  ///
  /// Called when the correction or card changes. Answers are about one specific piece of text,
  /// so carrying them over would leave replies on screen that no longer refer to anything.
  func reset(context: String) {
    guard context != self.context || !messages.isEmpty else { return }
    task?.cancel()
    task = nil
    self.context = context
    messages = []
    question = ""
    isAnswering = false
    errorMessage = nil
    savedCardMessageIDs = []
  }

  func ask() {
    let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !isAnswering else { return }
    messages.append(AskMessage(role: .owner, text: trimmed))
    question = ""
    errorMessage = nil
    isAnswering = true

    task = Task { [weak self, grammar, preferences, context] in
      defer { Task { @MainActor [weak self] in self?.isAnswering = false } }
      do {
        // `.ask` on purpose: this is not the correction path, so it may take a few seconds
        // and use a stronger model than a Quick Check can afford.
        let destination = try await preferences.outboundDestination(for: .ask)
        guard await preferences.hasAcceptedCurrentOutboundDisclosure(for: destination) else {
          await MainActor.run { [weak self] in
            self?.errorMessage =
              "Asking sends your question to \(destination.disclosureTarget). Approve that "
              + "destination once — a check or a Fix & Send will ask — and questions work after that."
          }
          return
        }
        let answer = try await grammar.answerQuestion(
          question: trimmed, context: context, destination: destination)
        guard !Task.isCancelled else { return }
        await MainActor.run { [weak self] in
          self?.messages.append(
            AskMessage(role: .bex, text: answer.answer, card: answer.card))
        }
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled else { return }
        await MainActor.run { [weak self] in
          self?.errorMessage = (error as? LocalizedError)?.errorDescription
            ?? "That question could not be answered. Try again, or carry on — nothing is blocked."
        }
      }
    }
  }

  /// Keeps the drillable pair an answer offered, as a Study card.
  ///
  /// Written straight to the learning log in the format `StudyCardBuilder` already reads, so
  /// the card enters the same deck, scheduling and daily plan as everything else — the same
  /// route `DictionaryLookup` takes for saved vocabulary.
  func saveCard(from message: AskMessage) async {
    guard let card = message.card, !savedCardMessageIDs.contains(message.id) else { return }
    savedCardMessageIDs.insert(message.id)
    await learningLog.append(
      client: "bex-ask",
      original: card.sentence,
      corrected: card.sentence.replacingOccurrences(
        of: card.weaker, with: card.better, options: [.caseInsensitive]),
      explanation: card.learningLogExplanation,
      provider: "bex",
      model: "ask"
    )
  }

  func cancel() {
    task?.cancel()
    task = nil
    isAnswering = false
  }
}
