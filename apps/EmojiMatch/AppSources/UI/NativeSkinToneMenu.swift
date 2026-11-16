import AppKit
import ObjectiveC

@MainActor
final class NativeSkinToneMenu {
  private typealias Factory =
    @convention(c) (
      AnyObject, Selector, NSString, CGFloat, NSSize
    ) -> Unmanaged<AnyObject>?
  private typealias Present =
    @convention(c) (
      AnyObject, Selector, NSRect, NSView, Bool, NSRect
    ) -> Bool
  private typealias GetObject = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
  private typealias Close = @convention(c) (AnyObject, Selector) -> Void

  private struct Runtime {
    let menuClass: NSWindow.Type
    let factory: Factory
    let present: Present
    let selectedCharacter: GetObject
    let menuView: GetObject
    let buttons: GetObject
    let close: Close
  }

  private static let factorySelector = NSSelectorFromString("menuForCharacter:fontSize:cellSize:")
  private static let presentSelector = NSSelectorFromString(
    "popUpMenuPositioningAtRect:inView:byMouse:pinRectInWindow:")
  private static let selectedSelector = NSSelectorFromString("selectedCharacter")
  private static let viewSelector = NSSelectorFromString("_menuView")
  private static let buttonsSelector = NSSelectorFromString("buttons")
  private static let closeSelector = NSSelectorFromString("closeMenu")
  private static let framework = dlopen(
    "/System/Library/PrivateFrameworks/CharacterPicker.framework/CharacterPicker", RTLD_LAZY)
  private static let runtime: Runtime? = loadRuntime()

  private var activeMenu: NSWindow?
  var isPresenting: Bool { activeMenu != nil }

  func owns(_ window: NSWindow?) -> Bool {
    guard let window else { return false }
    return activeMenu === window
  }

  @discardableResult
  func present(
    variants: [EmojiSelection], source: NSView, byMouse: Bool = false,
    sourceRect: NSRect? = nil,
    boundingRectInWindow: NSRect? = nil,
    onSelect: (EmojiSelection) -> Void
  ) -> Bool {
    guard let runtime = Self.runtime, variants.count == 6,
      variants.allSatisfy({ $0.asset == nil }), Set(variants.map(\.value)).count == variants.count,
      let base = variants.first, let window = source.window, window.isVisible,
      !source.isHiddenOrHasHiddenAncestor, let contentView = window.contentView
    else { return false }
    let visibleRect = source.visibleRect.intersection(source.bounds)
    let positioningRect = sourceRect ?? visibleRect
    guard !visibleRect.isEmpty, !positioningRect.isEmpty, !positioningRect.isInfinite,
      !positioningRect.isNull
    else { return false }
    cancel()
    guard
      let menu = runtime.factory(
        runtime.menuClass, Self.factorySelector, base.value as NSString, 32,
        NSSize(width: 52, height: 42))?
        .takeUnretainedValue() as? NSWindow,
      let view = runtime.menuView(menu, Self.viewSelector)?.takeUnretainedValue() as? NSView,
      NSStringFromClass(type(of: view)) == "CPKHorizontalPopupMenuView",
      let buttons = runtime.buttons(view, Self.buttonsSelector)?.takeUnretainedValue()
        as? [NSButton],
      buttons.map(\.title) == variants.map(\.value)
    else { return false }
    activeMenu = menu
    let pinRect = boundingRectInWindow ?? contentView.convert(contentView.bounds, to: nil)
    let selected = runtime.present(
      menu, Self.presentSelector, positioningRect, source, byMouse, pinRect)
    guard activeMenu === menu else { return true }
    activeMenu = nil
    if selected,
      let value = runtime.selectedCharacter(menu, Self.selectedSelector)?.takeUnretainedValue()
        as? String,
      let selection = variants.first(where: { $0.value == value })
    {
      onSelect(selection)
    }
    return true
  }

  func cancel() {
    guard let menu = activeMenu, let runtime = Self.runtime else { return }
    activeMenu = nil
    runtime.close(menu, Self.closeSelector)
  }

  private static func loadRuntime() -> Runtime? {
    guard framework != nil,
      let menuClass = NSClassFromString("CPKHorizontalPopupMenu") as? NSWindow.Type,
      let viewClass = NSClassFromString("CPKHorizontalPopupMenuView"),
      let factory = class_getClassMethod(menuClass, factorySelector),
      hasSignature(factory, result: "@", arguments: ["@", ":", "@", "d", "{CGSize=dd}"]),
      let present = class_getInstanceMethod(menuClass, presentSelector),
      hasSignature(
        present, result: "B",
        arguments: [
          "@", ":", "{CGRect={CGPoint=dd}{CGSize=dd}}", "@", "B",
          "{CGRect={CGPoint=dd}{CGSize=dd}}"
        ]),
      let selected = class_getInstanceMethod(menuClass, selectedSelector),
      hasSignature(selected, result: "@", arguments: ["@", ":"]),
      let view = class_getInstanceMethod(menuClass, viewSelector),
      hasSignature(view, result: "@", arguments: ["@", ":"]),
      let buttons = class_getInstanceMethod(viewClass, buttonsSelector),
      hasSignature(buttons, result: "@", arguments: ["@", ":"]),
      let close = class_getInstanceMethod(menuClass, closeSelector),
      hasSignature(close, result: "v", arguments: ["@", ":"])
    else { return nil }
    return Runtime(
      menuClass: menuClass,
      factory: unsafeBitCast(method_getImplementation(factory), to: Factory.self),
      present: unsafeBitCast(method_getImplementation(present), to: Present.self),
      selectedCharacter: unsafeBitCast(method_getImplementation(selected), to: GetObject.self),
      menuView: unsafeBitCast(method_getImplementation(view), to: GetObject.self),
      buttons: unsafeBitCast(method_getImplementation(buttons), to: GetObject.self),
      close: unsafeBitCast(method_getImplementation(close), to: Close.self))
  }

  private static func hasSignature(_ method: Method, result: String, arguments: [String]) -> Bool {
    let returnType = method_copyReturnType(method)
    defer { free(returnType) }
    guard String(cString: returnType) == result,
      method_getNumberOfArguments(method) == arguments.count
    else { return false }
    for (index, expected) in arguments.enumerated() {
      guard let argument = method_copyArgumentType(method, UInt32(index)) else { return false }
      defer { free(argument) }
      guard String(cString: argument) == expected else { return false }
    }
    return true
  }
}
