import AppKit
import SwiftUI

/// The composer's text and caret, and the edits the app makes to them.
///
/// The text view is the source of truth and this mirrors it. SwiftUI's
/// `TextField` was dropped because changes made to its binding while keys
/// were arriving didn't always reach the screen: a sent message stayed in
/// the field and was sent again, and an inserted emoji was typed over.
@Observable
final class Composer {
    /// What is typed.
    private(set) var text = ""
    /// The caret, as a UTF-16 offset into `text`.
    private(set) var caret = 0
    /// The field's height: the text's, from one line up to five.
    private(set) var height: CGFloat = Composer.line

    private static let line = ceil(ComposerField.font.ascender - ComposerField.font.descender + ComposerField.font.leading)

    @ObservationIgnored fileprivate weak var view: NSTextView?

    var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The caret as an index into `text`.
    var caretIndex: String.Index { String.Index(utf16Offset: min(caret, text.utf16.count), in: text) }

    /// Replaces part of the text and puts the caret after the new part.
    func replace(_ range: Range<String.Index>, with new: String) {
        guard let view else { return }
        let r = NSRange(range, in: text)
        if view.shouldChangeText(in: r, replacementString: new) {
            view.replaceCharacters(in: r, with: new)
            view.didChangeText()
        }
        view.setSelectedRange(NSRange(location: r.location + new.utf16.count, length: 0))
        sync()
    }

    /// Types text at the caret, replacing any selection.
    func insert(_ new: String) {
        guard let view else { return }
        view.insertText(new, replacementRange: view.selectedRange())
        sync()
    }

    func clear() {
        view?.string = ""
        // Typing's undo is registered on the text storage, not the view, and
        // undoing it into the emptied view raises a range exception. The
        // composer has its own undo manager, so this leaves other fields'.
        view?.undoManager?.removeAllActions()
        sync()
    }

    func focus() {
        guard let view else { return }
        view.window?.makeFirstResponder(view)
    }

    fileprivate func sync() {
        guard let view else { return }
        if text != view.string { text = view.string }
        let c = view.selectedRange().location
        if caret != c { caret = c }
        if let container = view.textContainer, let layout = view.layoutManager {
            layout.ensureLayout(for: container)
            let h = min(max(ceil(layout.usedRect(for: container).height), Self.line), Self.line * 5)
            if height != h { height = h }
        }
    }
}

/// Keys the composer hands to the conversation before the text view acts on
/// them. The handler returns whether it used the key.
enum ComposerKey {
    case send, tab, up, down, escape
}

/// A plain multi-line text view for the composer, one to five lines high.
struct ComposerField: NSViewRepresentable {
    var composer: Composer
    var placeholder: String
    var onKey: (ComposerKey) -> Bool

    static let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        let view = scroll.documentView as! NSTextView
        view.delegate = context.coordinator
        view.font = Self.font
        view.textColor = .labelColor
        view.insertionPointColor = .labelColor
        view.drawsBackground = false
        view.isRichText = false
        view.allowsUndo = true
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.setAccessibilityLabel(placeholder)
        composer.view = view
        composer.sync()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerField
        init(parent: ComposerField) { self.parent = parent }

        /// The composer's own undo history, so clearing it on send leaves the
        /// window's alone.
        let undo = UndoManager()
        func undoManager(for view: NSTextView) -> UndoManager? { undo }

        func textDidChange(_ notification: Notification) { parent.composer.sync() }
        func textViewDidChangeSelection(_ notification: Notification) { parent.composer.sync() }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                // Shift-Return is a new line; Return alone is the conversation's.
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { return false }
                return parent.onKey(.send)
            case #selector(NSResponder.insertTab(_:)):
                if !parent.onKey(.tab) { textView.window?.selectNextKeyView(nil) }
                return true
            case #selector(NSResponder.moveUp(_:)): return parent.onKey(.up)
            case #selector(NSResponder.moveDown(_:)): return parent.onKey(.down)
            case #selector(NSResponder.cancelOperation(_:)):
                if parent.onKey(.escape) { return true }
                // Not the text view's completion list: pass it on, where
                // Escape goes back or closes the popover.
                textView.nextResponder?.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: nil)
                return true
            default: return false
            }
        }
    }
}
