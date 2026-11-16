import ApplicationServices

struct TextInputFocusLocator {
  let elements: any AccessibilityElementReading

  func resolve(_ focused: AXUIElement) -> AXUIElement? {
    let lineage = [focused] + elements.ancestorElements(of: focused, maxDepth: 12)
    if let listIndex = lineage.firstIndex(where: { elements.role(of: $0) == kAXListRole }) {
      if let input = lineage.prefix(listIndex).first(where: isSemanticInput) {
        return input
      }
      guard let dialogIndex = lineage.firstIndex(where: elements.isDialog),
        listIndex < dialogIndex
      else { return nil }
      return owningInput(for: lineage[listIndex], in: lineage[dialogIndex])
    }
    return lineage.first(where: isTextInputCandidate)
  }

  func isTextInputCandidate(_ element: AXUIElement) -> Bool {
    let role = elements.role(of: element)
    guard role != kAXWindowRole, role != kAXApplicationRole, role != kAXStaticTextRole else {
      return false
    }
    if isSemanticInput(element) { return true }
    guard role == kAXGroupRole || role == "AXUnknown" || role == nil else { return false }
    return elements.insertionPointLine(of: element)
      .map(FocusedTextAnchorHeuristics.isPlausibleInsertionPointLine) ?? false
  }

  private func isSemanticInput(_ element: AXUIElement) -> Bool {
    elements.isEditableTextRole(elements.role(of: element))
      || elements.isExplicitlyEditable(element)
  }

  private func owningInput(for list: AXUIElement, in dialog: AXUIElement) -> AXUIElement? {
    guard let dialogRect = elements.elementRect(for: dialog),
      FocusedTextAnchorHeuristics.isUsableRect(dialogRect),
      let listRect = elements.elementRect(for: list),
      FocusedTextAnchorHeuristics.isUsableRect(listRect), dialogRect.contains(listRect)
    else { return nil }
    var queue = [(dialog, 0)]
    var visited = [dialog]
    var owners: [AXUIElement] = []
    var index = 0
    while index < queue.count {
      let (current, depth) = queue[index]
      index += 1
      if isSemanticInput(current) {
        guard let relationships = elements.ownedOrLinkedElements(of: current),
          relationships.count < 129
        else { return nil }
        if relationships.contains(where: { CFEqual($0, list) }) {
          owners.append(current)
          guard owners.count == 1 else { return nil }
        }
      }
      if CFEqual(current, list) || (!CFEqual(current, dialog) && elements.isDialog(current)) {
        continue
      }
      guard let children = elements.completeChildElements(of: current),
        children.count < 129, children.isEmpty || depth < 8
      else { return nil }
      for child in children where !visited.contains(where: { CFEqual($0, child) }) {
        guard visited.count < 128 else { return nil }
        visited.append(child)
        queue.append((child, depth + 1))
      }
    }
    guard let owner = owners.first, let rect = elements.elementRect(for: owner),
      FocusedTextAnchorHeuristics.isUsableRect(rect), dialogRect.contains(rect)
    else { return nil }
    return owner
  }
}
