import AppKit
import Carbon
import Carbon.HIToolbox

/// Carbon event handler: checks the fired hotkey ID matches this instance before dispatching.
private func globalHotKeyCarbonHandler(
    nextHandler: EventHandlerCallRef?,
    theEvent: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData, let theEvent else { return OSStatus(eventNotHandledErr) }
    let owner = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()

    // Extract the hotkey ID from the event so multiple GlobalHotKey instances
    // don't cross-fire each other's handlers.
    var firedID = EventHotKeyID()
    let err = GetEventParameter(
        theEvent,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &firedID
    )
    guard err == noErr,
          firedID.signature == owner.signatureOSType,
          firedID.id == owner.currentHotKeyID else {
        return OSStatus(eventNotHandledErr)
    }

    DispatchQueue.main.async { owner.invokeHandler() }
    return noErr
}

/// Registers a system-wide hot key via Carbon `RegisterEventHotKey`.
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    let signatureOSType: OSType
    private(set) var currentHotKeyID: UInt32 = 0
    private var hotKeyIDCounter: UInt32 = 0

    private let keyCode: UInt32
    private let carbonModifiers: UInt32
    private let handler: () -> Void

    /// - Parameters:
    ///   - signature: Unique 4-byte OSType for this hotkey slot. Use distinct values for each
    ///     `GlobalHotKey` instance so the carbon handler can route correctly.
    init(keyCode: UInt32, modifiers: UInt32, signature: OSType = 0x51_50_48_4B, callback: @escaping () -> Void) {
        self.keyCode = keyCode
        self.carbonModifiers = modifiers
        self.signatureOSType = signature
        self.handler = callback
    }

    deinit { unregister() }

    fileprivate func invokeHandler() { handler() }

    @discardableResult
    func register() -> Bool {
        unregister()

        hotKeyIDCounter += 1
        currentHotKeyID = hotKeyIDCounter
        let hotKeyID = EventHotKeyID(signature: signatureOSType, id: currentHotKeyID)

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
        if let hk = hotKeyRef { UnregisterEventHotKey(hk); hotKeyRef = nil }
        if let eh = eventHandler { RemoveEventHandler(eh); eventHandler = nil }
        currentHotKeyID = 0
    }
}
