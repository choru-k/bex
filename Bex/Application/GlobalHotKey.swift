import Carbon
import Foundation

private let bexHotKeySignature: OSType = 0x4245_5847  // BEXG

struct Shortcut: Equatable, Sendable {
  let id: UInt32
  let keyCode: UInt32
  let modifiers: UInt32
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

@MainActor
final class GlobalHotKey {

  private struct Registration {
    let reference: EventHotKeyRef
    let action: @MainActor () -> Void
  }

  private var registrations: [UInt32: Registration] = [:]
  private var eventHandlerReference: EventHandlerRef?

  func register(_ shortcut: Shortcut, action: @escaping @MainActor () -> Void) throws {
    guard registrations[shortcut.id] == nil else {
      throw HotKeyRegistrationError.duplicateID
    }
    try installEventHandlerIfNeeded()

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
    guard status == noErr, let reference else {
      if registrations.isEmpty {
        removeEventHandler()
      }
      throw HotKeyRegistrationError.failed
    }
    registrations[shortcut.id] = Registration(reference: reference, action: action)
  }

  func unregister(id: UInt32) {
    guard let registration = registrations.removeValue(forKey: id) else { return }
    UnregisterEventHotKey(registration.reference)
    if registrations.isEmpty {
      removeEventHandler()
    }
  }

  func unregisterAll() {
    for registration in registrations.values {
      UnregisterEventHotKey(registration.reference)
    }
    registrations.removeAll()
    removeEventHandler()
  }

  func handle(_ id: UInt32) {
    registrations[id]?.action()
  }

  private func installEventHandlerIfNeeded() throws {
    guard eventHandlerReference == nil else { return }
    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed)
    )
    let context = Unmanaged.passUnretained(self).toOpaque()
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
      throw HotKeyRegistrationError.failed
    }
  }

  private func removeEventHandler() {
    if let eventHandlerReference {
      RemoveEventHandler(eventHandlerReference)
      self.eventHandlerReference = nil
    }
  }
}

enum HotKeyRegistrationError: Error {
  case duplicateID
  case failed
}
