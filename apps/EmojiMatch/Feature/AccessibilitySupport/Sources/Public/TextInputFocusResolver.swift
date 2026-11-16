import ApplicationServices

/// Resolves the semantic text input, including inputs that own an active result list.
public enum TextInputFocusResolver {
  /// Use the returned element for insertion capture as well as input classification.
  /// Returns nil for ambiguous ownership or focus without an identifiable text input.
  public static func focusedElement(inApplication processIdentifier: pid_t) -> AXUIElement? {
    let application = AXUIElementCreateApplication(processIdentifier)
    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        application, kAXFocusedUIElementAttribute as CFString, &value) == .success,
      let value, CFGetTypeID(value) == AXUIElementGetTypeID()
    else { return nil }
    let focused = unsafeBitCast(value, to: AXUIElement.self)
    return TextInputFocusLocator(elements: AccessibilityElementReader()).resolve(focused)
  }
}
