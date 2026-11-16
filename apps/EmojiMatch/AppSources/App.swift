import AccessibilitySupport
import AppKit
import SwiftUI

@main
struct App: SwiftUI.App {
  @State private var settings: AppSettings
  @State private var panel: NSPanel?
  @State private var settingsWindow: NSWindow?
  @State private var sessionID = UUID()
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

  private func openEmojiMatch() {
    usageStore.refreshLibrary()
    let anchor = TextAnchorResolver.anchorRect()
    let captured =
      InsertionDestination.capture(includeSelectedText: settings.prefillSelectedText)
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
            settingsWindow?.orderOut(nil)
            close()
            createGenmoji(
              prompt: prompt, destination: captured,
              appKitAnchor: anchor.map {
                EmojiMatchPanelGeometry.appKitRect(
                  fromTopLeftRect: $0,
                  primaryScreenHeight: NSScreen.screens.first?.frame.maxY ?? 0)
              })
          } : nil,
        onClose: close,
        initialQuery: captured?.selectedText ?? "",
        allowsRichContent: captured?.allowsRichContent ?? true,
        defaultSkinTone: settings.defaultSkinTone,
        onCopySelection: copy
      )
    }
    self.panel = panel
    panel.show(anchorRect: anchor)
  }

  private func createGenmoji(
    prompt: String, destination: InsertionDestination?, appKitAnchor: CGRect?,
    onFinish: (() -> Void)? = nil
  ) {
    genmojiCapture?.cancel()
    let request = sessionID
    let capture = GenmojiCaptureSession()
    genmojiCapture = capture
    capture.onCapture = { glyph in
      guard sessionID == request else { return }
      genmojiCapture = nil
      do {
        let selection = try usageStore.importAdaptiveGlyph(glyph, asGenmoji: true)
        if let onFinish { onFinish() } else { deliver(selection, to: destination) }
      } catch {
        showError("Couldn’t Save Genmoji", detail: error.localizedDescription)
        onFinish?()
      }
    }
    capture.onCancel = {
      guard sessionID == request else { return }
      genmojiCapture = nil
      _ = destination?.restoreFocus()
      onFinish?()
    }
    capture.onError = { _ in
      guard sessionID == request else { return }
      genmojiCapture = nil
      showError(
        "Couldn’t Open Genmoji",
        detail: "You can import a copied Genmoji in Settings → Genmoji.")
      _ = destination?.restoreFocus()
      onFinish?()
    }
    #if DEBUG
      capture.onDiagnostic = { diagnostic in
        FileHandle.standardError.write(
          Data("Genmoji capture: \(diagnostic.phase.rawValue) \(diagnostic.message)\n".utf8))
      }
    #endif
    capture.start(prompt: prompt, anchorRect: appKitAnchor)
  }

  private func deliver(_ selection: EmojiSelection, to destination: InsertionDestination?) {
    let request = sessionID
    Task {
      try? await Task.sleep(for: .milliseconds(75))
      guard sessionID == request else { return }
      guard let destination else {
        NSSound.beep()
        return
      }
      guard selection.asset == nil || destination.allowsRichContent else {
        NSSound.beep()
        return
      }
      for _ in 0..<25 {
        guard sessionID == request else { return }
        guard destination.restoreFocus() else {
          NSSound.beep()
          return
        }
        try? await Task.sleep(for: .milliseconds(20))
        guard sessionID == request else { return }
        if destination.isValidForDelivery() {
          if TextPasteController.paste(
            selection, data: usageStore.data(for: selection), to: destination)
          {
            usageStore.record(selection)
          } else {
            showError(
              "Couldn’t Insert Item",
              detail: "Choose Copy from the item’s context menu, then paste it manually.")
          }
          return
        }
        try? await Task.sleep(for: .milliseconds(20))
      }
      guard sessionID == request else { return }
      NSSound.beep()
    }
  }

  private func copy(_ selection: EmojiSelection) {
    if !TextPasteController.copy(selection, data: usageStore.data(for: selection)) {
      showError("Couldn’t Copy Item", detail: "Try importing the original image again in Settings.")
    }
  }

  private func openSettings() {
    sessionID = UUID()
    genmojiCapture?.cancel()
    genmojiCapture = nil
    panel?.close()
    usageStore.refreshLibrary()
    if settingsWindow == nil {
      let window = NSWindow(
        contentRect: .init(x: 0, y: 0, width: 800, height: 580),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered, defer: false)
      window.title = "Emoji Match Settings"
      window.minSize = NSSize(width: 740, height: 560)
      window.isReleasedWhenClosed = false
      window.contentViewController = NSHostingController(
        rootView: EmojiMatchSettingsView(
          settings: settings, clearHistory: { usageStore.clearHistory() },
          setShortcutRecording: { recording in
            if !recording { systemShortcutMonitor.shortcut = settings.openShortcut }
            systemShortcutMonitor.isSuspended = recording
          },
          library: StickerLibraryModel(
            store: usageStore,
            copy: { selection in
              TextPasteController.copy(selection, data: usageStore.data(for: selection))
            }),
          genmojiLibrary: StickerLibraryModel(
            store: usageStore, collection: .genmoji,
            copy: { selection in
              TextPasteController.copy(selection, data: usageStore.data(for: selection))
            }),
          onCreateGenmoji: NativeGenmoji.isAvailable
            ? { anchor in
              sessionID = UUID()
              createGenmoji(
                prompt: "", destination: nil,
                appKitAnchor: CGRect(
                  x: anchor.midX, y: anchor.minY, width: 1, height: anchor.height),
                onFinish: restoreSettingsAfterGenmoji)
            } : nil))
      window.center()
      settingsWindow = window
    }
    NSApp.activate()
    settingsWindow?.makeKeyAndOrderFront(nil)
  }

  private func restoreSettingsAfterGenmoji() {
    guard settingsWindow?.isVisible == true else { return }
    let foreground = NSWorkspace.shared.frontmostApplication
    if foreground?.processIdentifier == ProcessInfo.processInfo.processIdentifier
      || foreground?.bundleIdentifier == "com.apple.CharacterPaletteIM"
    {
      openSettings()
    } else {
      settingsWindow?.orderBack(nil)
    }
  }

  private func showError(_ title: String, detail: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = detail
    alert.addButton(withTitle: "OK")
    NSApp.activate()
    alert.runModal()
  }
}
