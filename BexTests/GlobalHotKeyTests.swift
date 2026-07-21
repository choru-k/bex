import Carbon
import XCTest

@testable import Bex

@MainActor
final class GlobalHotKeyTests: XCTestCase {
  func testDuplicateBexChordReportsConflictWithoutCallingBackend() throws {
    let backend = FakeHotKeyRegistrationBackend()
    let hotKey = GlobalHotKey(backend: backend)
    let chord = KeyChord(keyCode: 12, modifiers: UInt32(cmdKey | shiftKey))
    let quickCheck = Shortcut(id: 1, chord: chord)
    let fixAndSend = Shortcut(id: 2, chord: chord)

    try hotKey.register(quickCheck) {}

    let expectedConflict = HotKeyConflict.chordAlreadyRegistered(chord: chord, existingID: 1)
    XCTAssertEqual(hotKey.conflict(for: fixAndSend), expectedConflict)
    XCTAssertThrowsError(try hotKey.register(fixAndSend) {}) { error in
      XCTAssertEqual(error as? HotKeyRegistrationError, .conflict(expectedConflict))
    }
    XCTAssertEqual(backend.registrationAttempts, [quickCheck])
    XCTAssertEqual(backend.activeShortcuts, [quickCheck])
  }

  func testReplacingSameChordRefreshesActionWithoutReregistering() throws {
    let backend = FakeHotKeyRegistrationBackend()
    let hotKey = GlobalHotKey(backend: backend)
    let shortcut = Shortcut(id: 1, chord: .defaultQuickCheck)
    var handledActions: [String] = []

    try hotKey.register(shortcut) {
      handledActions.append("old")
    }
    XCTAssertNil(hotKey.conflict(for: shortcut))
    try hotKey.replace(shortcut) {
      handledActions.append("refreshed")
    }
    hotKey.handle(shortcut.id)

    XCTAssertEqual(handledActions, ["refreshed"])
    XCTAssertEqual(backend.registrationAttempts, [shortcut])
    XCTAssertTrue(backend.unregisteredTokens.isEmpty)
    XCTAssertEqual(backend.activeShortcuts, [shortcut])
  }

  func testFailedReplacementPreservesPreviousRegistrationAndAction() throws {
    let backend = FakeHotKeyRegistrationBackend()
    let hotKey = GlobalHotKey(backend: backend)
    let original = Shortcut(id: 1, chord: .defaultQuickCheck)
    let replacement = Shortcut(
      id: 1,
      chord: KeyChord(keyCode: 14, modifiers: UInt32(cmdKey | optionKey))
    )
    var handledActions: [String] = []

    try hotKey.register(original) {
      handledActions.append("original")
    }
    backend.failingChord = replacement.chord

    XCTAssertThrowsError(
      try hotKey.replace(replacement) {
        handledActions.append("replacement")
      }
    ) { error in
      XCTAssertEqual(error as? HotKeyRegistrationError, .carbon(status: -9_876))
    }
    hotKey.handle(original.id)

    XCTAssertEqual(handledActions, ["original"])
    XCTAssertEqual(backend.registrationAttempts, [original, replacement])
    XCTAssertTrue(backend.unregisteredTokens.isEmpty)
    XCTAssertEqual(backend.activeShortcuts, [original])
  }

  func testAtomicRegistrationRollsBackEveryNewShortcutWhenOneFails() {
    let backend = FakeHotKeyRegistrationBackend()
    let hotKey = GlobalHotKey(backend: backend)
    let quickCheck = Shortcut(id: 1, chord: .defaultQuickCheck)
    let fixAndSend = Shortcut(id: 2, chord: .defaultFixAndSend)
    backend.failingChord = fixAndSend.chord
    let action: @MainActor @Sendable () -> Void = {}

    XCTAssertThrowsError(
      try hotKey.register([
        (shortcut: quickCheck, action: action),
        (shortcut: fixAndSend, action: action),
      ])
    ) { error in
      XCTAssertEqual(error as? HotKeyRegistrationError, .carbon(status: -9_876))
    }

    XCTAssertEqual(backend.registrationAttempts, [quickCheck, fixAndSend])
    XCTAssertTrue(backend.activeShortcuts.isEmpty)
    XCTAssertEqual(backend.unregisteredTokens.count, 1)
    XCTAssertNil(hotKey.conflict(for: quickCheck))
    XCTAssertNil(hotKey.conflict(for: fixAndSend))
  }

  func testDefaultChordsMatchProductShortcutsAndDoNotConflict() {
    XCTAssertEqual(
      KeyChord.defaultQuickCheck,
      KeyChord(keyCode: UInt32(kVK_ANSI_G), modifiers: UInt32(cmdKey | shiftKey))
    )
    XCTAssertEqual(
      KeyChord.defaultFixAndSend,
      KeyChord(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(cmdKey | shiftKey))
    )
    XCTAssertNotEqual(KeyChord.defaultQuickCheck, KeyChord.defaultFixAndSend)
  }
}

@MainActor
private final class FakeHotKeyRegistrationBackend: HotKeyRegistrationBackend {
  var failingChord: KeyChord?
  private(set) var registrationAttempts: [Shortcut] = []
  private(set) var unregisteredTokens: [HotKeyRegistrationToken] = []

  private var nextTokenRawValue: UInt = 1
  private var shortcutsByToken: [HotKeyRegistrationToken: Shortcut] = [:]

  var activeShortcuts: [Shortcut] {
    shortcutsByToken.values.sorted { $0.id < $1.id }
  }

  func start(owner: GlobalHotKey) throws {}

  func stop() {}

  func register(_ shortcut: Shortcut) throws -> HotKeyRegistrationToken {
    registrationAttempts.append(shortcut)
    if shortcut.chord == failingChord {
      throw HotKeyRegistrationError.carbon(status: -9_876)
    }

    let token = HotKeyRegistrationToken(rawValue: nextTokenRawValue)
    nextTokenRawValue += 1
    shortcutsByToken[token] = shortcut
    return token
  }

  func unregister(_ token: HotKeyRegistrationToken) {
    unregisteredTokens.append(token)
    shortcutsByToken[token] = nil
  }
}
