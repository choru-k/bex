import AppKit

@MainActor
protocol PasteboardWriting {
  func write(_ string: String) throws
}

@MainActor
protocol PasteboardTransacting {
  func stage(_ string: String) throws -> PasteboardRestoration
}

@MainActor
final class PasteboardRestoration {
  private let pasteboard: NSPasteboard
  private let items: [[NSPasteboard.PasteboardType: Data]]
  private let stagedChangeCount: Int
  private var restored = false

  fileprivate init(
    pasteboard: NSPasteboard,
    items: [[NSPasteboard.PasteboardType: Data]],
    stagedChangeCount: Int
  ) {
    self.pasteboard = pasteboard
    self.items = items
    self.stagedChangeCount = stagedChangeCount
  }

  @discardableResult
  func restore() -> Bool {
    guard !restored else { return false }
    restored = true
    guard pasteboard.changeCount == stagedChangeCount else { return false }
    pasteboard.clearContents()
    guard !items.isEmpty else { return true }
    let restoredItems = items.map { values -> NSPasteboardItem in
      let item = NSPasteboardItem()
      for (type, data) in values {
        item.setData(data, forType: type)
      }
      return item
    }
    pasteboard.writeObjects(restoredItems)
    return true
  }
}

@MainActor
final class SystemPasteboard: PasteboardWriting, PasteboardTransacting {
  private let pasteboard: NSPasteboard

  init(pasteboard: NSPasteboard = .general) {
    self.pasteboard = pasteboard
  }

  func write(_ string: String) throws {
    pasteboard.clearContents()
    guard pasteboard.setString(string, forType: .string) else {
      throw BexError.storageFailure("Bex could not copy the correction.")
    }
  }

  func stage(_ string: String) throws -> PasteboardRestoration {
    let snapshot = (pasteboard.pasteboardItems ?? []).map { item in
      Dictionary(
        uniqueKeysWithValues: item.types.compactMap { type in
          item.data(forType: type).map { (type, $0) }
        }
      )
    }
    pasteboard.clearContents()
    guard pasteboard.setString(string, forType: .string) else {
      throw BexError.storageFailure("Bex could not stage the correction.")
    }
    return PasteboardRestoration(
      pasteboard: pasteboard,
      items: snapshot,
      stagedChangeCount: pasteboard.changeCount
    )
  }
}
