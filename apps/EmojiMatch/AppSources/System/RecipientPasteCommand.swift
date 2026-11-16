import ApplicationServices

enum RecipientPasteCommand {
  enum Result {
    case unavailable
    case performed
    case failed
  }

  struct Dependencies {
    var application: (pid_t) -> AXUIElement = { AXUIElementCreateApplication($0) }
    var attribute: (AXUIElement, String) -> CFTypeRef? = { element, name in
      var value: CFTypeRef?
      guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
        return nil
      }
      return value
    }
    var children: (AXUIElement, Int) -> [AXUIElement]? = { element, limit in
      var count: CFIndex = 0
      guard
        AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count)
          == .success, count >= 0, count <= limit
      else { return nil }
      if count == 0 { return [] }
      var values: CFArray?
      guard
        AXUIElementCopyAttributeValues(
          element, kAXChildrenAttribute as CFString, 0, count, &values) == .success,
        let children = values as? [AXUIElement], children.count == count
      else { return nil }
      return children
    }
    var supportsPress: (AXUIElement) -> Bool = { element in
      var names: CFArray?
      guard AXUIElementCopyActionNames(element, &names) == .success,
        let actions = names as? [String], actions.count <= 32
      else { return false }
      return actions.contains(kAXPressAction)
    }
    var press: (AXUIElement) -> Bool = {
      AXUIElementPerformAction($0, kAXPressAction as CFString) == .success
    }
  }

  static func perform(
    for processIdentifier: pid_t, validate: () -> Bool, dependencies: Dependencies = .init()
  ) -> Result {
    let application = dependencies.application(processIdentifier)
    guard let value = dependencies.attribute(application, kAXMenuBarAttribute),
      CFGetTypeID(value) == AXUIElementGetTypeID()
    else { return .unavailable }
    let menuBar = unsafeBitCast(value, to: AXUIElement.self)
    guard let barItems = dependencies.children(menuBar, 32) else { return .unavailable }
    var candidate: AXUIElement?
    var remainingItems = 1024
    for barItem in barItems {
      guard let menus = dependencies.children(barItem, 8) else { return .unavailable }
      for menu in menus
      where dependencies.attribute(menu, kAXRoleAttribute) as? String == kAXMenuRole {
        guard let items = dependencies.children(menu, min(256, remainingItems)) else {
          return .unavailable
        }
        remainingItems -= items.count
        for item in items {
          guard dependencies.attribute(item, kAXRoleAttribute) as? String == kAXMenuItemRole,
            dependencies.attribute(item, kAXMenuItemCmdCharAttribute) as? String == "v",
            dependencies.attribute(item, kAXMenuItemCmdModifiersAttribute) as? Int == 0,
            dependencies.attribute(item, kAXEnabledAttribute) as? Bool == true,
            dependencies.supportsPress(item)
          else { continue }
          guard candidate == nil else { return .unavailable }
          candidate = item
        }
      }
    }
    guard let candidate else { return .unavailable }
    guard validate() else { return .failed }
    return dependencies.press(candidate) ? .performed : .failed
  }
}
