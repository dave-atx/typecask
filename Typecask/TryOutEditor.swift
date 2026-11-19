import CoreText
import SwiftUI
import UIKit

/// Try It Out's text: a UITextView of its own rather than SwiftUI's TextEditor, which scrolled back to the insertion
/// point whenever its font changed, so turning a feature on while reading further down jumped the text away. Here a
/// new font, size, line height or alignment restyles the text where it is and leaves the scroll position alone.
struct TryOutEditor: UIViewRepresentable {
    @Binding var text: String
    let font: CTFont
    let lineSpacing: CGFloat
    let alignment: TextAlignment
    /// Whether the keyboard is up. Typing sets it; clearing it puts the keyboard away.
    @Binding var isEditing: Bool

    func makeUIView(context: Context) -> TextView {
        let view = TextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.textContainerInset = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        view.alwaysBounceVertical = true
        view.keyboardDismissMode = .interactive
        view.accessibilityIdentifier = "tryItOutText"
        view.text = text
        restyle(view)
        return view
    }

    func updateUIView(_ view: TextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text {
            // Restore Sample Text, or the line a feature was opened with: new text, styled as the rest.
            view.text = text
            restyle(view)
        } else if context.coordinator.style != style {
            view.holdingScroll { restyle(view) }
        }
        context.coordinator.style = style
        if !isEditing, view.isFirstResponder {
            view.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    /// What the text is set in, compared to tell a restyle from an edit.
    struct Style: Equatable {
        let font: CTFont
        let lineSpacing: CGFloat
        let alignment: TextAlignment

        static func == (lhs: Style, rhs: Style) -> Bool {
            CFEqual(lhs.font, rhs.font) && lhs.lineSpacing == rhs.lineSpacing && lhs.alignment == rhs.alignment
        }
    }

    private var style: Style { Style(font: font, lineSpacing: lineSpacing, alignment: alignment) }

    private var attributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.alignment = switch alignment {
        case .leading: .natural
        case .center: .center
        case .trailing: UIApplication.shared.userInterfaceLayoutDirection == .rightToLeft ? .left : .right
        }
        return [.font: font as UIFont, .paragraphStyle: paragraph, .foregroundColor: UIColor.label]
    }

    /// Sets the whole text, and what's typed next, in the style. Through the text storage, not attributedText, which
    /// would move the selection to the end.
    private func restyle(_ view: UITextView) {
        let attributes = attributes
        let storage = view.textStorage
        storage.beginEditing()
        storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
        storage.endEditing()
        view.typingAttributes = attributes
    }

    /// A text view that can be restyled without scrolling to its insertion point, as UIKit does after any change to
    /// the text while it's being edited, and not right away but once it next lays out.
    final class TextView: UITextView {
        private var holds = 0

        func holdingScroll(_ change: () -> Void) {
            // The character at the top stays at the top, though a feature reflows the text above it.
            let top = CGPoint(x: bounds.midX, y: contentOffset.y + adjustedContentInset.top)
            let anchor = closestPosition(to: top)
            let above = anchor.map { caretRect(for: $0).minY - contentOffset.y }
            let selection = selectedRange
            holds += 1
            change()
            selectedRange = selection
            layoutIfNeeded()
            let restore = { [self] in
                guard let anchor, let above else { return }
                contentOffset = clamped(CGPoint(x: contentOffset.x, y: caretRect(for: anchor).minY - above))
            }
            restore()
            // UIKit's scroll to the insertion point comes on a later pass.
            DispatchQueue.main.async { [self] in
                restore()
                holds -= 1
            }
        }

        override func scrollRectToVisible(_ rect: CGRect, animated: Bool) {
            guard holds == 0 else { return }
            super.scrollRectToVisible(rect, animated: animated)
        }

        override func setContentOffset(_ offset: CGPoint, animated: Bool) {
            guard holds == 0 else { return }
            super.setContentOffset(offset, animated: animated)
        }

        /// The offset, kept within the text, which a restyle can shorten.
        private func clamped(_ offset: CGPoint) -> CGPoint {
            let top = -adjustedContentInset.top
            let bottom = max(contentSize.height + adjustedContentInset.bottom - bounds.height, top)
            return CGPoint(x: offset.x, y: min(max(offset.y, top), bottom))
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: TryOutEditor
        var style: Style?

        init(parent: TryOutEditor) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.isEditing = true
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.isEditing = false
        }
    }
}
