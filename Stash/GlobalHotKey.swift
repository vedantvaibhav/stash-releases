import AppKit
import Carbon
import Carbon.HIToolbox

/// Carbon event handler: forwards hot-key presses to the owning `GlobalHotKey` on the main queue.
private func globalHotKeyCarbonHandler(
    nextHandler: EventHandlerCallRef?,
    theEvent: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let owner = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
    DispatchQueue.main.async {
        owner.invokeHandler()
    }
    return noErr
}

/// Registers a system-wide hot key via Carbon `RegisterEventHotKey` (e.g. ⌘⇧Space).
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let signatureOSType: OSType = 0x51_50_48_4B // 'QPHK'
    private var hotKeyIDCounter: UInt32 = 0

    private let keyCode: UInt32
    private let carbonModifiers: UInt32
    private let handler: () -> Void

    init(keyCode: UInt32, modifiers: UInt32, callback: @escaping () -> Void) {
        self.keyCode = keyCode
        self.carbonModifiers = modifiers
        self.handler = callback
    }

    deinit {
        unregister()
        unregister()
    }

    fileprivate func invokeHandler() {
        handler()
    }

    @discardableResult
    func register() -> Bool {
        unregister()

        hotKeyIDCounter += 1
        let hotKeyID = EventHotKeyID(signature: signatureOSType, id: hotKeyIDCounter)
        
        

        var eventSpec = EventTypeSpec(eventClass: UInt32(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        var newHandler: EventHandlerRef?
        var err = InstallEventHandler(
            GetApplicationEventTarget(),
            globalHotKeyCarbonHandler,
            1,
            &eventSpec,
            selfPtr,
            &newHandler
        )
        guard err == noErr, let h = newHandler else { return false }
        eventHandler = h

        var newHotKey: EventHotKeyRef?
        err = RegisterEventHotKey(keyCode, carbonModifiers, hotKeyID, GetApplicationEventTarget(), 0, &newHotKey)
        guard err == noErr, let hk = newHotKey else {
            RemoveEventHandler(h)
            eventHandler = nil
            return false
        }
        hotKeyRef = hk
        return true
    }

    func unregister() {
        if let hk = hotKeyRef {
            UnregisterEventHotKey(hk)
            hotKeyRef = nil
        }
        if let eh = eventHandler {
            RemoveEventHandler(eh)
            eventHandler = nil
        }
    }
}
