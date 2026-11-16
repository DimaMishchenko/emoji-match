import AppKit
import SwiftUI

struct ScreenAnchoredButton: NSViewRepresentable {
  let title: String
  let action: (CGRect) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(action: action)
  }

  func makeNSView(context: Context) -> NSButton {
    let button = NSButton(
      title: title, target: context.coordinator, action: #selector(Coordinator.click(_:)))
    button.bezelStyle = .rounded
    button.setContentHuggingPriority(.required, for: .horizontal)
    button.setContentCompressionResistancePriority(.required, for: .horizontal)
    return button
  }

  func updateNSView(_ button: NSButton, context: Context) {
    button.title = title
    context.coordinator.action = action
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? {
    nsView.intrinsicContentSize
  }

  final class Coordinator: NSObject {
    var action: (CGRect) -> Void

    init(action: @escaping (CGRect) -> Void) {
      self.action = action
    }

    @objc func click(_ sender: NSButton) {
      guard let window = sender.window else { return }
      action(window.convertToScreen(sender.convert(sender.bounds, to: nil)))
    }
  }
}
