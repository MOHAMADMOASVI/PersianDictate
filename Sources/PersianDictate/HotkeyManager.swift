import Carbon

/// Registers one system-wide hotkey via Carbon's RegisterEventHotKey.
final class HotkeyManager {
    private static let signature: OSType = 0x5044_4354 // 'PDCT'
    private static var nextID: UInt32 = 1

    private let keyCode: UInt32
    private let modifiers: UInt32
    private let id: UInt32
    private let action: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// Defaults to Cmd+Shift+D.
    init(keyCode: Int = kVK_ANSI_D,
         modifiers: Int = cmdKey | shiftKey,
         action: @escaping () -> Void) {
        self.keyCode = UInt32(keyCode)
        self.modifiers = UInt32(modifiers)
        self.id = HotkeyManager.nextID
        HotkeyManager.nextID += 1
        self.action = action
    }

    deinit { unregister() }

    @discardableResult
    func register() -> Bool {
        unregister()

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()

        let installStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event,
                                           EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID),
                                           nil,
                                           MemoryLayout<EventHotKeyID>.size,
                                           nil,
                                           &hotKeyID)
            guard status == noErr else { return status }

            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            guard hotKeyID.signature == HotkeyManager.signature, hotKeyID.id == manager.id else {
                return OSStatus(eventNotHandledErr)
            }
            DispatchQueue.main.async { manager.action() }
            return noErr
        }, 1, &spec, context, &handlerRef)
        guard installStatus == noErr else { return false }

        let hotKeyID = EventHotKeyID(signature: HotkeyManager.signature, id: id)
        let registerStatus = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                                 GetApplicationEventTarget(), 0, &hotKeyRef)
        if registerStatus != noErr {
            unregister()
            return false
        }
        return true
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
    }
}
