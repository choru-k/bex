import AppKit
import Carbon
import Foundation

private let bexHotKeySignature: OSType = 0x4245_5847  // BEXG

struct KeyChord: Codable, Equatable, Hashable, Sendable {
  let keyCode: UInt32
  let modifiers: UInt32

  static let defaultFixAndSend = KeyChord(
    keyCode: UInt32(kVK_ANSI_P),
    modifiers: UInt32(cmdKey | shiftKey)
  )

  var keyEquivalent: String {
    switch Int(keyCode) {
    case kVK_ANSI_A: "a"
    case kVK_ANSI_B: "b"
    case kVK_ANSI_C: "c"
    case kVK_ANSI_D: "d"
    case kVK_ANSI_E: "e"
    case kVK_ANSI_F: "f"
    case kVK_ANSI_G: "g"
    case kVK_ANSI_H: "h"
    case kVK_ANSI_I: "i"
    case kVK_ANSI_J: "j"
    case kVK_ANSI_K: "k"
    case kVK_ANSI_L: "l"
    case kVK_ANSI_M: "m"
    case kVK_ANSI_N: "n"
    case kVK_ANSI_O: "o"
    case kVK_ANSI_P: "p"
    case kVK_ANSI_Q: "q"
    case kVK_ANSI_R: "r"
    case kVK_ANSI_S: "s"
    case kVK_ANSI_T: "t"
    case kVK_ANSI_U: "u"
    case kVK_ANSI_V: "v"
    case kVK_ANSI_W: "w"
    case kVK_ANSI_X: "x"
    case kVK_ANSI_Y: "y"
    case kVK_ANSI_Z: "z"
    case kVK_ANSI_0: "0"
    case kVK_ANSI_1: "1"
    case kVK_ANSI_2: "2"
    case kVK_ANSI_3: "3"
    case kVK_ANSI_4: "4"
    case kVK_ANSI_5: "5"
    case kVK_ANSI_6: "6"
    case kVK_ANSI_7: "7"
    case kVK_ANSI_8: "8"
    case kVK_ANSI_9: "9"
    case kVK_ANSI_Equal: "="
    case kVK_ANSI_Minus: "-"
    case kVK_ANSI_LeftBracket: "["
    case kVK_ANSI_RightBracket: "]"
    case kVK_ANSI_Backslash: "\\"
    case kVK_ANSI_Semicolon: ";"
    case kVK_ANSI_Quote: "'"
    case kVK_ANSI_Comma: ","
    case kVK_ANSI_Period: "."
    case kVK_ANSI_Slash: "/"
    case kVK_ANSI_Grave: "`"
    case kVK_Return: "\r"
    case kVK_Tab: "\t"
    case kVK_Space: " "
    case kVK_Delete: String(UnicodeScalar(NSBackspaceCharacter)!)
    case kVK_ForwardDelete: String(UnicodeScalar(NSDeleteFunctionKey)!)
    case kVK_LeftArrow: String(UnicodeScalar(NSLeftArrowFunctionKey)!)
    case kVK_RightArrow: String(UnicodeScalar(NSRightArrowFunctionKey)!)
    case kVK_DownArrow: String(UnicodeScalar(NSDownArrowFunctionKey)!)
    case kVK_UpArrow: String(UnicodeScalar(NSUpArrowFunctionKey)!)
    default: ""
    }
  }

  var modifierMask: NSEvent.ModifierFlags {
    var result: NSEvent.ModifierFlags = []
    if modifiers & UInt32(cmdKey) != 0 { result.insert(.command) }
    if modifiers & UInt32(optionKey) != 0 { result.insert(.option) }
    if modifiers & UInt32(controlKey) != 0 { result.insert(.control) }
    if modifiers & UInt32(shiftKey) != 0 { result.insert(.shift) }
    return result
  }

  var isValidGlobalShortcut: Bool {
    let requiredModifiers = UInt32(cmdKey | optionKey | controlKey)
    return !keyEquivalent.isEmpty && modifiers & requiredModifiers != 0
  }

  var displayString: String {
    var result = ""
    if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
    if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
    if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
    if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
    result += displayKey
    return result
  }

  private var displayKey: String {
    switch Int(keyCode) {
    case kVK_Return: "Return"
    case kVK_Tab: "Tab"
    case kVK_Space: "Space"
    case kVK_Delete: "Delete"
    case kVK_ForwardDelete: "Forward Delete"
    case kVK_LeftArrow: "←"
    case kVK_RightArrow: "→"
    case kVK_DownArrow: "↓"
    case kVK_UpArrow: "↑"
    default:
      keyEquivalent.isEmpty ? "Key \(keyCode)" : keyEquivalent.uppercased()
    }
  }
}

enum BexShortcut: UInt32, CaseIterable, Sendable {
  case fixAndSend = 2

  var title: String { "Fix & Send" }

  var defaultChord: KeyChord { .defaultFixAndSend }
}

struct Shortcut: Equatable, Sendable {
  let id: UInt32
  let chord: KeyChord

  var keyCode: UInt32 { chord.keyCode }
  var modifiers: UInt32 { chord.modifiers }

  init(id: UInt32, chord: KeyChord) {
    self.id = id
    self.chord = chord
  }

  init(id: UInt32, keyCode: UInt32, modifiers: UInt32) {
    self.init(id: id, chord: KeyChord(keyCode: keyCode, modifiers: modifiers))
  }
}

private let globalHotKeyEventHandler: EventHandlerUPP = { _, event, userData in
  guard let event, let userData else { return OSStatus(eventNotHandledErr) }
  var hotKeyID = EventHotKeyID()
  let status = GetEventParameter(
    event,
    EventParamName(kEventParamDirectObject),
    EventParamType(typeEventHotKeyID),
    nil,
    MemoryLayout<EventHotKeyID>.size,
    nil,
    &hotKeyID
  )
  guard status == noErr, hotKeyID.signature == bexHotKeySignature else {
    return OSStatus(eventNotHandledErr)
  }
  let owner = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
  Task { @MainActor in owner.handle(hotKeyID.id) }
  return noErr
}

enum HotKeyConflict: Equatable, Sendable {
  case identifierAlreadyRegistered(id: UInt32, chord: KeyChord)
  case chordAlreadyRegistered(chord: KeyChord, existingID: UInt32)
}

enum HotKeyRegistrationError: Error, Equatable {
  case invalidChord
  case conflict(HotKeyConflict)
  case carbon(status: OSStatus)
  case missingRegistrationReference
  case updaterUnavailable
}

extension HotKeyRegistrationError: LocalizedError {
  var errorDescription: String? {
    switch self {
    case .invalidChord:
      "Include Command, Option, or Control in the shortcut."
    case .conflict(.identifierAlreadyRegistered):
      "That Bex command already has a shortcut."
    case .conflict(.chordAlreadyRegistered):
      "That shortcut is already assigned to another Bex command."
    case .carbon:
      "macOS or another app is already using that shortcut."
    case .missingRegistrationReference:
      "macOS did not return a shortcut registration."
    case .updaterUnavailable:
      "Shortcut settings are not available yet."
    }
  }
}

struct HotKeyRegistrationToken: Hashable, Sendable {
  let rawValue: UInt
}

@MainActor
protocol HotKeyRegistrationBackend: AnyObject {
  func start(owner: GlobalHotKey) throws
  func stop()
  func register(_ shortcut: Shortcut) throws -> HotKeyRegistrationToken
  func unregister(_ token: HotKeyRegistrationToken)
}

@MainActor
protocol HotKeyRegistering: AnyObject {
  func conflict(for shortcut: Shortcut) -> HotKeyConflict?
  func register(_ shortcut: Shortcut, action: @escaping @MainActor () -> Void) throws
  func register(
    _ shortcuts: [(shortcut: Shortcut, action: @MainActor () -> Void)]
  ) throws
  func replace(_ shortcut: Shortcut, action: @escaping @MainActor () -> Void) throws
  func unregister(id: UInt32)
  func unregisterAll()
}

@MainActor
enum BexShortcutBridge {
  static var updater: ((BexShortcut, KeyChord) throws -> Void)?

  static func update(_ shortcut: BexShortcut, chord: KeyChord) throws {
    guard let updater else {
      throw HotKeyRegistrationError.updaterUnavailable
    }
    try updater(shortcut, chord)
  }
}

@MainActor
private final class CarbonHotKeyRegistrationBackend: HotKeyRegistrationBackend {
  private var eventHandlerReference: EventHandlerRef?

  func start(owner: GlobalHotKey) throws {
    guard eventHandlerReference == nil else { return }
    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed)
    )
    let context = Unmanaged.passUnretained(owner).toOpaque()
    let status = InstallEventHandler(
      GetEventDispatcherTarget(),
      globalHotKeyEventHandler,
      1,
      &eventType,
      context,
      &eventHandlerReference
    )
    guard status == noErr else {
      eventHandlerReference = nil
      throw HotKeyRegistrationError.carbon(status: status)
    }
  }

  func stop() {
    guard let eventHandlerReference else { return }
    RemoveEventHandler(eventHandlerReference)
    self.eventHandlerReference = nil
  }

  func register(_ shortcut: Shortcut) throws -> HotKeyRegistrationToken {
    var reference: EventHotKeyRef?
    let hotKeyID = EventHotKeyID(signature: bexHotKeySignature, id: shortcut.id)
    let status = RegisterEventHotKey(
      shortcut.keyCode,
      shortcut.modifiers,
      hotKeyID,
      GetEventDispatcherTarget(),
      0,
      &reference
    )
    guard status == noErr else {
      throw HotKeyRegistrationError.carbon(status: status)
    }
    guard let reference else {
      throw HotKeyRegistrationError.missingRegistrationReference
    }
    return HotKeyRegistrationToken(rawValue: UInt(bitPattern: reference))
  }

  func unregister(_ token: HotKeyRegistrationToken) {
    guard let reference = EventHotKeyRef(bitPattern: token.rawValue) else { return }
    UnregisterEventHotKey(reference)
  }
}

@MainActor
final class GlobalHotKey: HotKeyRegistering {
  private struct Registration {
    let token: HotKeyRegistrationToken
    let chord: KeyChord
    let action: @MainActor () -> Void
  }

  private let backend: any HotKeyRegistrationBackend
  private var registrations: [UInt32: Registration] = [:]
  private var backendStarted = false

  init() {
    backend = CarbonHotKeyRegistrationBackend()
  }

  init(backend: any HotKeyRegistrationBackend) {
    self.backend = backend
  }

  func conflict(for shortcut: Shortcut) -> HotKeyConflict? {
    chordConflict(for: shortcut)
  }

  func register(_ shortcut: Shortcut, action: @escaping @MainActor () -> Void) throws {
    try register([(shortcut: shortcut, action: action)])
  }

  func register(
    _ shortcuts: [(shortcut: Shortcut, action: @MainActor () -> Void)]
  ) throws {
    var proposedIDs: [UInt32: KeyChord] = [:]
    var proposedChords: [KeyChord: UInt32] = [:]
    for binding in shortcuts {
      guard binding.shortcut.chord.isValidGlobalShortcut else {
        throw HotKeyRegistrationError.invalidChord
      }
      if let existing = registrations[binding.shortcut.id] {
        throw HotKeyRegistrationError.conflict(
          .identifierAlreadyRegistered(id: binding.shortcut.id, chord: existing.chord)
        )
      }
      if let existingChord = proposedIDs[binding.shortcut.id] {
        throw HotKeyRegistrationError.conflict(
          .identifierAlreadyRegistered(id: binding.shortcut.id, chord: existingChord)
        )
      }
      if let conflict = conflict(for: binding.shortcut) {
        throw HotKeyRegistrationError.conflict(conflict)
      }
      if let existingID = proposedChords[binding.shortcut.chord] {
        throw HotKeyRegistrationError.conflict(
          .chordAlreadyRegistered(chord: binding.shortcut.chord, existingID: existingID)
        )
      }
      proposedIDs[binding.shortcut.id] = binding.shortcut.chord
      proposedChords[binding.shortcut.chord] = binding.shortcut.id
    }

    try startBackendIfNeeded()
    var pending: [(id: UInt32, registration: Registration)] = []
    do {
      for binding in shortcuts {
        let token = try backend.register(binding.shortcut)
        pending.append(
          (
            id: binding.shortcut.id,
            registration: Registration(
              token: token,
              chord: binding.shortcut.chord,
              action: binding.action
            )
          ))
      }
    } catch {
      for item in pending.reversed() {
        backend.unregister(item.registration.token)
      }
      stopBackendIfUnused()
      throw error
    }

    for item in pending {
      registrations[item.id] = item.registration
    }
  }

  func replace(_ shortcut: Shortcut, action: @escaping @MainActor () -> Void) throws {
    guard shortcut.chord.isValidGlobalShortcut else {
      throw HotKeyRegistrationError.invalidChord
    }
    guard let existing = registrations[shortcut.id] else {
      try register(shortcut, action: action)
      return
    }
    if existing.chord == shortcut.chord {
      registrations[shortcut.id] = Registration(
        token: existing.token,
        chord: shortcut.chord,
        action: action
      )
      return
    }
    if let conflict = chordConflict(for: shortcut) {
      throw HotKeyRegistrationError.conflict(conflict)
    }

    let replacementToken = try backend.register(shortcut)
    backend.unregister(existing.token)
    registrations[shortcut.id] = Registration(
      token: replacementToken,
      chord: shortcut.chord,
      action: action
    )
  }

  func unregister(id: UInt32) {
    guard let registration = registrations.removeValue(forKey: id) else { return }
    backend.unregister(registration.token)
    stopBackendIfUnused()
  }

  func unregisterAll() {
    for registration in registrations.values {
      backend.unregister(registration.token)
    }
    registrations.removeAll(keepingCapacity: true)
    stopBackendIfUnused()
  }

  func handle(_ id: UInt32) {
    registrations[id]?.action()
  }

  private func chordConflict(for shortcut: Shortcut) -> HotKeyConflict? {
    for (id, registration) in registrations
    where id != shortcut.id && registration.chord == shortcut.chord {
      return .chordAlreadyRegistered(chord: shortcut.chord, existingID: id)
    }
    return nil
  }

  private func startBackendIfNeeded() throws {
    guard !backendStarted else { return }
    try backend.start(owner: self)
    backendStarted = true
  }

  private func stopBackendIfUnused() {
    guard registrations.isEmpty, backendStarted else { return }
    backend.stop()
    backendStarted = false
  }
}
