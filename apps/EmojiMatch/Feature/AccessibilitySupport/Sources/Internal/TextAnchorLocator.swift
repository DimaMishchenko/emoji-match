import AppKit
import ApplicationServices

struct TextAnchorLocator {
  private enum Constants {
    static let manualAccessibilityWarmupDelay: CFTimeInterval = 0.15
    static let maximumDescendantDepth = 4
    static let maximumCandidateCount = 64
  }

  private let elements: any AccessibilityElementReading
  private var manualAccessibilityWarmup = ManualAccessibilityWarmup()

  init(elements: any AccessibilityElementReading = AccessibilityElementReader()) {
    self.elements = elements
  }

  mutating func anchorRect() -> CGRect? {
    guard AXIsProcessTrusted() else {
      return nil
    }

    let didWarmUpManualAccessibility = manualAccessibilityWarmup.prepareFrontmostApplication()
    if didWarmUpManualAccessibility {
      pauseForManualAccessibilityWarmup()
    }

    if let anchorRect = anchorRectForCurrentFocus() {
      return anchorRect
    }

    guard didWarmUpManualAccessibility else {
      return nil
    }

    pauseForManualAccessibilityWarmup()
    return anchorRectForCurrentFocus()
  }
}

private extension TextAnchorLocator {
  func pauseForManualAccessibilityWarmup() {
    CFRunLoopRunInMode(.defaultMode, Constants.manualAccessibilityWarmupDelay, false)
  }

  func anchorRectForCurrentFocus() -> CGRect? {
    guard let focusedElement = elements.refreshedFocusedElement(after: elements.focusedElement())
    else {
      return nil
    }

    return anchorRect(startingFrom: focusedElement)
  }
}

extension TextAnchorLocator {
  func anchorRect(startingFrom focusedElement: AXUIElement) -> CGRect? {
    guard !elements.isWindowElement(focusedElement) else {
      return nil
    }

    guard let inputElement = TextInputFocusLocator(elements: elements).resolve(focusedElement)
    else {
      return nil
    }

    let inputElementRect = editableElementRect(for: inputElement)
    let candidates = candidateElements(from: inputElement)
    for element in candidates {
      if let bounds = exactAnchorRect(for: element),
        FocusedTextAnchorHeuristics.isPlausibleTextBounds(
          bounds, selectionRange: nil, elementRect: inputElementRect)
      {
        return bounds
      }
    }

    let selections = candidates.compactMap { element -> (AXUIElement, CFRange)? in
      validSelectedTextRange(for: element).map { (element, $0) }
    }
    for (element, range) in selections {
      if let bounds = adjacentCharacterRect(
        for: range, in: element, elementRect: editableElementRect(for: element)),
        FocusedTextAnchorHeuristics.isPlausibleTextBounds(
          bounds, selectionRange: nil, elementRect: inputElementRect)
      {
        return bounds
      }
    }
    for (element, range) in selections {
      if let bounds = lineRangeCaretRect(
        for: range, in: element, elementRect: editableElementRect(for: element)),
        FocusedTextAnchorHeuristics.isPlausibleTextBounds(
          bounds, selectionRange: nil, elementRect: inputElementRect)
      {
        return bounds
      }
    }
    for (element, range) in selections {
      if let bounds = estimatedCaretRect(
        for: element, selectedTextRange: range, elementRect: editableElementRect(for: element)),
        FocusedTextAnchorHeuristics.isPlausibleTextBounds(
          bounds, selectionRange: nil, elementRect: inputElementRect)
      {
        return bounds
      }
    }

    return inputElementRect
  }
}

private extension TextAnchorLocator {
  func candidateElements(from inputElement: AXUIElement) -> [AXUIElement] {
    var candidates = [inputElement]
    var queue = [(element: inputElement, depth: 0)]
    var visited = [inputElement]
    var queueIndex = 0

    while queueIndex < queue.count, visited.count < Constants.maximumCandidateCount {
      let current = queue[queueIndex]
      queueIndex += 1
      guard current.depth < Constants.maximumDescendantDepth else {
        continue
      }

      for child in elements.childElements(of: current.element)
      where !visited.contains(where: { CFEqual($0, child) }) {
        visited.append(child)
        queue.append((child, current.depth + 1))
        if isTextInputCandidate(child) {
          candidates.append(child)
        }
        guard visited.count < Constants.maximumCandidateCount else {
          break
        }
      }
    }
    return candidates
  }

  func validSelectedTextRange(for element: AXUIElement) -> CFRange? {
    guard let range = elements.selectedTextRange(for: element),
      FocusedTextAnchorHeuristics.isValidRange(
        range, textLength: elements.stringValue(of: element).map { ($0 as NSString).length })
    else {
      return nil
    }
    return range
  }

  func exactAnchorRect(for element: AXUIElement) -> CGRect? {
    let elementRect = editableElementRect(for: element)
    let selectedTextRange = validSelectedTextRange(for: element)
    if let marker = elements.selectedTextMarkerRange(for: element),
      let bounds = elements.textMarkerSelectionBounds(for: marker, in: element),
      FocusedTextAnchorHeuristics.isPlausibleTextBounds(
        bounds, selectionRange: selectedTextRange, elementRect: elementRect)
    {
      return bounds
    }
    if let selectedTextRange {
      return selectionBounds(for: selectedTextRange, in: element, elementRect: elementRect)
    }
    return nil
  }

  func editableElementRect(for element: AXUIElement) -> CGRect? {
    guard isTextInputCandidate(element), let rect = elements.elementRect(for: element),
      FocusedTextAnchorHeuristics.isUsableRect(rect)
    else {
      return nil
    }
    return rect
  }

  func adjacentCharacterRect(
    for selectedTextRange: CFRange,
    in element: AXUIElement,
    elementRect: CGRect?
  ) -> CGRect? {
    guard selectedTextRange.length == 0 else {
      return nil
    }
    if let text = elements.stringValue(of: element).map(NSString.init),
      FocusedTextAnchorHeuristics.isAtLineStart(in: text, selectedTextRange: selectedTextRange)
    {
      return nil
    }

    let textLength = elements.stringValue(of: element).map { ($0 as NSString).length }
    for range in FocusedTextAnchorHeuristics.candidateCharacterRanges(for: selectedTextRange)
    where FocusedTextAnchorHeuristics.isValidRange(range, textLength: textLength) {
      var mutableRange = range
      guard let rangeValue = AXValueCreate(.cfRange, &mutableRange),
        let bounds = elements.boundsForRangeValue(rangeValue, in: element),
        FocusedTextAnchorHeuristics.isPlausibleTextBounds(
          bounds, selectionRange: nil, elementRect: elementRect)
      else {
        continue
      }

      let string = elements.stringForRangeValue(rangeValue, in: element)
      if string?.contains(where: \.isNewline) == true {
        continue
      }

      if range.location < selectedTextRange.location {
        return CGRect(x: bounds.maxX, y: bounds.minY, width: 1, height: bounds.height)
      }

      return CGRect(x: bounds.minX, y: bounds.minY, width: 1, height: bounds.height)
    }

    return nil
  }

  func lineRangeCaretRect(
    for selectedTextRange: CFRange,
    in element: AXUIElement,
    elementRect: CGRect?
  ) -> CGRect? {
    guard
      selectedTextRange.length == 0,
      let text = elements.stringValue(of: element).map(NSString.init),
      FocusedTextAnchorHeuristics.isAtLineStart(in: text, selectedTextRange: selectedTextRange),
      let insertionIndex = FocusedTextAnchorHeuristics.insertionIndex(
        in: text,
        for: selectedTextRange
      ),
      let lineNumber = elements.lineNumber(for: insertionIndex, in: element),
      FocusedTextAnchorHeuristics.isPlausibleInsertionPointLine(lineNumber),
      let lineRange = elements.rangeForLine(lineNumber, in: element),
      FocusedTextAnchorHeuristics.isValidRange(lineRange, textLength: text.length),
      lineRange.location <= insertionIndex,
      lineRange.location + lineRange.length >= insertionIndex,
      let lineRangeValue = rangeValue(for: lineRange),
      let lineBounds = elements.boundsForRangeValue(lineRangeValue, in: element),
      FocusedTextAnchorHeuristics.isPlausibleTextBounds(
        lineBounds, selectionRange: nil, elementRect: elementRect)
    else {
      return nil
    }

    return CGRect(
      x: lineBounds.minX,
      y: lineBounds.minY,
      width: 1,
      height: lineBounds.height
    )
  }

  func estimatedCaretRect(
    for element: AXUIElement,
    selectedTextRange: CFRange,
    elementRect: CGRect?
  ) -> CGRect? {
    guard let elementRect else {
      return nil
    }

    let lineHeight = min(FocusedTextAnchorHeuristics.defaultEstimatedLineHeight, elementRect.height)
    let y: CGFloat

    if isSingleLineTextElement(element) {
      y = min(
        max(elementRect.midY - (lineHeight / 2), elementRect.minY),
        elementRect.maxY - lineHeight
      )
    } else {
      let lineIndex = estimatedLineIndex(for: element, selectedTextRange: selectedTextRange)
      y = min(
        max(
          elementRect.minY + FocusedTextAnchorHeuristics.estimatedTextVerticalInset
            + (CGFloat(lineIndex) * lineHeight),
          elementRect.minY
        ),
        elementRect.maxY - lineHeight
      )
    }

    return CGRect(
      x: estimatedCaretX(for: element, selectedTextRange: selectedTextRange, in: elementRect),
      y: y,
      width: 1,
      height: lineHeight
    )
  }

  func estimatedLineIndex(for element: AXUIElement, selectedTextRange: CFRange) -> Int {
    if let text = elements.stringValue(of: element).map(NSString.init),
      let insertionIndex = FocusedTextAnchorHeuristics.insertionIndex(
        in: text,
        for: selectedTextRange
      )
    {
      return FocusedTextAnchorHeuristics.visualLineIndex(in: text.substring(to: insertionIndex))
    }

    guard let line = elements.insertionPointLine(of: element),
      FocusedTextAnchorHeuristics.isPlausibleInsertionPointLine(line)
    else {
      return 0
    }
    return max(line - 1, 0)
  }

  func estimatedCaretX(
    for element: AXUIElement,
    selectedTextRange: CFRange,
    in elementRect: CGRect
  ) -> CGFloat {
    let minX = max(
      elementRect.minX,
      min(
        elementRect.minX + leadingTextInset(for: element, in: elementRect),
        elementRect.maxX - 1
      )
    )
    let maxX = max(
      minX,
      elementRect.maxX - FocusedTextAnchorHeuristics.estimatedTextHorizontalInset
    )

    guard
      let text = elements.stringValue(of: element).map(NSString.init),
      let insertionIndex = FocusedTextAnchorHeuristics.insertionIndex(
        in: text,
        for: selectedTextRange
      )
    else {
      return minX
    }

    let prefix = text.substring(to: insertionIndex)
    let column = prefix.components(separatedBy: "\n").last?.count ?? 0
    return min(
      minX + (CGFloat(column) * FocusedTextAnchorHeuristics.defaultEstimatedCharacterWidth),
      maxX
    )
  }

  func selectionBounds(
    for selectedTextRange: CFRange,
    in element: AXUIElement,
    elementRect: CGRect?
  ) -> CGRect? {
    var range = selectedTextRange
    guard let rangeValue = AXValueCreate(.cfRange, &range),
      let bounds = elements.boundsForRangeValue(rangeValue, in: element)
    else {
      return nil
    }

    guard
      FocusedTextAnchorHeuristics.isPlausibleTextBounds(
        bounds, selectionRange: selectedTextRange, elementRect: elementRect)
    else {
      return nil
    }

    return bounds
  }

  func leadingTextInset(for element: AXUIElement, in elementRect: CGRect) -> CGFloat {
    let baseInset =
      elements.role(of: element) == "AXSearchField"
      ? FocusedTextAnchorHeuristics.estimatedSearchFieldHorizontalInset
      : FocusedTextAnchorHeuristics.estimatedTextHorizontalInset

    guard let accessory = leadingAccessoryBounds(in: element, elementRect: elementRect) else {
      return baseInset
    }
    let spacing: CGFloat =
      accessory.height >= elementRect.height
      ? 0 : FocusedTextAnchorHeuristics.estimatedAccessoryTextSpacing
    return FocusedTextAnchorHeuristics.horizontalInset(
      baseInset: baseInset,
      elementMinX: elementRect.minX,
      leadingAccessoryTrailingEdge: accessory.maxX,
      accessorySpacing: spacing
    )
  }

  func leadingAccessoryBounds(in element: AXUIElement, elementRect: CGRect) -> CGRect? {
    let leadingLimit =
      elementRect.minX + FocusedTextAnchorHeuristics.maximumEstimatedAccessoryTextInset
    var candidates = elements.childElements(of: element)
    if let parent = elements.ancestorElements(of: element, maxDepth: 1).first,
      let parentRect = elements.elementRect(for: parent),
      abs(parentRect.minX - elementRect.minX) <= 2,
      abs(parentRect.minY - elementRect.minY) <= 2,
      abs(parentRect.width - elementRect.width) <= 2,
      abs(parentRect.height - elementRect.height) <= 2
    {
      candidates += elements.childElements(of: parent)
        .filter { sibling in
          guard let rect = elements.elementRect(for: sibling),
            abs(rect.minX - elementRect.minX) <= 2,
            abs(rect.minY - elementRect.minY) <= 2,
            abs(rect.height - elementRect.height) <= 2
          else { return false }
          return isLeadingAccessory(sibling)
        }
    }
    return
      candidates.compactMap { child -> CGRect? in
        guard !CFEqual(child, element), isLeadingAccessory(child),
          let rect = elements.elementRect(for: child),
          FocusedTextAnchorHeuristics.isUsableRect(rect),
          rect.minX >= elementRect.minX,
          rect.maxX <= leadingLimit,
          rect.minY >= elementRect.minY,
          rect.maxY <= elementRect.maxY
        else { return nil }
        return rect
      }
      .max { $0.maxX < $1.maxX }
  }

  func isLeadingAccessory(_ element: AXUIElement) -> Bool {
    let role = elements.role(of: element)
    if role == kAXButtonRole || role == kAXImageRole { return true }
    guard role == kAXGroupRole, let rect = elements.elementRect(for: element) else { return false }
    return elements.childElements(of: element)
      .contains { child in
        let childRole = elements.role(of: child)
        return (childRole == kAXButtonRole || childRole == kAXImageRole)
          && elements.elementRect(for: child) == rect
      }
  }

  func rangeValue(for range: CFRange) -> AXValue? {
    var mutableRange = range
    return AXValueCreate(.cfRange, &mutableRange)
  }
}

private extension TextAnchorLocator {
  func isTextInputCandidate(_ element: AXUIElement) -> Bool {
    TextInputFocusLocator(elements: elements).isTextInputCandidate(element)
  }

  func isSingleLineTextElement(_ element: AXUIElement) -> Bool {
    elements.isSingleLineTextRole(elements.role(of: element))
  }
}
