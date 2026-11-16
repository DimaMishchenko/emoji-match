import AppKit
import ApplicationServices
import ImagePlayground

enum NativeGenmoji {
  static var isAvailable: Bool {
    ImagePlaygroundViewController.isAvailable
  }

  static func advanceCreator(prompt: String) -> Bool {
    guard
      let application =
        NSRunningApplication.runningApplications(
          withBundleIdentifier: "com.apple.CharacterPaletteIM"
        )
        .first
    else { return false }
    let app = AXUIElementCreateApplication(application.processIdentifier)
    AXUIElementSetMessagingTimeout(app, 0.1)
    func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
      var value: CFTypeRef?
      guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
        return nil
      }
      return value
    }
    func field(in element: AXUIElement, depth: Int) -> AXUIElement? {
      guard depth < 10 else { return nil }
      if attribute(element, kAXRoleAttribute) as? String == kAXTextFieldRole { return element }
      for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
        if let field = field(in: child, depth: depth + 1) { return field }
      }
      return nil
    }
    func frame(of element: AXUIElement) -> CGRect? {
      guard let position = attribute(element, kAXPositionAttribute),
        let size = attribute(element, kAXSizeAttribute),
        CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
      else { return nil }
      var origin = CGPoint.zero
      var dimensions = CGSize.zero
      guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &origin),
        AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions)
      else { return nil }
      return CGRect(origin: origin, size: dimensions)
    }
    guard let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] else { return false }
    for window in windows {
      let popovers = attribute(window, kAXChildrenAttribute) as? [AXUIElement] ?? []
      for popover in popovers
      where attribute(popover, kAXRoleAttribute) as? String == kAXPopoverRole {
        let contents = attribute(popover, kAXChildrenAttribute) as? [AXUIElement] ?? []
        for content in contents {
          let children = attribute(content, kAXChildrenAttribute) as? [AXUIElement] ?? []
          if let search = children.first(where: {
            attribute($0, kAXRoleAttribute) as? String == kAXTextFieldRole
          }), let searchFrame = frame(of: search) {
            guard
              let button = children.first(where: {
                guard attribute($0, kAXRoleAttribute) as? String == kAXButtonRole,
                  let buttonFrame = frame(of: $0)
                else { return false }
                return buttonFrame.minX >= searchFrame.maxX
                  && abs(buttonFrame.midY - searchFrame.midY) < 2
              })
            else { continue }
            AXUIElementPerformAction(button, kAXPressAction as CFString)
            return false
          }
          guard let contentFrame = frame(of: content), contentFrame.height >= 480 else { continue }
          if prompt.isEmpty { return true }
          guard let field = field(in: content, depth: 0) else { continue }
          guard let value = attribute(field, kAXValueAttribute) as? String else { return false }
          guard value.isEmpty else { return true }
          AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
          return AXUIElementSetAttributeValue(
            field, kAXValueAttribute as CFString, prompt as CFString)
            == .success
        }
      }
    }
    return false
  }
}
