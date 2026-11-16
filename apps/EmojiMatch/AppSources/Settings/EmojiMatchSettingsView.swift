import AccessibilitySupport
import AppKit
import Carbon.HIToolbox
import DesignSystem
import SwiftUI

struct EmojiMatchSettingsView: View {
  @Bindable var settings: AppSettings
  let clearHistory: () -> Void
  let openSystemPicker: () -> Void
  let setShortcutRecording: (Bool) -> Void
  @State private var recording = false
  @State private var keyboardMonitor: Any?
  @State private var shortcutError: String?
  @State private var recordingWindowNumber: Int?
  @State private var hasAccessibility = AccessibilityPermission.isGranted

  var body: some View {
    Form {
      Section {
        LabeledContent("Open Emoji Match") {
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
      Section("Accessibility") {
        LabeledContent("Access", value: hasAccessibility ? "Granted" : "Not granted")
        Button("Open Accessibility Settings…") {
          if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
          {
            NSWorkspace.shared.open(url)
          }
        }
        Text("Accessibility access enables caret placement and insertion into other apps.")
          .font(.caption).foregroundStyle(Color.ds.textSecondary)
      }
      Section {
        Button("Clear Recent History", action: clearHistory)
        Text("Saved items and favorites are kept.")
          .font(.caption).foregroundStyle(Color.ds.textSecondary)
        Button("Open System Emoji & Symbols…", action: openSystemPicker)
        if !NativeGenmoji.isAvailable {
          Text("Genmoji creation requires Apple Intelligence and supported system settings.")
            .font(.caption).foregroundStyle(Color.ds.textSecondary)
        }
      }
    }
    .formStyle(.grouped)
    .frame(width: 460, height: 390)
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
