import Carbon
import Foundation

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
  guard status == noErr, hotKeyID.id == 1 else {
    return OSStatus(eventNotHandledErr)
  }
  let owner = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
  Task { @MainActor in owner.invoke() }
  return noErr
}

@MainActor
final class GlobalHotKey {
  private static let signature: OSType = 0x4245_5847  // BEXG

  private let action: @MainActor () -> Void
  private var hotKeyReference: EventHotKeyRef?
  private var eventHandlerReference: EventHandlerRef?

  init(action: @escaping @MainActor () -> Void) {
    self.action = action
  }

  func register() throws {
    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed)
    )
    let context = Unmanaged.passUnretained(self).toOpaque()
    let installStatus = InstallEventHandler(
      GetEventDispatcherTarget(),
      globalHotKeyEventHandler,
      1,
      &eventType,
      context,
      &eventHandlerReference
    )
    guard installStatus == noErr else {
      throw HotKeyRegistrationError.failed
    }

    let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
    let registerStatus = RegisterEventHotKey(
      UInt32(kVK_ANSI_G),
      UInt32(cmdKey | shiftKey),
      hotKeyID,
      GetEventDispatcherTarget(),
      0,
      &hotKeyReference
    )
    guard registerStatus == noErr else {
      if let eventHandlerReference {
        RemoveEventHandler(eventHandlerReference)
        self.eventHandlerReference = nil
      }
      throw HotKeyRegistrationError.failed
    }
  }

  func unregister() {
    if let hotKeyReference {
      UnregisterEventHotKey(hotKeyReference)
      self.hotKeyReference = nil
    }
    if let eventHandlerReference {
      RemoveEventHandler(eventHandlerReference)
      self.eventHandlerReference = nil
    }
  }

  fileprivate func invoke() {
    action()
  }
}

private enum HotKeyRegistrationError: Error {
  case failed
}
