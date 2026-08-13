import SwiftUI

struct WelcomeView: View {
  let dismiss: @MainActor () -> Void
  let openQuickCheck: @MainActor () -> Void
  let setUpProvider: @MainActor () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      HStack(alignment: .top, spacing: 16) {
        Image(systemName: "text.badge.checkmark")
          .font(.system(size: 42, weight: .medium))
          .foregroundStyle(.tint)
          .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 6) {
          Text("Welcome to Bex")
            .font(.largeTitle.bold())
            .accessibilityAddTraits(.isHeader)
          Text("Review and improve writing without leaving your current app.")
            .font(.title3)
            .foregroundStyle(.secondary)
        }
      }

      VStack(alignment: .leading, spacing: 14) {
        feature(
          title: "Quick Check",
          detail: "Open Bex from the menu bar or your shortcut, then review a correction before copying it."
        )
        feature(
          title: "Fix & Send",
          detail: "Capture the focused text field, confirm exactly what leaves your Mac, and choose how the correction is delivered."
        )
        feature(
          title: "You stay in control",
          detail: "Bex asks before outbound work and does not save drafts or History unless you choose to."
        )
      }

      Spacer(minLength: 0)

      HStack {
        Button("Not Now", role: .cancel, action: dismiss)
          .keyboardShortcut(.cancelAction)
          .accessibilityIdentifier("welcome-not-now")
        Spacer()
        Button("Set Up Provider…", action: setUpProvider)
          .accessibilityIdentifier("welcome-set-up-provider")
        Button("Open Quick Check", action: openQuickCheck)
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("welcome-open-quick-check")
      }
    }
    .padding(28)
    .frame(minWidth: 500, minHeight: 360)
    // No container-level identifier here: on current macOS a container's
    // accessibilityIdentifier is stamped onto every descendant, clobbering the buttons'
    // own ids ("welcome-set-up-provider" et al.) in the exposed tree. Nothing referenced
    // the container id.
  }

  private func feature(title: String, detail: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title)
        .font(.headline)
      Text(detail)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}
