import AccessibilitySupport
import AppKit
import SwiftUI

@main
struct App: SwiftUI.App {
  private enum Constants {
    static let emContentSize = CGSize(
      width: EmojiPickerMetrics.contentWidth,
      height: EmojiPickerMetrics.expandedHeight
    )

  }

  @State private var settings = AppSettings()
  @State private var panel: NSPanel?
  private let searchStore = EmojiSearchStore()
  private let usageStore = EmojiUsageStore()
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
      contentSize: Constants.emContentSize,
      onClose: {
        self.panel = nil
      }
    ) { close in
      EmojiMatchView(
        contentWidth: Constants.emContentSize.width,
        searchStore: searchStore,
        usageStore: usageStore,
        onSubmit: { selection in
          closeAndPaste(selection, close: close)
        },
        onSelectEmoji: { selection in
          closeAndPaste(selection, close: close)
        },
        onClose: {
          close()
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

    panel.close()
  }

  private func closeAndPaste(_ selection: EmojiSelection, close: () -> Void) {
    close()
    DispatchQueue.main.async {
      if TextPasteController.paste(selection.value) {
        usageStore.record(selection)
      }
    }
  }
}
