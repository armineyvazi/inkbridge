import Carbon.HIToolbox

/// System-wide keyboard shortcuts.
///
/// The app never becomes active while the user annotates (the toolbar is a
/// non-activating panel), so ordinary menu key equivalents would not fire.
/// Carbon hot keys are delivered regardless of which app is frontmost and,
/// unlike a global event monitor, need no Accessibility permission.
final class HotKeyCenter {
  private var refs: [EventHotKeyRef?] = []
  private var actions: [UInt32: () -> Void] = [:]
  private var handler: EventHandlerRef?

  static let controlOption = UInt32(controlKey | optionKey)
  static let controlOptionShift = UInt32(controlKey | optionKey | shiftKey)

  init() {
    var spec = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(
      GetApplicationEventTarget(),
      { _, event, userData in
        guard let event, let userData else { return OSStatus(eventNotHandledErr) }
        var id = EventHotKeyID()
        GetEventParameter(
          event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
          nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
        let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
        center.actions[id.id]?()
        return noErr
      }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
  }

  deinit {
    refs.forEach { if let r = $0 { UnregisterEventHotKey(r) } }
    if let handler { RemoveEventHandler(handler) }
  }

  /// Registers `keyCode` (a `kVK_*` constant) with Carbon modifier flags.
  func register(_ keyCode: Int, modifiers: UInt32 = controlOption, _ action: @escaping () -> Void) {
    let id = UInt32(actions.count + 1)
    actions[id] = action
    var ref: EventHotKeyRef?
    // 'INKB' namespaces our IDs from other hot keys in the process.
    let hotKeyID = EventHotKeyID(signature: OSType(0x494E_4B42), id: id)
    RegisterEventHotKey(UInt32(keyCode), modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
    refs.append(ref)
  }
}
