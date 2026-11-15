import AccessibilitySupport
import AppKit
import SwiftUI

@main
struct App: SwiftUI.App {
  private enum Constants {
    static let emInitialContentSize = CGSize(width: 324, height: 44)
    static let emMaximumContentSize = EmojiMatchView.maximumContentSize(
      width: emInitialContentSize.width
    )
  }

  @State private var settings = AppSettings()
  @State private var panel: NSPanel?
  private let systemShortcutMonitor = SystemShortcutMonitor()

  var body: some Scene {
    MenuBarExtra {
      Button(String(localized: .menuOpen)) {
        openEmojiMatch()
      }

      Divider()

      Button(String(localized: .menuQuit)) {
        NSApp.terminate(nil)
      }
      .keyboardShortcut("q")
    } label: {
      Label(String(localized: .appName), systemImage: "face.smiling")
        .task {
          systemShortcutMonitor.start {
            openEmojiMatch()
          }
        }
        .onChange(of: settings.openShortcut, initial: true) { _, shortcut in
          systemShortcutMonitor.shortcut = shortcut
        }
    }
    .menuBarExtraStyle(.menu)
  }

  private func openEmojiMatch() {
    AccessibilityPermission.requestIfNeeded()
    closeExistingInstance()

    let panel = EmojiMatchPanel(
      initialContentSize: Constants.emInitialContentSize,
      maximumContentSize: Constants.emMaximumContentSize,
      onClose: {
        self.panel = nil
      }
    ) { close, setExpanded in
      EmojiMatchView(
        contentWidth: Constants.emInitialContentSize.width,
        onSubmit: {
          guard let emoji = MockRandomEmojiSource.randomEmoji() else {
            return
          }

          closeAndPaste(emoji, close: close)
        },
        onSelectEmoji: { emoji in
          closeAndPaste(emoji, close: close)
        },
        onOpenBrowser: {
          setExpanded(true)
        }
      )
    }
    self.panel = panel
    panel.show(anchorRect: TextAnchorResolver.anchorRect())
  }

  private func closeExistingInstance() {
    guard let panel else {
      return
    }

    // `onClose` clears the stored panel after it closes. This handles the separate case where the
    // open shortcut is triggered again while the previous panel is still open.
    panel.close()
  }

  private func closeAndPaste(_ emoji: String, close: () -> Void) {
    close()
    DispatchQueue.main.async {
      TextPasteController.paste(emoji)
    }
  }
}
