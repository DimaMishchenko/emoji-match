import ApplicationServices

struct RecipientContentPolicy {
  struct InputTraits {
    var role: String?
    var subrole: String?
    var isWebContent = false
    var isInSearchLandmark = false
    var ownsDialogResultList = false
    var hasMultilineEditableAncestor = false
  }

  enum Assessment {
    case unknown
    case webSearch
    case terminal

    var allowsRichContent: Bool { self == .unknown }
  }

  static func assess(bundleIdentifier: String?, input: InputTraits) -> Assessment {
    if bundleIdentifier == "com.apple.Terminal", input.role == kAXTextAreaRole {
      return .terminal
    }
    guard input.isWebContent, !input.hasMultilineEditableAncestor,
      [kAXTextFieldRole, kAXComboBoxRole, "AXSearchField"].contains(input.role)
    else { return .unknown }
    if input.subrole == "AXSearchField" || input.role == "AXSearchField"
      || input.isInSearchLandmark || input.ownsDialogResultList
    {
      return .webSearch
    }
    return .unknown
  }

  static func inputTraits(
    for element: AXUIElement,
    attribute: (AXUIElement, String) -> CFTypeRef? = readAttribute
  ) -> InputTraits {
    let lineage = ancestors(including: element, attribute: attribute)
    let dialog = lineage.first { isDialog($0, attribute: attribute) }
    let relationships = ["AXOwns", "AXLinkedUIElements"]
      .flatMap { name -> [AXUIElement] in
        guard let values = attribute(element, name) as? [AXUIElement], values.count <= 128 else {
          return []
        }
        return values
      }
    let ownsDialogResultList =
      dialog.map { dialog in
        relationships.contains { related in
          attribute(related, kAXRoleAttribute) as? String == kAXListRole
            && ancestors(including: related, attribute: attribute)
              .first(where: { isDialog($0, attribute: attribute) })
              .map { CFEqual($0, dialog) } == true
        }
      } ?? false
    return InputTraits(
      role: attribute(element, kAXRoleAttribute) as? String,
      subrole: attribute(element, kAXSubroleAttribute) as? String,
      isWebContent: attribute(element, "AXDOMClassList") as? [String] != nil
        || attribute(element, "AXDOMIdentifier") as? String != nil
        || lineage.contains { attribute($0, kAXRoleAttribute) as? String == "AXWebArea" },
      isInSearchLandmark: lineage.contains {
        attribute($0, kAXSubroleAttribute) as? String == "AXLandmarkSearch"
      },
      ownsDialogResultList: ownsDialogResultList,
      hasMultilineEditableAncestor: lineage.dropFirst()
        .contains {
          attribute($0, kAXRoleAttribute) as? String == kAXTextAreaRole
        })
  }

  private static func ancestors(
    including element: AXUIElement, attribute: (AXUIElement, String) -> CFTypeRef?
  ) -> [AXUIElement] {
    var result = [element]
    var current = element
    for _ in 0..<12 {
      guard let raw = attribute(current, kAXParentAttribute),
        CFGetTypeID(raw) == AXUIElementGetTypeID()
      else { break }
      let parent = unsafeBitCast(raw, to: AXUIElement.self)
      guard !result.contains(where: { CFEqual($0, parent) }) else { break }
      result.append(parent)
      current = parent
    }
    return result
  }

  private static func isDialog(
    _ element: AXUIElement, attribute: (AXUIElement, String) -> CFTypeRef?
  ) -> Bool {
    attribute(element, kAXRoleAttribute) as? String == "AXDialog"
      || ["AXApplicationDialog", "AXDialog"]
        .contains(
          attribute(element, kAXSubroleAttribute) as? String)
  }

  nonisolated private static func readAttribute(
    _ element: AXUIElement, _ name: String
  ) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
      return nil
    }
    return value
  }
}
