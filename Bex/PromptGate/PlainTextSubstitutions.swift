import AppKit
import SwiftUI

/// Turns off macOS smart dashes, smart quotes, and text replacement for every text view
/// in the window this lands in.
///
/// The Fix & Send composer is a place where technical text is normal, and system text
/// substitution is actively wrong there: typing `--dry-run` produced `—dry—run`, which no
/// longer matched the flag mask pattern — so a manually edited draft could carry an
/// unmasked flag past the consent sheet. The final-message editor has the same problem
/// one step later: an em-dashed flag would be delivered to the terminal.
///
/// A whole-window sweep rather than a per-editor wrapper because `TextEditor` gives no
/// handle to its backing `NSTextView`; walking the panel's view tree from a marker view is
/// the smallest thing that works, and it is idempotent.
// ponytail: re-sweeps the whole window tree on every SwiftUI update; the trees here are
// tiny. Wrap NSTextView properly only if a profiler ever notices this.
struct PlainTextSubstitutionsDisabler: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    Disabler()
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    // Phase changes mount fresh editors; every update re-applies to whatever exists now.
    (nsView as? Disabler)?.disableSoon()
  }

  private final class Disabler: NSView {
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      disableSoon()
    }

    func disableSoon() {
      // Async so sibling SwiftUI views (the editors themselves) finish mounting first.
      DispatchQueue.main.async { [weak self] in
        guard let root = self?.window?.contentView else { return }
        Self.disable(in: root)
      }
    }

    private static func disable(in view: NSView) {
      if let textView = view as? NSTextView {
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
      }
      for subview in view.subviews {
        disable(in: subview)
      }
    }
  }
}
