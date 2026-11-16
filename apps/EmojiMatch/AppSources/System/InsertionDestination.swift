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
        ownProcessIdentifier: ProcessInfo.processInfo.processIdentifier
      )
    }
  }

  let application: NSRunningApplication
  let focusedElement: AXUIElement
  let initialSelectedRange: CFRange?
  let selectedText: String?
  let allowsRichContent: Bool
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
      dependencies: dependencies
    )
    return destination.isValidForDelivery() ? destination : nil
  }

  func restoreFocus() -> Bool {
    guard let frontmost = dependencies.frontmostApplication(),
      frontmost.processIdentifier == application.processIdentifier
        || frontmost.processIdentifier == dependencies.ownProcessIdentifier,
      hasUnchangedControl()
    else { return false }
    guard let current = dependencies.frontmostApplication(),
      current.processIdentifier == application.processIdentifier
        || current.processIdentifier == dependencies.ownProcessIdentifier
    else { return false }
    return dependencies.activate(application)
  }

  func isValidForDelivery() -> Bool {
    guard dependencies.frontmostApplication()?.processIdentifier == application.processIdentifier,
      hasUnchangedControl()
    else { return false }
    return dependencies.frontmostApplication()?.processIdentifier == application.processIdentifier
  }

  private func hasUnchangedControl() -> Bool {
    guard dependencies.isAlive(application), dependencies.isEditable(focusedElement),
      let focused = dependencies.focusedElement(application.processIdentifier),
      CFEqual(focused, focusedElement)
    else { return false }
    let current = dependencies.selectedRange(focused)
    let unchangedRange: Bool
    switch (initialSelectedRange, current) {
    case (.none, .none): unchangedRange = true
    case (.some(let initial), .some(let current)):
      unchangedRange = initial.location == current.location && initial.length == current.length
    default: unchangedRange = false
    }
    guard unchangedRange,
      let latestFocused = dependencies.focusedElement(application.processIdentifier)
    else { return false }
    return CFEqual(latestFocused, focusedElement)
  }
}

private func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
  var value: CFTypeRef?
  guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
    return nil
  }
  return value
}
