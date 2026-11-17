import AppKit
import DesignSystem
import ObjectiveC.runtime
import Observation
import QuartzCore
import SwiftUI

extension EnvironmentValues {
  @Entry var emojiMatchPresentation: EmojiMatchPanelPresentation?
}

@Observable
final class EmojiMatchPanelPresentation {
  private(set) var showsHeaderClose = false
  @ObservationIgnored var onDetach: (() -> Void)?
  @ObservationIgnored var resolveCloseButton: ((NSWindow) -> NSButton?)?
  @ObservationIgnored weak var closeButtonHost: EmojiMatchCloseButtonHost?
  @ObservationIgnored private var isReconciling = false

  func beginDrag() { onDetach?() }

  func attach(_ host: EmojiMatchCloseButtonHost) {
    closeButtonHost = host
    host.presentation = self
    reconcile()
  }

  func didDetach() {
    showsHeaderClose = true
    reconcile()
  }

  func suppressUnplaced(_ button: NSButton?) {
    guard let button, closeButtonHost?.contains(button) != true else { return }
    button.alphaValue = 0
  }

  func reconcile() {
    guard !isReconciling, let host = closeButtonHost, let window = host.window else { return }
    isReconciling = true
    defer { isReconciling = false }
    guard let button = resolveCloseButton?(window), button.window === window else { return }
    if host.contains(button) { return }
    button.alphaValue = 0
    showsHeaderClose = true
    host.install(button)
  }
}

struct EmojiMatchNativeCloseButton: NSViewRepresentable {
  let presentation: EmojiMatchPanelPresentation?

  func makeNSView(context: Context) -> EmojiMatchCloseButtonHost {
    let view = EmojiMatchCloseButtonHost()
    presentation?.attach(view)
    return view
  }

  func updateNSView(_ nsView: EmojiMatchCloseButtonHost, context: Context) {
    presentation?.attach(nsView)
  }

  static func dismantleNSView(_ nsView: EmojiMatchCloseButtonHost, coordinator: ()) {
    nsView.stopReveal()
  }
}

final class EmojiMatchCloseButtonHost: NSView {
  weak var presentation: EmojiMatchPanelPresentation?
  private var closeButton: NSButton?
  private var nativeSize = NSSize.zero
  private weak var searchField: NSTextField?
  private var revealTimer: Timer?

  func contains(_ button: NSButton) -> Bool {
    closeButton === button && button.superview === self
  }

  func install(_ button: NSButton) {
    guard !contains(button) else { return }
    stopReveal()
    closeButton?.removeFromSuperview()
    button.alphaValue = 0
    button.sizeToFit()
    nativeSize = button.frame.size
    button.removeFromSuperview()
    button.translatesAutoresizingMaskIntoConstraints = true
    button.autoresizingMask = []
    closeButton = button
    addSubview(button)
    searchField = window?.contentView?.emojiMatchSearchField
    layoutCloseButton()
    scheduleReveal()
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if newWindow !== window {
      stopReveal()
      closeButton?.alphaValue = 0
    }
    super.viewWillMove(toWindow: newWindow)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    searchField = window?.contentView?.emojiMatchSearchField
    presentation?.reconcile()
    if let closeButton, contains(closeButton), closeButton.alphaValue < 1 { scheduleReveal() }
  }

  override func layout() {
    super.layout()
    presentation?.reconcile()
    layoutCloseButton()
  }

  private func scheduleReveal() {
    stopReveal()
    guard let button = closeButton, let window else { return }
    let delay =
      NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : Double.ds.motion.quick
    let timer = Timer(timeInterval: delay, repeats: false) {
      [weak self, weak button, weak window] _ in
      MainActor.assumeIsolated {
        guard let self, let button, let window, self.window === window,
          button.window === window, self.contains(button),
          self.presentation?.closeButtonHost === self, window.isVisible
        else { return }
        self.revealTimer = nil
        self.layoutSubtreeIfNeeded()
        self.layoutCloseButton()
        NSAnimationContext.runAnimationGroup { context in
          context.duration =
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : .ds.motion.quick
          context.timingFunction = CAMediaTimingFunction(name: .easeOut)
          button.animator().alphaValue = 1
        }
      }
    }
    revealTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  func stopReveal() {
    revealTimer?.invalidate()
    revealTimer = nil
  }

  private func layoutCloseButton() {
    let centerY = searchField.map { convert($0.bounds, from: $0).midY } ?? bounds.midY
    closeButton?.frame = NSRect(
      x: bounds.midX - nativeSize.width / 2, y: centerY - nativeSize.height / 2,
      width: nativeSize.width, height: nativeSize.height)
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let view = super.hitTest(point)
    return view === self ? nil : view
  }
}

@MainActor
final class EmojiMatchPanel<Content: View>: NSPanel, NSPopoverDelegate {
  private let picker = NSPopover()
  private let presentation = EmojiMatchPanelPresentation()
  private let onClose: () -> Void
  private var isClosing = false
  private var nativeDetachmentRequested = false
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
    presentation.onDetach = { [weak self] in self?.detachPicker() }
    presentation.resolveCloseButton = { [weak self] window in
      guard let self, !self.isClosing,
        self.picker.contentViewController?.view.window === window,
        let button = self.nativeCloseButton(in: window),
        self.picker.isDetached
          || (self.nativeDetachmentRequested && !button.isHiddenOrHasHiddenAncestor)
      else { return nil }
      return button
    }
    picker.contentViewController = NSHostingController(
      rootView: content({ [weak self] in self?.close() })
        .environment(\.emojiMatchPresentation, presentation)
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
    if let window = picker.contentViewController?.view.window {
      presentation.suppressUnplaced(nativeCloseButton(in: window, includingHidden: true))
    }
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
    localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [
      .leftMouseDown, .rightMouseDown, .leftMouseDragged
    ]
    ) {
      [weak self] event in
      guard let self, let window = self.picker.contentViewController?.view.window else {
        return event
      }
      if event.type == .leftMouseDragged {
        self.presentation.reconcile()
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
    guard let view = picker.contentViewController?.view,
      let field = view.emojiMatchSearchField
    else { return }
    view.window?.makeFirstResponder(field)
  }

  func popoverShouldDetach(_ popover: NSPopover) -> Bool {
    nativeDetachmentRequested = true
    if let window = popover.contentViewController?.view.window {
      presentation.suppressUnplaced(nativeCloseButton(in: window, includingHidden: true))
    }
    presentation.reconcile()
    return true
  }

  private func detachPicker() {
    guard !isClosing, picker.isShown else { return }
    if !picker.isDetached {
      let selector = NSSelectorFromString("detach")
      guard let method = class_getInstanceMethod(type(of: picker), selector),
        method_getNumberOfArguments(method) == 2
      else { return }
      let returnType = method_copyReturnType(method)
      defer { free(returnType) }
      guard String(cString: returnType) == "v" else { return }
      typealias Detach = @convention(c) (AnyObject, Selector) -> Void
      let detach = unsafeBitCast(method_getImplementation(method), to: Detach.self)
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      defer { CATransaction.commit() }
      if let window = picker.contentViewController?.view.window {
        nativeCloseButton(in: window)?.alphaValue = 0
      }
      detach(picker, selector)
    }
    if picker.isDetached { popoverDidDetach(picker) }
  }

  func popoverDidDetach(_ popover: NSPopover) {
    guard popover === picker, popover.isDetached, !isClosing else { return }
    if let window = popover.contentViewController?.view.window {
      window.isMovable = true
      window.isMovableByWindowBackground = true
      presentation.suppressUnplaced(nativeCloseButton(in: window))
    }
    presentation.didDetach()
  }

  private func nativeCloseButton(in window: NSWindow, includingHidden: Bool = false) -> NSButton? {
    if let button = window.standardWindowButton(.closeButton) { return button }
    var candidates: [NSButton] = []
    var inspected = 0
    var complete = true
    func visit(_ view: NSView, depth: Int) {
      inspected += 1
      guard depth < 12, inspected <= 256 else { complete = false; return }
      if let button = view as? NSButton, button.accessibilitySubrole() == .closeButton,
        includingHidden || !button.isHiddenOrHasHiddenAncestor
      {
        candidates.append(button)
      }
      for child in view.subviews { visit(child, depth: depth + 1) }
    }
    if let root = window.contentView?.superview ?? window.contentView { visit(root, depth: 0) }
    return complete && candidates.count == 1 ? candidates.first : nil
  }

  func popoverDidClose(_ notification: Notification) {
    close()
  }

  override func close() {
    guard !isClosing else { return }
    isClosing = true
    presentation.resolveCloseButton = nil
    presentation.closeButtonHost?.stopReveal()
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

private extension NSView {
  var emojiMatchSearchField: NSTextField? {
    if let field = self as? NSTextField { return field }
    return subviews.lazy.compactMap(\.emojiMatchSearchField).first
  }
}
