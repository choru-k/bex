import SwiftUI

/// Which page the one Bex window is showing.
///
/// Bex used to open Learning, Study, History and Writing Styles as four independent
/// `NSWindow`s, plus a fifth for Settings, each with its own frame, its own title and its
/// own way of being found. The redesign collapses all of them into one window with a
/// sidebar: everything that is not the correction moment now lives in a single place the
/// owner can navigate without hunting through a menu.
///
/// Fix & Send is deliberately absent from the page list. It stays a floating panel driven
/// by its global shortcut — the correction path is latency-sensitive, and routing it
/// through a window that has to be found, raised and switched to would be the wrong trade.
enum MainWindowPage: String, CaseIterable, Identifiable, Hashable {
  case learn
  case history
  case writingStyles
  case settings

  var id: String { rawValue }

  var title: String {
    switch self {
    case .learn: return "Learn"
    case .history: return "History"
    case .writingStyles: return "Writing Styles"
    case .settings: return "Settings"
    }
  }

  var symbol: String {
    switch self {
    case .learn: return "target"
    case .history: return "clock.arrow.circlepath"
    case .writingStyles: return "textformat"
    case .settings: return "gearshape"
    }
  }
}

/// Everything the one window needs, owned for the window's lifetime.
///
/// The child view models live here rather than being created inside `BexMainWindow` so
/// that switching pages does not rebuild them — a `HistoryViewModel` that reloaded every
/// time the owner glanced at Learn and came back would re-read the whole store for
/// nothing. `study` is injected rather than constructed because the menu-bar hub answers
/// cards from the same session; see `WindowCoordinator.studyDrill`.
@MainActor
final class MainWindowModel: ObservableObject {
  @Published var page: MainWindowPage

  /// True while a drill has taken the window over: no sidebar, no tabs, no counters —
  /// design 3a. Lives here rather than on `StudyViewModel` because it is a fact about this
  /// window; the menu-bar hub shows the very same session and never takes anything over.
  @Published var isDrillTakeover = false

  /// Whether the owner has already pressed Esc out of a drill in this window.
  ///
  /// Without it, every return to Learn — and every fresh card — would drop them straight
  /// back into a takeover they had just chosen to leave. Bex pushing a card is the point;
  /// Bex ignoring "not now" is not.
  @Published var hasLeftDrill = false

  let study: StudyViewModel
  let learning: LearningViewModel
  let askThread: AskThreadViewModel
  let history: HistoryViewModel
  let profiles: ProfilesViewModel
  let settings: SettingsViewModel

  init(
    page: MainWindowPage = .learn,
    study: StudyViewModel,
    learning: LearningViewModel,
    askThread: AskThreadViewModel,
    history: HistoryViewModel,
    profiles: ProfilesViewModel,
    settings: SettingsViewModel
  ) {
    self.page = page
    self.study = study
    self.learning = learning
    self.askThread = askThread
    self.history = history
    self.profiles = profiles
    self.settings = settings
  }

  func startDrill() {
    guard study.currentCard != nil else { return }
    isDrillTakeover = true
  }

  func endDrill() {
    hasLeftDrill = true
    isDrillTakeover = false
  }
}

/// The one Bex window: a sidebar of destinations on the left, the selected page on the
/// right.
struct BexMainWindow: View {
  @ObservedObject var model: MainWindowModel
  /// Invokes the floating Fix & Send workflow from correction entry points.
  let openFixAndSend: () -> Void

  var body: some View {
    // A drill replaces the window's content outright rather than collapsing the split view's
    // sidebar around it.
    //
    // Design 3a asks for the card to *be* the screen, and going through the split view to get
    // there was both indirect and wrong: at `.detailOnly` the split view laid itself out
    // 1345pt tall inside a 560pt window and centred the overflow, which silently pushed the
    // drill's top bar off the top edge and its progress dots off the bottom. Swapping the root
    // is what "takes over the window" already meant, and it deletes the column-visibility and
    // toolbar-hiding juggling that was standing in for it.
    if model.isDrillTakeover, let card = model.study.currentCard {
      StudyTakeoverView(
        viewModel: model.study,
        askThread: model.askThread,
        card: card,
        end: model.endDrill
      )
    } else {
      NavigationSplitView {
        sidebar
          .navigationSplitViewColumnWidth(min: 180, ideal: 196, max: 260)
      } detail: {
        detail
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      // No `.navigationTitle` on purpose: `WindowCoordinator` owns the window title so that
      // routing to a page and clicking that page in the sidebar cannot disagree about it.
    }
  }

  // MARK: - Sidebar

  /// Settings is pinned below the list rather than sitting in it, matching the design and
  /// the way every other Mac app with a settings destination in its sidebar behaves: the
  /// things you work in scroll, the thing you configure stays put.
  private var sidebar: some View {
    VStack(spacing: 0) {
      List(selection: $model.page) {
        row(.learn)
          .badge(model.study.remainingCount > 0 ? Text("\(model.study.remainingCount)") : nil)
          .tag(MainWindowPage.learn)
        fixAndSendRow
        row(.history).tag(MainWindowPage.history)
        row(.writingStyles).tag(MainWindowPage.writingStyles)
      }
      .listStyle(.sidebar)

      Divider()
      pinnedSettingsRow
    }
    .accessibilityIdentifier("main-sidebar")
  }

  private func row(_ page: MainWindowPage) -> some View {
    Label(page.title, systemImage: page.symbol)
      .accessibilityIdentifier("main-sidebar-\(page.rawValue)")
  }

  /// An action, not a destination: it raises Fix & Send and leaves the selection alone.
  private var fixAndSendRow: some View {
    Button(action: openFixAndSend) {
      Label("Fix & Send", systemImage: "checkmark.circle")
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("main-sidebar-fix-and-send")
  }

  private var pinnedSettingsRow: some View {
    Button {
      model.page = .settings
    } label: {
      row(.settings)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(
          RoundedRectangle(cornerRadius: 6)
            .fill(model.page == .settings ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear))
        )
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
  }

  // MARK: - Detail

  @ViewBuilder
  private var detail: some View {
    switch model.page {
    case .learn:
      LearnView(
        model: model,
        study: model.study,
        learning: model.learning,
        askThread: model.askThread,
        openFixAndSend: openFixAndSend
      )
    case .history:
      HistoryView(viewModel: model.history)
    case .writingStyles:
      ProfilesView(viewModel: model.profiles)
    case .settings:
      SettingsView(viewModel: model.settings)
    }
  }
}
