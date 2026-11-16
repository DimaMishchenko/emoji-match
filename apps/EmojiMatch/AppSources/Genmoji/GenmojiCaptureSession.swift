import AppKit
import Darwin

@MainActor
final class GenmojiCaptureSession: NSObject, NSTextViewDelegate {
  enum Phase: String {
    case idle, activating, acquiringInput, ready, awaitingCapture, captured, cancelled, failed
  }

  struct Diagnostic {
    let phase: Phase
    let message: String
  }

  enum Failure: Error {
    case prohibitedActivationPolicy
    case creatorEntryUnavailable
    case activationRejected
    case activationTimedOut
    case inputOwnershipTimedOut
    case presentationTimedOut
  }

  var onCapture: ((NSAdaptiveImageGlyph) -> Void)?
  var onCancel: (() -> Void)?
  var onError: ((Failure) -> Void)?
  var onDiagnostic: ((Diagnostic) -> Void)?
  private(set) var phase: Phase = .idle

  private var generation = UUID()
  private var window: ReceiverWindow?
  private var receiver: ReceiverTextView?
  private var preparation: Task<Void, Never>?
  private var presentation: Task<Void, Never>?
  private var prompt = ""
  private var activationObserver: NSObjectProtocol?
  private var startingApplication: NSRunningApplication?
  private var creatorEntry: CreatorEntry?

  /// anchorRect uses AppKit global screen coordinates, with the origin at the bottom left.
  func start(prompt: String, anchorRect: CGRect? = nil) {
    teardown()
    let token = UUID()
    generation = token
    self.prompt = prompt
    startingApplication = NSWorkspace.shared.frontmostApplication
    guard NSApp.activationPolicy() != .prohibited else {
      fail(.prohibitedActivationPolicy, "A prohibited app cannot own the input session")
      return
    }
    guard let entry = CreatorEntry() else {
      fail(.creatorEntryUnavailable, "CharacterPicker creation-first entry is unavailable")
      return
    }
    creatorEntry = entry
    let anchor = anchorRect ?? defaultAnchor()
    let editor = ReceiverTextView(frame: NSRect(x: 0, y: 0, width: 2, height: 2))
    editor.anchorRect = anchor
    editor.isRichText = true
    editor.importsGraphics = true
    editor.isEditable = true
    editor.isSelectable = true
    editor.drawsBackground = false
    editor.focusRingType = .none
    editor.textColor = .clear
    editor.insertionPointColor = .clear
    editor.selectedTextAttributes = [
      .foregroundColor: NSColor.clear, .backgroundColor: NSColor.clear
    ]
    editor.string = prompt
    editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
    editor.delegate = self
    editor.onGlyph = { [weak self] glyph in self?.capture(glyph, token: token) }
    editor.onEscape = { [weak self] in self?.cancel() }
    let host = ReceiverWindow(
      contentRect: NSRect(x: anchor.minX, y: anchor.minY, width: 2, height: 2),
      styleMask: [.borderless], backing: .buffered, defer: false)
    host.isReleasedWhenClosed = false
    host.backgroundColor = .clear
    host.isOpaque = false
    host.hasShadow = false
    host.ignoresMouseEvents = true
    host.isExcludedFromWindowsMenu = true
    host.collectionBehavior = [.transient, .fullScreenAuxiliary]
    host.contentView = editor
    window = host
    receiver = editor
    activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { [weak self] notification in
      let application =
        notification.userInfo?[NSWorkspace.applicationUserInfoKey]
        as? NSRunningApplication
      MainActor.assumeIsolated {
        self?.applicationActivated(application, token: token)
      }
    }
    report(.activating, "Waiting for app activation; policy=\(NSApp.activationPolicy().rawValue)")
    guard generation == token else { return }
    if !NSApp.isActive, let application = startingApplication {
      guard NSRunningApplication.current.activate(from: application, options: []) else {
        fail(.activationRejected, "System rejected activation from the initiating application")
        return
      }
    } else if !NSApp.isActive {
      NSApp.activate()
    }
    preparation = Task { [weak self] in
      await self?.prepare(token: token)
    }
  }

  func cancel() {
    guard isRunning else { return }
    teardown()
    report(.cancelled, "Capture cancelled; no application was reactivated")
    onCancel?()
  }

  func textDidChange(_ notification: Notification) {
    guard let editor = notification.object as? ReceiverTextView, editor === receiver,
      let storage = editor.textStorage
    else { return }
    var selectedGlyph: NSAdaptiveImageGlyph?
    storage.enumerateAttribute(
      .adaptiveImageGlyph, in: NSRange(location: 0, length: storage.length)
    ) {
      value, _, stop in
      if let glyph = value as? NSAdaptiveImageGlyph {
        selectedGlyph = glyph
        stop.pointee = true
      }
    }
    if let selectedGlyph { capture(selectedGlyph, token: generation) }
  }

  private var isRunning: Bool {
    [.activating, .acquiringInput, .ready, .awaitingCapture].contains(phase)
  }

  private func prepare(token: UUID) async {
    for _ in 0..<100 {
      guard generation == token, !Task.isCancelled else { return }
      if NSApp.isActive { break }
      do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
    }
    guard generation == token, !Task.isCancelled else { return }
    guard NSApp.isActive else {
      fail(.activationTimedOut, "Activation did not complete within two seconds")
      return
    }
    guard let window, let receiver else { return }
    report(.acquiringInput, "App active; acquiring key window and native text input context")
    guard generation == token else { return }
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(receiver)
    receiver.inputContext?.activate()
    var stableChecks = 0
    for _ in 0..<100 {
      guard generation == token, !Task.isCancelled else { return }
      guard NSApp.isActive else {
        cancel()
        return
      }
      let ownsInput =
        window.isKeyWindow && window.firstResponder === receiver
        && receiver.inputContext != nil
        && NSTextInputContext.current === receiver.inputContext
      stableChecks = ownsInput ? stableChecks + 1 : 0
      if stableChecks >= 2 {
        report(.ready, ownershipDescription())
        guard generation == token, NSApp.isActive else { return }
        receiver.inputContext?.invalidateCharacterCoordinates()
        creatorEntry?.showCreationFirst()
        report(
          .awaitingCapture,
          "Opening native creator; selected prompt length=\(receiver.string.utf16.count)")
        guard generation == token, NSApp.isActive else { return }
        NSApp.orderFrontCharacterPalette(nil)
        presentation = Task { [weak self] in await self?.watchPresentation(token: token) }
        return
      }
      do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
    }
    fail(.inputOwnershipTimedOut, ownershipDescription())
  }

  private func watchPresentation(token: UUID) async {
    var appeared = false
    var missingChecks = 0
    var prefilled = prompt.isEmpty
    for iteration in 0... {
      do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
      guard generation == token, phase == .awaitingCapture else { return }
      let palettePIDs = Set(
        NSRunningApplication.runningApplications(
          withBundleIdentifier: "com.apple.CharacterPaletteIM"
        )
        .map(\.processIdentifier))
      let windows =
        CGWindowListCopyWindowInfo(
          [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
      let visible = windows.contains { info in
        guard let pid = info[kCGWindowOwnerPID as String] as? Int32,
          palettePIDs.contains(pid),
          let bounds = info[kCGWindowBounds as String] as? [String: CGFloat]
        else { return false }
        return (bounds["Width"] ?? 0) >= 250 && (bounds["Height"] ?? 0) >= 200
      }
      if visible {
        appeared = true
        missingChecks = 0
        if !prefilled { prefilled = NativeGenmoji.advanceCreator(prompt: prompt) }
      } else if appeared {
        missingChecks += 1
        if missingChecks >= 3 { cancel(); return }
      } else if iteration == 4, NSApp.isActive, let window, let receiver,
        window.isKeyWindow, window.firstResponder === receiver,
        receiver.inputContext != nil,
        NSTextInputContext.current === receiver.inputContext
      {
        report(.awaitingCapture, "Retrying native creator after input-service startup")
        guard generation == token, phase == .awaitingCapture,
          NSApp.isActive, window.isKeyWindow, window.firstResponder === receiver,
          receiver.inputContext != nil,
          NSTextInputContext.current === receiver.inputContext
        else { return }
        creatorEntry?.showCreationFirst()
        receiver.inputContext?.invalidateCharacterCoordinates()
        NSApp.orderFrontCharacterPalette(nil)
      } else if iteration >= 49 {
        fail(.presentationTimedOut, "The native creator did not become visible")
        return
      }
    }
  }

  private func applicationActivated(_ application: NSRunningApplication?, token: UUID) {
    guard generation == token, isRunning, let application else { return }
    guard application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
      application.bundleIdentifier != "com.apple.CharacterPaletteIM"
    else { return }
    cancel()
  }

  private func capture(_ glyph: NSAdaptiveImageGlyph, token: UUID) {
    guard generation == token, phase == .awaitingCapture else { return }
    if let foreground = NSWorkspace.shared.frontmostApplication,
      foreground.processIdentifier != ProcessInfo.processInfo.processIdentifier,
      foreground.bundleIdentifier != "com.apple.CharacterPaletteIM"
    {
      cancel()
      return
    }
    teardown()
    report(
      .captured,
      "Captured \(glyph.imageContent.count) original bytes; id=\(glyph.contentIdentifier)")
    onCapture?(glyph)
  }

  private func fail(_ failure: Failure, _ message: String) {
    teardown()
    report(.failed, message)
    onError?(failure)
  }

  private func report(_ phase: Phase, _ message: String) {
    self.phase = phase
    onDiagnostic?(Diagnostic(phase: phase, message: message))
  }

  private func ownershipDescription() -> String {
    "active=\(NSApp.isActive) key=\(window?.isKeyWindow == true) "
      + "firstResponder=\(window?.firstResponder === receiver) "
      + "context=\(receiver?.inputContext != nil) "
      + "currentContext=\(receiver?.inputContext != nil && NSTextInputContext.current === receiver?.inputContext)"
  }

  private func teardown() {
    generation = UUID()
    preparation?.cancel()
    preparation = nil
    presentation?.cancel()
    presentation = nil
    if let activationObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
    }
    activationObserver = nil
    receiver?.onGlyph = nil
    receiver?.onEscape = nil
    receiver?.delegate = nil
    if let context = receiver?.inputContext, NSTextInputContext.current === context {
      context.discardMarkedText()
      context.deactivate()
    }
    window?.orderOut(nil)
    window?.close()
    window = nil
    receiver = nil
    creatorEntry = nil
    startingApplication = nil
  }

  private func defaultAnchor() -> CGRect {
    let frame = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 800, height: 600)
    return CGRect(x: frame.midX, y: frame.midY, width: 1, height: 20)
  }

  isolated deinit {
    teardown()
  }
}

private final class ReceiverWindow: NSWindow {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

private final class ReceiverTextView: NSTextView {
  var anchorRect = CGRect.zero
  var onGlyph: ((NSAdaptiveImageGlyph) -> Void)?
  var onEscape: (() -> Void)?

  override var supportsAdaptiveImageGlyph: Bool { true }

  override func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect
  {
    actualRange?.pointee = selectedRange()
    return anchorRect
  }

  override func insert(_ adaptiveImageGlyph: NSAdaptiveImageGlyph, replacementRange: NSRange) {
    onGlyph?(adaptiveImageGlyph)
  }

  override func cancelOperation(_ sender: Any?) {
    onEscape?()
  }
}

private final class CreatorEntry {
  private let handle: UnsafeMutableRawPointer
  private let entry: @convention(c) () -> Void

  init?() {
    guard
      let handle = dlopen(
        "/System/Library/PrivateFrameworks/CharacterPicker.framework/CharacterPicker", RTLD_LAZY)
    else { return nil }
    guard let symbol = dlsym(handle, "CPKShowGenmojiCreationFirstOnNextSession") else {
      dlclose(handle)
      return nil
    }
    self.handle = handle
    entry = unsafeBitCast(symbol, to: (@convention(c) () -> Void).self)
  }

  func showCreationFirst() { entry() }

  isolated deinit { dlclose(handle) }
}
