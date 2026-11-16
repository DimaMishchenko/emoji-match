import AppKit
import SwiftUI

@MainActor
final class EmojiMatchPanel<Content: View>: NSPanel, NSPopoverDelegate {
  private let picker = NSPopover()
  private let onClose: () -> Void
  private var isClosing = false
  private var outsideClickMonitor: Any?
  private var localClickMonitor: Any?

  init(
    contentSize: CGSize,
    onClose: @escaping () -> Void = {},
    @ViewBuilder content:
      @escaping (
        _ close: @escaping () -> Void
      ) -> Content
  ) {
    self.onClose = onClose
    super
      .init(
        contentRect: .zero,
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
      )
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    ignoresMouseEvents = true
    hidesOnDeactivate = false
    level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)))
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    contentView = NSView()
    picker.behavior = .transient
    picker.animates = false
    picker.delegate = self
    picker.contentViewController = NSHostingController(
      rootView: content(
        { [weak self] in self?.close() }
      )
    )
    picker.contentSize = contentSize
  }

  func show(anchorRect: CGRect?) {
    let rect: CGRect
    if let anchorRect {
      rect = EmojiMatchPanelGeometry.appKitRect(
        fromTopLeftRect: anchorRect,
        primaryScreenHeight: NSScreen.screens.first?.frame.maxY ?? 0
      )
    } else {
      let screen =
        NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
      let visibleFrame = screen?.visibleFrame ?? .zero
      rect = CGRect(x: visibleFrame.midX, y: visibleFrame.midY, width: 1, height: 1)
    }
    setFrame(
      CGRect(x: rect.minX, y: rect.minY, width: max(rect.width, 3), height: max(rect.height, 1)),
      display: false
    )
    guard let contentView else { return }
    orderFrontRegardless()
    picker.show(relativeTo: contentView.bounds, of: contentView, preferredEdge: .minY)
    picker.contentViewController?.view.window?.makeKey()
    installDismissalMonitors()
    DispatchQueue.main.async { [weak self] in self?.focusSearchField() }
  }

  private func installDismissalMonitors() {
    outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [
      .leftMouseDown, .rightMouseDown
    ]) {
      [weak self] _ in
      MainActor.assumeIsolated { self?.close() }
    }
    localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]
    ) {
      [weak self] event in
      guard let self, let window = self.picker.contentViewController?.view.window else {
        return event
      }
      let point = NSEvent.mouseLocation
      let auxiliary = NSApp.windows
        .filter {
          $0 !== window && $0.isVisible
            && ($0.parent === window || $0.level.rawValue >= NSWindow.Level.popUpMenu.rawValue)
        }
        .map(\.frame)
      if EmojiMatchPanelGeometry.shouldDismissClick(
        at: point, picker: window.frame, auxiliary: auxiliary)
      {
        self.close()
      }
      return event
    }
  }

  private func focusSearchField() {
    func firstTextField(in view: NSView) -> NSTextField? {
      if let field = view as? NSTextField { return field }
      return view.subviews.lazy.compactMap { firstTextField(in: $0) }.first
    }
    guard let view = picker.contentViewController?.view,
      let field = firstTextField(in: view)
    else { return }
    view.window?.makeFirstResponder(field)
  }

  func popoverDidClose(_ notification: Notification) {
    close()
  }

  override func close() {
    guard !isClosing else { return }
    isClosing = true
    if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
    if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
    outsideClickMonitor = nil
    localClickMonitor = nil
    picker.close()
    super.close()
    onClose()
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

enum EmojiMatchPanelGeometry {
  nonisolated static func shouldDismissClick(
    at point: CGPoint, picker: CGRect, auxiliary: [CGRect]
  ) -> Bool {
    !picker.contains(point) && !auxiliary.contains { $0.contains(point) }
  }

  nonisolated static func appKitRect(
    fromTopLeftRect rect: CGRect, primaryScreenHeight: CGFloat
  ) -> CGRect {
    CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
  }

}
