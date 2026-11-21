import Carbon.HIToolbox
import Foundation

/// One system-wide keyboard shortcut. Carbon's hot keys are the only API
/// that works without the Accessibility permission.
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    /// Called on the main thread when the shortcut is pressed.
    var onPress: (() -> Void)?

    /// Listens for `shortcut`, replacing the one before. nil listens for
    /// nothing.
    func set(_ shortcut: Shortcut?) {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        guard let shortcut else { return }
        installHandlerOnce()
        let id = EventHotKeyID(signature: OSType(0x646D_6272) /* "dmbr" */, id: 1)
        RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &ref)
    }

    private func installHandlerOnce() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // Carbon delivers hot keys on the main thread's event loop.
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return noErr }
            let me = Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { me.onPress?() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
}
