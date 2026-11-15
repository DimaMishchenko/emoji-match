import Carbon.HIToolbox
import Observation

@MainActor
@Observable
final class AppSettings {
  struct Shortcut: Equatable {
    let keyCode: UInt32
    let carbonModifiers: UInt32

    static let defaultOpen = Shortcut(
      keyCode: UInt32(kVK_Space),
      carbonModifiers: UInt32(cmdKey | controlKey)
    )
  }

  var openShortcut = Shortcut.defaultOpen
}
