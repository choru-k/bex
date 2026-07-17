import AppKit

@MainActor
protocol PasteboardWriting {
  func write(_ string: String) throws
}

@MainActor
final class SystemPasteboard: PasteboardWriting {
  func write(_ string: String) throws {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    guard pasteboard.setString(string, forType: .string) else {
      throw BexError.storageFailure("Bex could not copy the correction.")
    }
  }
}
