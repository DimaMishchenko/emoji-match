import AccessibilitySupport
import AppKit
import SwiftUI

@main
struct App: SwiftUI.App {
  @State private var settings: AppSettings
  @State private var panel: NSPanel?
  @State private var settingsWindow: NSWindow?
  @State private var sessionID = UUID()
  @State private var lastSelection: EmojiSelection?
  @State private var message: String?
  @State private var genmojiCapture: GenmojiCaptureSession?
  private let searchStore = EmojiSearchStore()
  private let usageStore: EmojiUsageStore
  private let systemShortcutMonitor = SystemShortcutMonitor()

  init() {
    #if DEBUG
      let arguments = ProcessInfo.processInfo.arguments
      if let index = arguments.firstIndex(of: "--verification-directory"),
        index + 1 < arguments.count
      {
        let directory = URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL
          .resolvingSymlinksInPath()
        if directory.path.hasPrefix("/private/tmp/emoji-match-")
          || directory.path.hasPrefix("/tmp/emoji-match-")
        {
          let defaults =
            UserDefaults(
              suiteName: "com.dimasike.EmojiMatch.verification." + directory.lastPathComponent)
            ?? .standard
          _settings = State(
            initialValue: AppSettings(defaults: defaults, prefix: "verification.settings"))
          usageStore = EmojiUsageStore(
            defaults: defaults, storageKey: "verification.history",
            libraryDirectory: directory.appendingPathComponent("library"))
          return
        }
      }
    #endif
    _settings = State(initialValue: AppSettings())
    usageStore = EmojiUsageStore()
  }

  var body: some Scene {
    MenuBarExtra {
      Button(String(localized: .menuOpen)) { openEmojiMatch() }
      Button("System Emoji & Symbols…") {
        openSystemPicker(destination: InsertionDestination.capture())
      }
      Button("Import from Clipboard…") {
        importClipboard(destination: InsertionDestination.capture())
      }
      if let lastSelection {
        Button("Copy Last Selection") { copy(lastSelection) }
      }
      if let message { Text(message).font(.caption) }
      Divider()
      Button("Settings…") { openSettings() }.keyboardShortcut(",")
      Button(String(localized: .menuQuit)) { NSApp.terminate(nil) }.keyboardShortcut("q")
    } label: {
      Label(String(localized: .appName), systemImage: "face.smiling")
        .task {
          systemShortcutMonitor.onRegistrationChanged = { settings.registrationError = $0 }
          systemShortcutMonitor.start { openEmojiMatch() }
        }
        .onChange(of: settings.openShortcut, initial: true) { _, shortcut in
          systemShortcutMonitor.shortcut = shortcut
        }
    }
    .menuBarExtraStyle(.menu)
  }

  private func openEmojiMatch(destination override: InsertionDestination? = nil) {
    usageStore.refreshLibrary()
    let anchor = TextAnchorResolver.anchorRect()
    let captured =
      override ?? InsertionDestination.capture(includeSelectedText: settings.prefillSelectedText)
    sessionID = UUID()
    genmojiCapture?.cancel()
    genmojiCapture = nil
    panel?.close()
    let size = CGSize(
      width: EmojiPickerMetrics.contentWidth, height: EmojiPickerMetrics.expandedHeight)
    let panel = EmojiMatchPanel(contentSize: size, onClose: { self.panel = nil }) { close in
      EmojiMatchView(
        contentWidth: size.width,
        searchStore: searchStore,
        usageStore: usageStore,
        onSubmit: { selection in
          close(); deliver(selection, to: captured)
        },
        onSelectEmoji: { selection in
          close(); deliver(selection, to: captured)
        },
        onCreateGenmoji: NativeGenmoji.isAvailable && captured?.allowsRichContent != false
          ? { prompt in
            close()
            createGenmoji(prompt: prompt, destination: captured, anchor: anchor)
          } : nil,
        onClose: close,
        initialQuery: captured?.selectedText ?? "",
        allowsRichContent: captured?.allowsRichContent ?? true,
        onCopySelection: copy
      )
    }
    self.panel = panel
    panel.show(anchorRect: anchor)
  }

  private func createGenmoji(
    prompt: String, destination: InsertionDestination?, anchor: CGRect?
  ) {
    let request = sessionID
    let capture = GenmojiCaptureSession()
    genmojiCapture = capture
    capture.onCapture = { glyph in
      guard sessionID == request else { return }
      genmojiCapture = nil
      do {
        let selection = try usageStore.importAdaptiveGlyph(glyph)
        deliver(selection, to: destination)
      } catch {
        showError("Couldn’t Save Genmoji", detail: error.localizedDescription)
      }
    }
    capture.onCancel = {
      guard sessionID == request else { return }
      genmojiCapture = nil
      _ = destination?.restoreFocus()
    }
    capture.onError = { _ in
      guard sessionID == request else { return }
      genmojiCapture = nil
      message = "Genmoji creation could not open. You can import a copied Genmoji instead."
      _ = destination?.restoreFocus()
    }
    #if DEBUG
      capture.onDiagnostic = { diagnostic in
        FileHandle.standardError.write(
          Data("Genmoji capture: \(diagnostic.phase.rawValue) \(diagnostic.message)\n".utf8))
      }
    #endif
    let appKitAnchor = anchor.map {
      CGRect(
        x: $0.minX, y: (NSScreen.screens.first?.frame.maxY ?? 0) - $0.maxY,
        width: $0.width, height: $0.height)
    }
    capture.start(prompt: prompt, anchorRect: appKitAnchor)
  }

  private func deliver(_ selection: EmojiSelection, to destination: InsertionDestination?) {
    lastSelection = selection
    let request = sessionID
    Task {
      try? await Task.sleep(for: .milliseconds(75))
      guard sessionID == request else { return }
      guard let destination else {
        message = "Insertion unavailable. Use Copy Last Selection or the system picker."
        return
      }
      guard selection.asset == nil || destination.allowsRichContent else {
        message = "This input accepts text only. Your item remains available to copy."
        return
      }
      for _ in 0..<25 {
        guard sessionID == request else { return }
        guard destination.restoreFocus() else {
          message = "The original input changed. Your selection is available to copy."
          return
        }
        try? await Task.sleep(for: .milliseconds(20))
        guard sessionID == request else { return }
        if destination.isValidForDelivery() {
          if TextPasteController.paste(
            selection, data: usageStore.data(for: selection), to: destination)
          {
            usageStore.record(selection)
            message = nil
          } else {
            message = "Could not insert. Use Copy Last Selection to paste manually."
          }
          return
        }
        try? await Task.sleep(for: .milliseconds(20))
      }
      guard sessionID == request else { return }
      message = "Could not restore the original input. Your selection is available to copy."
    }
  }

  private func copy(_ selection: EmojiSelection) {
    lastSelection = selection
    message =
      TextPasteController.copy(selection, data: usageStore.data(for: selection))
      ? "Copied." : "This item could not be copied."
  }

  private func importClipboard(destination: InsertionDestination?) {
    do {
      let selections = try retain(RichContentImport.read())
      message = "Imported \(selections.count) item(s)."
      openEmojiMatch(destination: destination)
    } catch {
      showError(
        "Couldn’t Import",
        detail:
          "Copy a Genmoji or supported image, then choose Import again. \(error.localizedDescription)"
      )
    }
  }

  private func retain(_ contents: [ImportedContent]) throws -> [EmojiSelection] {
    try contents.map { content in
      switch content {
      case .adaptiveGlyph(let glyph): try usageStore.importAdaptiveGlyph(glyph)
      case .image(let data, let type, let description):
        try usageStore.importImage(data: data, typeIdentifier: type, description: description)
      }
    }
  }

  private func openSystemPicker(
    destination: InsertionDestination?,
    nativeDestination: NativeGenmoji.Destination? = NativeGenmoji.Destination.capture()
  ) {
    sessionID = UUID()
    genmojiCapture?.cancel()
    genmojiCapture = nil
    let request = sessionID
    panel?.close()
    Task {
      try? await Task.sleep(for: .milliseconds(100))
      guard sessionID == request else { return }
      if let destination {
        guard destination.restoreFocus() else { return }
        try? await Task.sleep(for: .milliseconds(100))
        guard sessionID == request, destination.isValidForDelivery() else { return }
        systemShortcutMonitor.openNativeEmojiPicker()
      } else if let nativeDestination,
        nativeDestination.application.processIdentifier
          != ProcessInfo.processInfo.processIdentifier,
        nativeDestination.application.isActive
      {
        systemShortcutMonitor.openNativeEmojiPicker()
      } else {
        NSApp.orderFrontCharacterPalette(nil)
      }
    }
  }

  private func openSettings() {
    sessionID = UUID()
    genmojiCapture?.cancel()
    genmojiCapture = nil
    panel?.close()
    if settingsWindow == nil {
      let window = NSWindow(
        contentRect: .init(x: 0, y: 0, width: 460, height: 390), styleMask: [.titled, .closable],
        backing: .buffered, defer: false)
      window.title = "Emoji Match Settings"
      window.isReleasedWhenClosed = false
      window.contentViewController = NSHostingController(
        rootView: EmojiMatchSettingsView(
          settings: settings, clearHistory: { usageStore.clearHistory() },
          openSystemPicker: { openSystemPicker(destination: nil) },
          setShortcutRecording: { recording in
            if !recording { systemShortcutMonitor.shortcut = settings.openShortcut }
            systemShortcutMonitor.isSuspended = recording
          }))
      window.center()
      settingsWindow = window
    }
    NSApp.activate()
    settingsWindow?.makeKeyAndOrderFront(nil)
  }

  private func showError(_ title: String, detail: String) {
    message = detail
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = detail
    alert.addButton(withTitle: "OK")
    NSApp.activate()
    alert.runModal()
  }
}
