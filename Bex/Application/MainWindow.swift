import SwiftUI

/// Which page the one Bex window is showing.
///
/// Bex used to open Learning, Study, History and Writing Styles as four independent
/// `NSWindow`s, plus a fifth for Settings, each with its own frame, its own title and its
/// own way of being found. The redesign collapses all of them into one window with a
/// sidebar: everything that is not the correction moment now lives in a single place the
/// owner can navigate without hunting through a menu.
///
/// Quick Check and Fix & Send are deliberately absent. They stay floating panels driven
/// by their global shortcuts — non-negotiable 1 makes the correction path latency-sacred,
/// and routing it through a window that has to be found, raised and switched to would be
/// exactly the wrong trade.
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

  let study: StudyViewModel
  let learning: LearningViewModel
  let history: HistoryViewModel
  let profiles: ProfilesViewModel
  let settings: SettingsViewModel

  init(
    page: MainWindowPage = .learn,
    study: StudyViewModel,
    learning: LearningViewModel,
    history: HistoryViewModel,
    profiles: ProfilesViewModel,
    settings: SettingsViewModel
  ) {
    self.page = page
    self.study = study
    self.learning = learning
    self.history = history
    self.profiles = profiles
    self.settings = settings
  }
}

/// The one Bex window: a sidebar of destinations on the left, the selected page on the
/// right.
struct BexMainWindow: View {
  @ObservedObject var model: MainWindowModel
  /// Opens the Quick Check panel. A closure rather than a page because Quick Check is not
  /// a page — see `MainWindowPage`.
  let openQuickCheck: () -> Void

  var body: some View {
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
        quickCheckRow
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

  /// An action, not a destination: it raises the floating Quick Check panel and leaves the
  /// window's own selection alone.
  private var quickCheckRow: some View {
    Button(action: openQuickCheck) {
      Label("Quick Check", systemImage: "checkmark.circle")
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("main-sidebar-quick-check")
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
      LearnView(study: model.study, learning: model.learning)
    case .history:
      HistoryView(viewModel: model.history)
    case .writingStyles:
      ProfilesView(viewModel: model.profiles)
    case .settings:
      SettingsView(viewModel: model.settings)
    }
  }
}
