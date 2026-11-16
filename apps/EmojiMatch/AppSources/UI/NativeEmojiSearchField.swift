import AppKit
import SwiftUI

struct NativeEmojiSearchField: NSViewRepresentable {
  @Binding var text: String
  let onFocusSearch: () -> Void
  let onKeyDown: (NSEvent, NSTextView) -> Bool

  func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }

  func makeNSView(context: Context) -> NSSearchField {
    let field = NSSearchField()
    field.font = .systemFont(ofSize: EmojiPickerMetrics.searchFontSize)
    field.controlSize = .large
    field.drawsBackground = false
    field.backgroundColor = .clear
    field.placeholderString = String(localized: .emSearchPlaceholder)
    field.setAccessibilityLabel(String(localized: .emSearchPlaceholder))
    field.maximumRecents = 0
    field.sendsSearchStringImmediately = true
    field.sendsWholeSearchString = false
    field.delegate = context.coordinator
    field.target = context.coordinator
    field.action = #selector(Coordinator.searchChanged(_:))
    context.coordinator.installMonitor(for: field)
    return field
  }

  func updateNSView(_ field: NSSearchField, context: Context) {
    context.coordinator.parent = self
    field.controlSize = .large
    if field.stringValue != text, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true {
      field.stringValue = text
    }
    field.focusRingType = .default
  }

  func sizeThatFits(
    _ proposal: ProposedViewSize, nsView: NSSearchField, context: Context
  ) -> CGSize? {
    CGSize(width: proposal.width ?? 265, height: EmojiPickerMetrics.searchHeight)
  }

  static func dismantleNSView(_ field: NSSearchField, coordinator: Coordinator) {
    coordinator.stop()
    field.delegate = nil
    field.target = nil
    field.action = nil
  }

  static func focus(in window: NSWindow?) {
    func find(in view: NSView) -> NSSearchField? {
      if let field = view as? NSSearchField { return field }
      return view.subviews.lazy.compactMap { find(in: $0) }.first
    }
    guard let window, let content = window.contentView, let field = find(in: content) else {
      return
    }
    window.makeFirstResponder(field)
  }

  final class Coordinator: NSObject, NSSearchFieldDelegate {
    var parent: NativeEmojiSearchField
    private var monitor: Any?

    init(parent: NativeEmojiSearchField) {
      self.parent = parent
    }

    func installMonitor(for field: NSSearchField) {
      monitor = NSEvent.addLocalMonitorForEvents(
        matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
      ) { [weak self, weak field] event in
        guard let self, let field, let window = field.window, event.window === window else {
          return event
        }
        if event.type != .keyDown {
          if field.bounds.contains(field.convert(event.locationInWindow, from: nil)) {
            parent.onFocusSearch()
          }
          return event
        }
        guard let editor = field.currentEditor() as? NSTextView,
          window.firstResponder === editor
        else { return event }
        return parent.onKeyDown(event, editor) ? nil : event
      }
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
      parent.onFocusSearch()
    }

    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSSearchField else { return }
      searchChanged(field)
    }

    @objc func searchChanged(_ field: NSSearchField) {
      guard (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
      parent.text = field.stringValue
    }

    func stop() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }
  }
}
