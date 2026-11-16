import AccessibilitySupport
import AppKit
import Carbon.HIToolbox
import DesignSystem
import SwiftUI

struct EmojiMatchSettingsView: View {
  @Bindable var settings: AppSettings
  let clearHistory: () -> Void
  let setShortcutRecording: (Bool) -> Void
  @State private var recording = false
  @State private var keyboardMonitor: Any?
  @State private var shortcutError: String?
  @State private var recordingWindowNumber: Int?
  @State private var hasAccessibility = AccessibilityPermission.isGranted

  private enum Page: String, CaseIterable, Identifiable {
    case general = "General"
    case stickers = "Stickers"
    case genmoji = "Genmoji"
    case accessibility = "Accessibility"

    var id: Self { self }
    var symbol: String {
      switch self {
      case .general: "gearshape"
      case .stickers: "square.grid.2x2"
      case .genmoji: "face.smiling"
      case .accessibility: "accessibility"
      }
    }
  }

  @State private var page: Page? = .general
  @State private var confirmsClearHistory = false
  let library: StickerLibraryModel
  let genmojiLibrary: StickerLibraryModel
  let onCreateGenmoji: ((CGRect) -> Void)?

  var body: some View {
    NavigationSplitView(columnVisibility: .constant(.all)) {
      List(Page.allCases, selection: $page) { page in
        NavigationLink(value: page) {
          Label(page.rawValue, systemImage: page.symbol)
        }
      }
      .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
      .toolbar(removing: .sidebarToggle)
      .safeAreaInset(edge: .bottom, alignment: .leading) {
        Text("Emoji Match").font(.caption).foregroundStyle(Color.ds.textSecondary)
          .padding(.horizontal, CGFloat.ds.spacing.md).padding(.vertical, CGFloat.ds.spacing.sm)
      }
    } detail: {
      Group {
        switch page ?? .general {
        case .general: generalSettings
        case .stickers: StickerLibrarySettingsView(model: library)
        case .genmoji:
          StickerLibrarySettingsView(model: genmojiLibrary, onCreateGenmoji: onCreateGenmoji)
        case .accessibility: accessibilitySettings
        }
      }
      .id(page)
      .navigationTitle((page ?? .general).rawValue)
    }
    .frame(minWidth: 740, minHeight: 520)
    .onChange(of: page) { _, _ in stopRecording() }
    .onDisappear { stopRecording() }
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) {
      notification in
      if (notification.object as? NSWindow)?.windowNumber == recordingWindowNumber {
        stopRecording()
      }
    }
    .onReceive(
      NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)
    ) { _ in stopRecording() }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in
      hasAccessibility = AccessibilityPermission.isGranted
    }
  }

  private var generalSettings: some View {
    Form {
      Section("Opening the Picker") {
        LabeledContent("Keyboard shortcut") {
          Button(recording ? "Press a shortcut…" : settings.openShortcut.label) { startRecording() }
            .accessibilityLabel("Record opening shortcut")
          Button("Reset") { settings.openShortcut = .defaultOpen }
            .disabled(recording)
        }
        if let error = shortcutError ?? settings.registrationError {
          Text(error).foregroundStyle(.red).font(.caption)
        }
        Toggle("Use selected text as the initial search", isOn: $settings.prefillSelectedText)
      }
      Section("Emoji") {
        Picker("Default skin tone", selection: $settings.defaultSkinTone) {
          ForEach(DefaultSkinTone.allCases) { tone in
            Text(tone.hand).tag(tone).accessibilityLabel(tone.label)
          }
        }
        .pickerStyle(.segmented)
      }
      Section("History") {
        LabeledContent("Clear Recent") {
          Button("Clear…") { confirmsClearHistory = true }
        }
      }
    }
    .formStyle(.grouped)
    .confirmationDialog("Clear recent history?", isPresented: $confirmsClearHistory) {
      Button("Clear History", role: .destructive, action: clearHistory)
    } message: {
      Text("Your saved items and favorites will remain in the library.")
    }
  }

  private var accessibilitySettings: some View {
    Form {
      Section("Accessibility Access") {
        LabeledContent("Status", value: hasAccessibility ? "Granted" : "Not granted")
        Button("Open Accessibility Settings…") {
          if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
          {
            NSWorkspace.shared.open(url)
          }
        }
        Text("Allows Emoji Match to position the picker and insert items into your current app.")
          .font(.caption).foregroundStyle(Color.ds.textSecondary)
      }
    }
    .formStyle(.grouped)
  }

  private func startRecording() {
    stopRecording()
    recording = true
    recordingWindowNumber = NSApp.keyWindow?.windowNumber
    setShortcutRecording(true)
    shortcutError = nil
    keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      if event.keyCode == UInt16(kVK_Escape) { stopRecording(); return nil }
      let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      guard !flags.intersection([.command, .control, .option]).isEmpty else {
        shortcutError = "Include Command, Control or Option."
        return nil
      }
      var modifiers: UInt32 = 0
      for (flag, carbon) in [
        (NSEvent.ModifierFlags.command, cmdKey), (.control, controlKey), (.option, optionKey),
        (.shift, shiftKey)
      ] where flags.contains(flag) {
        modifiers |= UInt32(carbon)
      }
      let key =
        event.keyCode == UInt16(kVK_Space)
        ? "Space" : (event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)")
      settings.openShortcut = .init(
        keyCode: UInt32(event.keyCode), carbonModifiers: modifiers, displayKey: key)
      stopRecording()
      return nil
    }
  }

  private func stopRecording() {
    if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
    keyboardMonitor = nil
    recording = false
    recordingWindowNumber = nil
    setShortcutRecording(false)
  }
}
