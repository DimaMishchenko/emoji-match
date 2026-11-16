import AppKit
import SwiftUI

struct NativeEmojiVariants: NSViewRepresentable {
  let identity: String
  let variants: [EmojiSelection]
  let labels: [String]
  @Binding var isPresented: Bool
  let onSelect: (EmojiSelection) -> Void

  func makeNSView(context: Context) -> EmojiVariantAnchor {
    EmojiVariantAnchor()
  }

  func sizeThatFits(
    _ proposal: ProposedViewSize, nsView: EmojiVariantAnchor, context: Context
  ) -> CGSize? {
    CGSize(width: EmojiPickerMetrics.emojiCellSize, height: EmojiPickerMetrics.emojiCellSize)
  }

  func updateNSView(_ view: EmojiVariantAnchor, context: Context) {
    if view.identity != identity {
      view.cancel()
      view.identity = identity
    }
    view.variants = variants
    view.labels = labels
    view.onSelect = onSelect
    view.onDismiss = { isPresented = false }
    view.requestsPresentation = isPresented
    if isPresented {
      DispatchQueue.main.async { [weak view] in
        guard let view, view.identity == identity, view.requestsPresentation else { return }
        view.requestsPresentation = false
        view.present(tracking: false)
      }
    }
  }

  static func dismantleNSView(_ view: EmojiVariantAnchor, coordinator: ()) {
    view.tearDown()
  }
}

final class EmojiVariantAnchor: NSView, NSPopoverDelegate {
  var identity = ""
  var variants: [EmojiSelection] = []
  var labels: [String] = []
  var onSelect: ((EmojiSelection) -> Void)?
  var onDismiss: (() -> Void)?
  var requestsPresentation = false
  private final class WeakAnchor {
    weak var value: EmojiVariantAnchor?
    init(_ value: EmojiVariantAnchor) { self.value = value }
  }

  private static var anchors: [ObjectIdentifier: WeakAnchor] = [:]
  private static var sourceMonitor: Any?
  private static weak var activeAnchor: EmojiVariantAnchor?
  private var sessionID = UUID()
  private var sessionMonitor: Any?
  private var outsideMonitor: Any?
  private var observers: [NSObjectProtocol] = []
  private var holdTimer: Timer?
  private var popover: NSPopover?
  private var choices: EmojiVariantChoices?
  private var pressLocation = NSPoint.zero
  private var tracksRelease = false
  private let nativeMenu = NativeSkinToneMenu()

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    tearDown()
    guard window != nil else { return }
    Self.anchors[ObjectIdentifier(self)] = WeakAnchor(self)
    guard Self.sourceMonitor == nil else { return }
    Self.sourceMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
      guard let window = event.window else { return event }
      let screenPoint = window.convertPoint(toScreen: event.locationInWindow)
      let candidates = Self.anchors.values.compactMap(\.value)
        .filter {
          $0.window === window && !$0.variants.isEmpty && $0.containsSource(screenPoint)
        }
      if candidates.count == 1, let anchor = candidates.first, anchor.popover == nil {
        anchor.beginPress(at: screenPoint)
      }
      return event
    }
  }

  private var sourceScreenRect: NSRect? {
    guard let window, window.isVisible, !isHiddenOrHasHiddenAncestor else { return nil }
    let visible = visibleRect.intersection(bounds)
    guard !visible.isEmpty else { return nil }
    return window.convertToScreen(convert(visible, to: nil))
  }

  func containsSource(_ screenPoint: NSPoint) -> Bool {
    sourceScreenRect?.contains(screenPoint) == true
  }

  private func beginPress(at screenPoint: NSPoint) {
    Self.activeAnchor?.cancel()
    cancel()
    Self.activeAnchor = self
    pressLocation = screenPoint
    installSessionMonitors()
    let currentSession = sessionID
    let timer = Timer(timeInterval: 0.45, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, Self.activeAnchor === self, self.sessionID == currentSession else { return }
        guard self.containsSource(NSEvent.mouseLocation), NSEvent.pressedMouseButtons & 1 != 0
        else { self.cancel(); return }
        self.present(tracking: true)
      }
    }
    holdTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  func present(tracking: Bool) {
    guard popover == nil, !nativeMenu.isPresenting,
      let window, window.isVisible, !variants.isEmpty
    else { return }
    if Self.activeAnchor !== self {
      Self.activeAnchor?.cancel()
      Self.activeAnchor = self
    }
    holdTimer?.invalidate()
    holdTimer = nil
    installSessionMonitors()
    if variants.count == 6 {
      let token = sessionID
      let presentationIdentity = identity
      let dismiss = onDismiss
      let select = onSelect
      if let sessionMonitor { NSEvent.removeMonitor(sessionMonitor) }
      if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
      sessionMonitor = nil
      outsideMonitor = nil
      let pinRect = window.contentView.map {
        $0.convert($0.bounds.insetBy(dx: 13, dy: 13), to: nil)
      }
      let handled = nativeMenu.present(
        variants: variants, source: self, byMouse: tracking,
        sourceRect: bounds.insetBy(dx: -6, dy: -1), boundingRectInWindow: pinRect
      ) { [weak self] selection in
        guard let self, self.sessionID == token, Self.activeAnchor === self else { return }
        self.cancel()
        dismiss?()
        select?(selection)
      }
      if handled {
        if sessionID == token, identity == presentationIdentity {
          cancel()
          dismiss?()
        }
        return
      }
      for observer in observers { NotificationCenter.default.removeObserver(observer) }
      observers.removeAll()
    }
    tracksRelease = tracking
    installSessionMonitors()
    let choices = EmojiVariantChoices(variants: variants, labels: labels)
    choices.onSelect = { [weak self] index in self?.select(index) }
    self.choices = choices
    let controller = NSViewController()
    controller.view = choices
    let popover = NSPopover()
    popover.contentViewController = controller
    popover.contentSize = choices.frame.size
    popover.behavior = .applicationDefined
    popover.animates = false
    popover.delegate = self
    self.popover = popover
    let anchor = NSRect(x: bounds.midX, y: bounds.maxY, width: 0, height: 0)
    popover.show(relativeTo: anchor, of: self, preferredEdge: .minY)
    if !tracking {
      choices.window?.makeFirstResponder(choices.buttons.first)
    }
  }

  private func installSessionMonitors() {
    guard sessionMonitor == nil else { return }
    sessionMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [
        .leftMouseDragged, .leftMouseUp, .leftMouseDown, .rightMouseDown, .mouseMoved, .keyDown,
        .scrollWheel
      ]
    ) { [weak self] event in
      guard let self else { return event }
      switch event.type {
      case .leftMouseDragged, .mouseMoved:
        if let choices = self.choices {
          choices.highlight(at: NSEvent.mouseLocation)
        } else if hypot(
          NSEvent.mouseLocation.x - self.pressLocation.x,
          NSEvent.mouseLocation.y - self.pressLocation.y) > 6
        {
          self.cancel()
        }
      case .leftMouseUp:
        if self.tracksRelease {
          let index = self.choices?.index(at: NSEvent.mouseLocation)
          if let index { self.select(index) } else { self.cancel() }
          return nil
        } else if self.popover == nil {
          self.cancel()
        }
      case .leftMouseDown, .rightMouseDown:
        if let choices = self.choices, event.window !== choices.window {
          self.cancel()
        }
      case .scrollWheel:
        if self.popover == nil || event.window !== self.choices?.window { self.cancel() }
      case .keyDown:
        guard event.window === self.window || event.window === self.choices?.window else {
          self.cancel()
          return event
        }
        if event.keyCode == 53 {
          self.cancel()
          return nil
        }
        if event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
          self.choices?.handleKey(event.keyCode) == true
        {
          return nil
        }
      default: break
      }
      return event
    }
    outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [
      .leftMouseUp, .leftMouseDown, .rightMouseDown
    ]) {
      [weak self] _ in
      MainActor.assumeIsolated { self?.cancel() }
    }
    let currentSession = sessionID
    let center = NotificationCenter.default
    observers.append(
      center.addObserver(
        forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
      ) {
        [weak self] _ in
        MainActor.assumeIsolated { self?.cancel() }
      })
    if let window {
      observers.append(
        center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) {
          [weak self] _ in
          MainActor.assumeIsolated { self?.cancel() }
        })
      observers.append(
        center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main)
        {
          [weak self] _ in
          Task { @MainActor [weak self] in
            guard let self, self.sessionID == currentSession,
              NSApp.keyWindow !== self.choices?.window,
              !self.nativeMenu.owns(NSApp.keyWindow)
            else { return }
            self.cancel()
          }
        })
    }
  }

  private func select(_ index: Int) {
    guard variants.indices.contains(index) else { cancel(); return }
    let selection = variants[index]
    cancel()
    onSelect?(selection)
  }

  func popoverDidClose(_ notification: Notification) {
    cancel()
  }

  func cancel() {
    let shouldDismiss = nativeMenu.isPresenting || popover != nil || requestsPresentation
    let dismiss = onDismiss
    requestsPresentation = false
    sessionID = UUID()
    nativeMenu.cancel()
    if Self.activeAnchor === self { Self.activeAnchor = nil }
    holdTimer?.invalidate()
    holdTimer = nil
    if let sessionMonitor { NSEvent.removeMonitor(sessionMonitor) }
    if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
    sessionMonitor = nil
    outsideMonitor = nil
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers.removeAll()
    tracksRelease = false
    let previous = popover
    popover = nil
    choices = nil
    previous?.delegate = nil
    previous?.close()
    if shouldDismiss { dismiss?() }
  }

  func tearDown() {
    cancel()
    Self.anchors.removeValue(forKey: ObjectIdentifier(self))
    Self.anchors = Self.anchors.filter { $0.value.value != nil }
    if Self.anchors.isEmpty, let sourceMonitor = Self.sourceMonitor {
      NSEvent.removeMonitor(sourceMonitor)
      Self.sourceMonitor = nil
    }
  }
}

final class EmojiVariantChoices: NSView {
  var onSelect: ((Int) -> Void)?
  private(set) var buttons: [NSButton] = []
  private let scrollView = NSScrollView()
  private let document = NSView()
  private(set) var selectedIndex: Int?

  init(variants: [EmojiSelection], labels: [String]) {
    let compact = variants.count <= 6
    let rows = (variants.count + 5) / 6
    let width: CGFloat = compact ? CGFloat(variants.count * 48 + 47) : 332
    let height: CGFloat = compact ? 48 : min(272, CGFloat(rows * 44 + 8))
    super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
    scrollView.frame = bounds
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = !compact && rows > 6
    scrollView.autohidesScrollers = true
    document.frame = NSRect(
      x: 0, y: 0, width: width, height: CGFloat(rows * 44 + (compact ? 4 : 8)))
    scrollView.documentView = document
    addSubview(scrollView)
    for (index, variant) in variants.enumerated() {
      let column = index % 6
      let row = index / 6
      let x = compact ? (index == 0 ? 10 : CGFloat(index * 48 + 31)) : CGFloat(column * 54 + 4)
      let y = document.frame.height - CGFloat((row + 1) * 44) - (compact ? 2 : 4)
      let button = NSButton(title: variant.value, target: self, action: #selector(choose(_:)))
      button.frame = NSRect(x: x, y: y, width: 54, height: 44)
      button.font = .systemFont(ofSize: 30)
      button.isBordered = false
      button.bezelStyle = .regularSquare
      button.setButtonType(.momentaryChange)
      button.tag = index
      button.toolTip = labels[index]
      button.setAccessibilityLabel(labels[index])
      button.wantsLayer = true
      button.layer?.cornerRadius = 6
      document.addSubview(button)
      buttons.append(button)
    }
    scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.frame.height - height)))
    scrollView.reflectScrolledClipView(scrollView.contentView)
    if compact && variants.count > 1 {
      let divider = NSBox(frame: NSRect(x: 71, y: 8, width: 1, height: 32))
      divider.boxType = .separator
      addSubview(divider)
    }
  }

  required init?(coder: NSCoder) { nil }

  func index(at screenPoint: NSPoint) -> Int? {
    guard let window else { return nil }
    let point = convert(window.convertPoint(fromScreen: screenPoint), from: nil)
    guard bounds.contains(point) else { return nil }
    let candidates = buttons.indices.filter { index in
      let button = buttons[index]
      return button.visibleRect.contains(button.convert(point, from: self))
    }
    return candidates.min { first, second in
      let firstCenter = convert(
        NSPoint(x: buttons[first].bounds.midX, y: buttons[first].bounds.midY), from: buttons[first])
      let secondCenter = convert(
        NSPoint(x: buttons[second].bounds.midX, y: buttons[second].bounds.midY),
        from: buttons[second])
      return abs(point.x - firstCenter.x) < abs(point.x - secondCenter.x)
    }
  }

  func highlight(at screenPoint: NSPoint) {
    let hovered = index(at: screenPoint)
    for (index, button) in buttons.enumerated() {
      button.layer?.backgroundColor =
        index == hovered
        ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.25).cgColor : nil
    }
  }

  @discardableResult
  func handleKey(_ keyCode: UInt16) -> Bool {
    guard !buttons.isEmpty else { return false }
    let focused = buttons.firstIndex { $0 === window?.firstResponder }
    let current = focused ?? selectedIndex ?? 0
    let next: Int
    switch keyCode {
    case 123: next = max(current / 6 * 6, current - 1)
    case 124: next = min(buttons.count - 1, current / 6 * 6 + 5, current + 1)
    case 125: next = min(buttons.count - 1, current + 6)
    case 126: next = max(0, current - 6)
    case 36, 49:
      onSelect?(current)
      return true
    default: return false
    }
    selectedIndex = next
    for (index, button) in buttons.enumerated() {
      button.layer?.backgroundColor =
        index == next
        ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.25).cgColor : nil
    }
    buttons[next].scrollToVisible(buttons[next].bounds)
    window?.makeFirstResponder(buttons[next])
    return true
  }

  @objc private func choose(_ sender: NSButton) {
    onSelect?(sender.tag)
  }
}
