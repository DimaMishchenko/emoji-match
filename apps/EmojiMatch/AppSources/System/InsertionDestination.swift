import AccessibilitySupport
import AppKit
import ApplicationServices

struct InsertionDestination {
  struct Dependencies {
    var frontmostApplication: () -> NSRunningApplication?
    var focusedElement: (pid_t) -> AXUIElement?
    var selectedRange: (AXUIElement) -> CFRange?
    var selectedText: (AXUIElement, CFRange) -> String?
    var isEditable: (AXUIElement) -> Bool
    var isAlive: (NSRunningApplication) -> Bool
    var activate: (NSRunningApplication) -> Bool
    var ownProcessIdentifier: pid_t
    var rawFocusedElement: (pid_t) -> AXUIElement? = { _ in nil }
    var focusedWindow: (pid_t) -> AXUIElement? = { _ in nil }
    var elementWindow: (AXUIElement) -> AXUIElement? = { _ in nil }
    var hasWritableValue: (AXUIElement) -> Bool = { _ in false }
    var focus: (AXUIElement) -> Bool = { _ in false }

    static var live: Self {
      Self(
        frontmostApplication: { NSWorkspace.shared.frontmostApplication },
        focusedElement: { TextInputFocusResolver.focusedElement(inApplication: $0) },
        selectedRange: { element in
          guard let value = attribute(kAXSelectedTextRangeAttribute, of: element),
            CFGetTypeID(value) == AXValueGetTypeID()
          else { return nil }
          var range = CFRange()
          guard AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cfRange, &range),
            range.location >= 0, range.length >= 0
          else { return nil }
          return range
        },
        selectedText: { element, selection in
          var range = selection
          guard let value = AXValueCreate(.cfRange, &range) else { return nil }
          var result: CFTypeRef?
          guard
            AXUIElementCopyParameterizedAttributeValue(
              element, kAXStringForRangeParameterizedAttribute as CFString, value, &result
            ) == .success
          else { return nil }
          return result as? String
        },
        isEditable: { element in
          guard let role = attribute(kAXRoleAttribute, of: element) as? String,
            [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField"].contains(role),
            attribute(kAXSubroleAttribute, of: element) as? String != kAXSecureTextFieldSubrole,
            attribute(kAXEnabledAttribute, of: element) as? Bool != false,
            attribute("AXEditable", of: element) as? Bool != false
          else { return false }
          return true
        },
        isAlive: { !$0.isTerminated },
        activate: { $0.activate() },
        ownProcessIdentifier: ProcessInfo.processInfo.processIdentifier,
        rawFocusedElement: { pid in
          elementAttribute(kAXFocusedUIElementAttribute, of: AXUIElementCreateApplication(pid))
        },
        focusedWindow: { pid in
          elementAttribute(kAXFocusedWindowAttribute, of: AXUIElementCreateApplication(pid))
        },
        elementWindow: { elementAttribute(kAXWindowAttribute, of: $0) },
        hasWritableValue: { element in
          var writable: DarwinBoolean = false
          return AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &writable)
            == .success && writable.boolValue
        },
        focus: { element in
          AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            == .success
        }
      )
    }
  }

  let application: NSRunningApplication
  let focusedElement: AXUIElement
  let initialSelectedRange: CFRange?
  let selectedText: String?
  let allowsRichContent: Bool
  private let capturedWindow: AXUIElement?
  private let dependencies: Dependencies

  static func capture(includeSelectedText: Bool = true) -> Self? {
    capture(includeSelectedText: includeSelectedText, dependencies: .live)
  }

  static func capture(includeSelectedText: Bool = true, dependencies: Dependencies) -> Self? {
    guard let application = dependencies.frontmostApplication(),
      application.processIdentifier != dependencies.ownProcessIdentifier,
      dependencies.isAlive(application),
      let element = dependencies.focusedElement(application.processIdentifier),
      dependencies.isEditable(element)
    else { return nil }
    let window = dependencies.elementWindow(element)
    let range = dependencies.selectedRange(element)
    var text: String?
    if includeSelectedText, let range, range.location >= 0, range.length > 0, range.length <= 1024 {
      if let selection = dependencies.selectedText(element, range), selection.utf16.count <= 1024 {
        text = selection
      }
    }
    let destination = Self(
      application: application,
      focusedElement: element,
      initialSelectedRange: range,
      selectedText: text,
      allowsRichContent:
        RecipientContentPolicy.assess(
          bundleIdentifier: application.bundleIdentifier,
          input: RecipientContentPolicy.inputTraits(for: element)
        )
        .allowsRichContent,
      capturedWindow: window,
      dependencies: dependencies
    )
    return destination.isValidForDelivery() ? destination : nil
  }

  func restoreFocus() -> Bool {
    guard canActivateRecipient() else { return false }
    if hasUnchangedControl() {
      return canActivateRecipient() && dependencies.activate(application)
    }
    guard let window = capturedWindow, canReassertFocus(in: window),
      dependencies.activate(application), canActivateRecipient()
    else { return false }
    if hasUnchangedControl() {
      return isInFocusedWindow(window) && canActivateRecipient()
    }
    return canReassertFocus(in: window) && dependencies.focus(focusedElement)
  }

  func isValidForDelivery() -> Bool {
    guard dependencies.frontmostApplication()?.processIdentifier == application.processIdentifier,
      hasUnchangedControl()
    else { return false }
    if let capturedWindow, !isInFocusedWindow(capturedWindow) { return false }
    guard let focused = dependencies.focusedElement(application.processIdentifier),
      CFEqual(focused, focusedElement)
    else { return false }
    return dependencies.frontmostApplication()?.processIdentifier == application.processIdentifier
  }

  private func canActivateRecipient() -> Bool {
    guard let pid = dependencies.frontmostApplication()?.processIdentifier else { return false }
    return pid == application.processIdentifier || pid == dependencies.ownProcessIdentifier
  }

  private func isInFocusedWindow(_ window: AXUIElement) -> Bool {
    guard let elementWindow = dependencies.elementWindow(focusedElement),
      CFEqual(elementWindow, window),
      let focusedWindow = dependencies.focusedWindow(application.processIdentifier)
    else { return false }
    return CFEqual(focusedWindow, window)
  }

  private func hasWindowFocus(_ window: AXUIElement) -> Bool {
    let pid = application.processIdentifier
    guard isInFocusedWindow(window), dependencies.focusedElement(pid) == nil,
      let rawFocus = dependencies.rawFocusedElement(pid), CFEqual(rawFocus, window),
      isInFocusedWindow(window), dependencies.focusedElement(pid) == nil,
      let latestRawFocus = dependencies.rawFocusedElement(pid)
    else { return false }
    return CFEqual(latestRawFocus, window)
  }

  private func canReassertFocus(in window: AXUIElement) -> Bool {
    guard initialSelectedRange != nil, canActivateRecipient(), dependencies.isAlive(application),
      hasWindowFocus(window),
      dependencies.isEditable(focusedElement), hasUnchangedRange(of: focusedElement),
      dependencies.hasWritableValue(focusedElement), hasWindowFocus(window),
      dependencies.isAlive(application)
    else { return false }
    return canActivateRecipient()
  }

  private func hasUnchangedControl() -> Bool {
    guard dependencies.isAlive(application), dependencies.isEditable(focusedElement),
      let focused = dependencies.focusedElement(application.processIdentifier),
      CFEqual(focused, focusedElement)
    else { return false }
    guard hasUnchangedRange(of: focused),
      let latestFocused = dependencies.focusedElement(application.processIdentifier)
    else { return false }
    return CFEqual(latestFocused, focusedElement)
  }

  private func hasUnchangedRange(of element: AXUIElement) -> Bool {
    switch (initialSelectedRange, dependencies.selectedRange(element)) {
    case (.none, .none): return true
    case (.some(let initial), .some(let current)):
      return initial.location == current.location && initial.length == current.length
    default: return false
    }
  }
}

private func elementAttribute(_ name: String, of element: AXUIElement) -> AXUIElement? {
  guard let value = attribute(name, of: element), CFGetTypeID(value) == AXUIElementGetTypeID()
  else { return nil }
  return unsafeBitCast(value, to: AXUIElement.self)
}

private func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
  var value: CFTypeRef?
  guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
    return nil
  }
  return value
}
