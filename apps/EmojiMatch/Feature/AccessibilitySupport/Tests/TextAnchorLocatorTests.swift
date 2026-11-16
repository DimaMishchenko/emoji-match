import ApplicationServices
import Foundation
import Testing

@testable import AccessibilitySupport

@Suite struct TextAnchorLocatorTests {
  @Test func activeResultResolvesExplicitOwnerForAnchorAndInsertion() {
    for linked in [false, true] {
      let fixture = ownedInputFixture()
      fixture.input.links = linked ? [fixture.list.element] : []
      fixture.input.owns = linked ? [] : [fixture.list.element]
      let reader = AnchorReader(fixture.nodes)
      let resolved = TextInputFocusLocator(elements: reader).resolve(fixture.result.element)
      #expect(resolved.map { CFEqual($0, fixture.input.element) } == true)
      #expect(
        TextAnchorLocator(elements: reader).anchorRect(startingFrom: fixture.result.element)
          == fixture.input.rect)
    }
  }

  @Test func unrelatedInputAndFakeSelectionDoNotResolveResultLabel() {
    let fixture = ownedInputFixture()
    fixture.input.owns = []
    let reader = AnchorReader(fixture.nodes)
    #expect(TextInputFocusLocator(elements: reader).resolve(fixture.result.element) == nil)
    #expect(
      TextAnchorLocator(elements: reader).anchorRect(startingFrom: fixture.result.element) == nil)
  }

  @Test func ambiguousOwnersAreRejectedEvenWhenOneHasInvalidGeometry() {
    let fixture = ownedInputFixture()
    let other = AnchorElement(5)
    other.links = [fixture.list.element]
    fixture.dialog.children.append(other.element)
    for rect in [fixture.input.rect, nil] {
      other.rect = rect
      let reader = AnchorReader(fixture.nodes + [other])
      #expect(TextInputFocusLocator(elements: reader).resolve(fixture.result.element) == nil)
    }
  }

  @Test func ownerOutsideNearestDialogIsNotSearched() {
    let fixture = ownedInputFixture()
    let outer = AnchorElement(5)
    outer.role = kAXWindowRole
    outer.children = [fixture.dialog.element, fixture.input.element]
    fixture.dialog.children = [fixture.list.element]
    fixture.result.ancestors.append(outer.element)
    let reader = AnchorReader(fixture.nodes + [outer])
    #expect(TextInputFocusLocator(elements: reader).resolve(fixture.result.element) == nil)
  }

  @Test func unreadableOwnerBranchOrRelationshipsRejectOtherwiseUniqueOwner() {
    let fixture = ownedInputFixture()
    let branch = AnchorElement(5)
    branch.role = kAXGroupRole
    fixture.dialog.children.append(branch.element)
    let reader = AnchorReader(fixture.nodes + [branch])
    branch.childrenReadable = false
    #expect(TextInputFocusLocator(elements: reader).resolve(fixture.result.element) == nil)
    branch.childrenReadable = true
    branch.role = kAXTextFieldRole
    branch.relationshipsReadable = false
    #expect(TextInputFocusLocator(elements: reader).resolve(fixture.result.element) == nil)
    branch.relationshipsReadable = true
    #expect(
      TextInputFocusLocator(elements: reader).resolve(fixture.result.element)
        .map { CFEqual($0, fixture.input.element) } == true)
  }

  @Test func staleOwnerGeometryIsRejectedAndStaleCaretStaysWithinOwner() {
    let fixture = ownedInputFixture()
    let reader = AnchorReader(fixture.nodes)
    for rect in [
      nil, CGRect.zero, CGRect(x: 900, y: 900, width: 200, height: 34),
      CGRect(x: CGFloat.infinity, y: 127, width: 200, height: 34)
    ] {
      fixture.input.rect = rect
      #expect(TextInputFocusLocator(elements: reader).resolve(fixture.result.element) == nil)
      #expect(
        TextAnchorLocator(elements: reader).anchorRect(startingFrom: fixture.result.element) == nil)
    }
    fixture.input.rect = CGRect(x: 478, y: 127, width: 556, height: 34)
    fixture.input.markerBounds = fixture.result.rect
    #expect(
      TextAnchorLocator(elements: reader).anchorRect(startingFrom: fixture.result.element)
        == fixture.input.rect)
  }

  @Test func staticTextInsertionSignalIsRejectedButGroupWrapperIsPreserved() {
    let field = AnchorElement(1)
    field.role = kAXStaticTextRole
    field.insertionLine = 0
    let reader = AnchorReader([field])
    #expect(TextAnchorLocator(elements: reader).anchorRect(startingFrom: field.element) == nil)
    field.role = kAXGroupRole
    #expect(
      TextAnchorLocator(elements: reader).anchorRect(startingFrom: field.element) == field.rect)
  }

  @Test func resultWithoutDialogDoesNotUseFakeInsertionLineOnList() {
    let fixture = ownedInputFixture()
    fixture.list.insertionLine = 0
    fixture.dialog.dialog = false
    let reader = AnchorReader(fixture.nodes)
    #expect(TextInputFocusLocator(elements: reader).resolve(fixture.result.element) == nil)
  }

  @Test func nestedDialogInputCannotOwnOuterDialogResult() {
    let fixture = ownedInputFixture()
    let nested = AnchorElement(5)
    nested.role = kAXGroupRole
    nested.dialog = true
    nested.children = [fixture.input.element]
    fixture.dialog.children = [fixture.list.element, nested.element]
    let reader = AnchorReader(fixture.nodes + [nested])
    #expect(TextInputFocusLocator(elements: reader).resolve(fixture.result.element) == nil)
  }

  @Test func ownerSearchFailsClosedAtTraversalBudgetAndHandlesCycles() {
    let fixture = ownedInputFixture()
    fixture.dialog.children.append(fixture.dialog.element)
    let reader = AnchorReader(fixture.nodes)
    #expect(
      TextInputFocusLocator(elements: reader).resolve(fixture.result.element)
        .map { CFEqual($0, fixture.input.element) } == true)
    let extra = (10..<140).map { AnchorElement(pid_t($0)) }
    fixture.dialog.children += extra.map(\.element)
    #expect(
      TextInputFocusLocator(elements: AnchorReader(fixture.nodes + extra))
        .resolve(fixture.result.element) == nil)
  }

  @Test func ownedInputKeepsExactGeometryWithinItsOwnSubtree() {
    let fixture = ownedInputFixture()
    let editor = AnchorElement(5)
    editor.rect = fixture.input.rect
    editor.markerBounds = CGRect(x: 500, y: 130, width: 1, height: 18)
    fixture.input.children = [editor.element]
    let reader = AnchorReader(fixture.nodes + [editor])
    #expect(
      TextAnchorLocator(elements: reader).anchorRect(startingFrom: fixture.result.element)
        == editor.markerBounds)
  }

  @Test func focusedFieldWithoutSelectionUsesItsOwnBounds() {
    let field = AnchorElement(1)
    let reader = AnchorReader([field])

    #expect(
      TextAnchorLocator(elements: reader).anchorRect(startingFrom: field.element) == field.rect)
  }

  @Test func markerGeometryDoesNotRequireNumericSelection() {
    let field = AnchorElement(1)
    field.markerBounds = CGRect(x: 140, y: 110, width: 0, height: 18)
    let reader = AnchorReader([field])

    #expect(
      TextAnchorLocator(elements: reader).anchorRect(startingFrom: field.element)
        == field.markerBounds)
  }

  @Test func markerGeometrySurvivesMalformedNumericSelection() {
    let field = AnchorElement(1)
    field.selection = CFRange(location: Int.max, length: 1)
    field.markerBounds = CGRect(x: 140, y: 110, width: 1, height: 18)
    let reader = AnchorReader([field])

    #expect(
      TextAnchorLocator(elements: reader).anchorRect(startingFrom: field.element)
        == field.markerBounds)
    #expect(reader.requestedRanges.isEmpty)
  }

  @Test func malformedSelectionNeverReachesParameterizedAXLookup() {
    for range in [
      CFRange(location: -2, length: 0), CFRange(location: 0, length: -1),
      CFRange(location: Int.max, length: 1), CFRange(location: 99, length: 0)
    ] {
      let field = AnchorElement(1)
      field.text = "hello"
      field.selection = range
      let reader = AnchorReader([field])

      #expect(
        TextAnchorLocator(elements: reader).anchorRect(startingFrom: field.element) == field.rect)
      #expect(reader.requestedRanges.isEmpty)
    }
  }

  @Test func exactGeometryWinsOverEstimatedLineAndSearchInsets() {
    let field = AnchorElement(1)
    field.role = "AXSearchField"
    field.text = "hello"
    field.selection = CFRange(location: 2, length: 0)
    field.bounds["2:0"] = CGRect(x: 102, y: 110, width: 1, height: 18)
    let reader = AnchorReader([field])

    #expect(
      TextAnchorLocator(elements: reader).anchorRect(startingFrom: field.element)
        == field.bounds["2:0"])

    field.role = kAXTextAreaRole
    field.text = String(repeating: "wrapped or scrolled text\n", count: 20)
    field.selection = CFRange(location: (field.text! as NSString).length, length: 0)
    field.bounds["\(field.selection!.location):0"] = CGRect(
      x: 200, y: 120, width: 1, height: 18)
    #expect(
      TextAnchorLocator(elements: reader).anchorRect(startingFrom: field.element)
        == CGRect(x: 200, y: 120, width: 1, height: 18))
  }

  @Test func staleMarkerAndSelectedBoundsFallBackWithinFocusedField() {
    let field = AnchorElement(1)
    field.text = "hello"
    field.selection = CFRange(location: 2, length: 0)
    field.markerBounds = CGRect(x: 900, y: 900, width: 1, height: 18)
    field.bounds["2:0"] = field.markerBounds
    let reader = AnchorReader([field])
    let result = TextAnchorLocator(elements: reader).anchorRect(startingFrom: field.element)

    #expect(result == CGRect(x: 128, y: 119, width: 1, height: 22))
  }

  @Test func staleNonemptySelectionBoundsAreRejected() {
    let field = AnchorElement(1)
    field.text = "hello"
    field.selection = CFRange(location: 0, length: 3)
    field.bounds["0:3"] = CGRect(x: 100, y: 500, width: 40, height: 18)
    let reader = AnchorReader([field])
    let result = TextAnchorLocator(elements: reader).anchorRect(startingFrom: field.element)

    #expect(result == CGRect(x: 136, y: 119, width: 1, height: 22))
  }

  @Test func staleAdjacentCharacterBoundsAreRejected() {
    let field = AnchorElement(1)
    field.text = "hello"
    field.selection = CFRange(location: 2, length: 0)
    field.bounds["1:1"] = CGRect(x: 900, y: 900, width: 8, height: 18)
    field.bounds["2:1"] = field.bounds["1:1"]
    let reader = AnchorReader([field])

    #expect(
      TextAnchorLocator(elements: reader).anchorRect(startingFrom: field.element)
        == CGRect(x: 128, y: 119, width: 1, height: 22))
  }

  @Test func staleLineBoundsAreRejected() {
    let field = AnchorElement(1)
    field.role = kAXTextAreaRole
    field.text = "hello\nworld"
    field.selection = CFRange(location: 6, length: 0)
    field.lineRange = CFRange(location: 6, length: 5)
    field.bounds["6:5"] = CGRect(x: 900, y: 900, width: 40, height: 18)
    let reader = AnchorReader([field])

    #expect(
      TextAnchorLocator(elements: reader).anchorRect(startingFrom: field.element)
        == CGRect(x: 112, y: 130, width: 1, height: 22))
  }

  @Test func focusedFieldDoesNotBorrowSiblingSelection() {
    let field = AnchorElement(1)
    let sibling = AnchorElement(2)
    sibling.markerBounds = CGRect(x: 120, y: 110, width: 1, height: 18)
    let window = AnchorElement(3)
    window.role = kAXWindowRole
    field.ancestors = [window.element]
    window.children = [field.element, sibling.element]
    let reader = AnchorReader([field, sibling, window])

    #expect(
      TextAnchorLocator(elements: reader).anchorRect(startingFrom: field.element) == field.rect)
  }

  @Test func focusInsideFieldResolvesAncestorWithoutSearchingItsSiblings() {
    let focused = AnchorElement(1)
    focused.role = kAXStaticTextRole
    let field = AnchorElement(2)
    focused.ancestors = [field.element]
    let reader = AnchorReader([focused, field])

    #expect(
      TextAnchorLocator(elements: reader).anchorRect(startingFrom: focused.element) == field.rect)
  }

  @Test func nonTextFocusDoesNotSearchWindowFields() {
    let focused = AnchorElement(1)
    focused.role = kAXButtonRole
    let window = AnchorElement(2)
    window.role = kAXWindowRole
    window.insertionLine = 0
    let field = AnchorElement(3)
    focused.ancestors = [window.element]
    window.children = [focused.element, field.element]
    let reader = AnchorReader([focused, window, field])

    #expect(TextAnchorLocator(elements: reader).anchorRect(startingFrom: focused.element) == nil)
  }

  @Test func descendantExactGeometryBeatsFocusedFieldEstimate() {
    let field = AnchorElement(1)
    field.selection = CFRange(location: 0, length: 0)
    let innerField = AnchorElement(2)
    innerField.markerBounds = CGRect(x: 140, y: 110, width: 1, height: 18)
    field.children = [innerField.element]
    let reader = AnchorReader([field, innerField])

    #expect(
      TextAnchorLocator(elements: reader).anchorRect(startingFrom: field.element)
        == innerField.markerBounds)
  }

  @Test func descendantCharacterBoundsBeatWrapperFieldFallback() {
    let wrapper = AnchorElement(1)
    let editor = AnchorElement(2)
    editor.text = "hello"
    editor.selection = CFRange(location: 2, length: 0)
    editor.bounds["1:1"] = CGRect(x: 140, y: 110, width: 8, height: 18)
    wrapper.children = [editor.element]
    let reader = AnchorReader([wrapper, editor])

    #expect(
      TextAnchorLocator(elements: reader).anchorRect(startingFrom: wrapper.element)
        == CGRect(x: 148, y: 110, width: 1, height: 18))
  }

  @Test func malformedOptionalLineDoesNotDisqualifyTextField() {
    let field = AnchorElement(1)
    field.insertionLine = .max
    let reader = AnchorReader([field])

    #expect(
      TextAnchorLocator(elements: reader).anchorRect(startingFrom: field.element) == field.rect)
  }

  @Test func unknownRoleWithInsertionSignalUsesOnlyItsOwnFieldBounds() {
    let field = AnchorElement(1)
    field.role = "AXUnknown"
    field.insertionLine = 0
    let reader = AnchorReader([field])

    #expect(
      TextAnchorLocator(elements: reader).anchorRect(startingFrom: field.element) == field.rect)
    field.insertionLine = .max
    #expect(TextAnchorLocator(elements: reader).anchorRect(startingFrom: field.element) == nil)
  }

  @Test func descendantBoundsOutsideFocusedInputAreRejected() {
    let field = AnchorElement(1)
    let child = AnchorElement(2)
    child.rect = CGRect(x: 800, y: 800, width: 300, height: 60)
    child.markerBounds = CGRect(x: 820, y: 810, width: 1, height: 18)
    field.children = [child.element]
    let reader = AnchorReader([field, child])

    #expect(
      TextAnchorLocator(elements: reader).anchorRect(startingFrom: field.element) == field.rect)
  }

  @Test func endOfTextDoesNotQueryCharacterPastTextLength() {
    let field = AnchorElement(1)
    field.text = "hello"
    field.selection = CFRange(location: 5, length: 0)
    let reader = AnchorReader([field])

    _ = TextAnchorLocator(elements: reader).anchorRect(startingFrom: field.element)
    #expect(reader.requestedRanges == ["5:0", "4:1"])
  }

  @Test func invalidLineRangeIsNotSentToAX() {
    let field = AnchorElement(1)
    field.text = "hello\nworld"
    field.selection = CFRange(location: 6, length: 0)
    field.lineRange = CFRange(location: Int.max, length: 1)
    let reader = AnchorReader([field])

    _ = TextAnchorLocator(elements: reader).anchorRect(startingFrom: field.element)
    #expect(reader.requestedRanges == ["6:0"])
  }

  @Test func cyclicDescendantsTerminateUsingAXIdentity() {
    let field = AnchorElement(1)
    let wrapper = AnchorElement(2)
    wrapper.role = kAXGroupRole
    field.children = [wrapper.element]
    wrapper.children = [AXUIElementCreateApplication(1)]
    let reader = AnchorReader([field, wrapper])

    #expect(
      TextAnchorLocator(elements: reader).anchorRect(startingFrom: field.element) == field.rect)
  }

  @Test func fullHeightLeadingSiblingAccessoryDefinesTextStart() {
    let field = AnchorElement(1)
    field.role = "AXComboBox"
    field.rect = CGRect(x: 547, y: 42, width: 474, height: 48)
    field.text = ""
    field.selection = CFRange(location: 0, length: 0)
    let parent = AnchorElement(2)
    parent.role = kAXGroupRole
    parent.rect = field.rect
    let accessory = AnchorElement(3)
    accessory.role = kAXGroupRole
    accessory.rect = CGRect(x: 547, y: 42, width: 48, height: 48)
    let button = AnchorElement(4)
    button.role = kAXButtonRole
    button.rect = accessory.rect
    accessory.children = [button.element]
    parent.children = [accessory.element, field.element]
    field.ancestors = [parent.element]
    let reader = AnchorReader([field, parent, accessory, button])
    #expect(
      TextAnchorLocator(elements: reader).anchorRect(startingFrom: field.element)
        == CGRect(x: 595, y: 55, width: 1, height: 22))
  }

  @Test func siblingPlaceholderDoesNotShiftEstimatedCaret() {
    let field = AnchorElement(1)
    field.text = ""
    field.selection = CFRange(location: 0, length: 0)
    let parent = AnchorElement(2)
    parent.role = kAXGroupRole
    parent.rect = field.rect
    let placeholder = AnchorElement(3)
    placeholder.role = kAXStaticTextRole
    placeholder.rect = CGRect(x: 112, y: 119, width: 48, height: 22)
    field.ancestors = [parent.element]
    parent.children = [placeholder.element, field.element]
    let reader = AnchorReader([field, parent, placeholder])
    #expect(
      TextAnchorLocator(elements: reader).anchorRect(startingFrom: field.element)
        == CGRect(x: 112, y: 119, width: 1, height: 22))
  }

  @Test func narrowFieldEstimateStaysInsideField() {
    let field = AnchorElement(1)
    field.role = "AXSearchField"
    field.rect = CGRect(x: 100, y: 100, width: 10, height: 20)
    field.selection = CFRange(location: 0, length: 0)
    let reader = AnchorReader([field])
    let result = TextAnchorLocator(elements: reader).anchorRect(startingFrom: field.element)

    #expect(result == CGRect(x: 109, y: 100, width: 1, height: 20))
  }
}

private final class AnchorElement {
  let element: AXUIElement
  var role: String? = kAXTextFieldRole
  var dialog = false
  var owns: [AXUIElement] = []
  var links: [AXUIElement] = []
  var rect: CGRect? = CGRect(x: 100, y: 100, width: 300, height: 60)
  var text: String?
  var selection: CFRange?
  var markerBounds: CGRect?
  var insertionLine: Int?
  var lineRange: CFRange?
  var bounds: [String: CGRect] = [:]
  var ancestors: [AXUIElement] = []
  var children: [AXUIElement] = []
  var childrenReadable = true
  var relationshipsReadable = true

  init(_ identifier: pid_t) {
    element = AXUIElementCreateApplication(identifier)
  }
}

private final class AnchorReader: AccessibilityElementReading {
  let nodes: [AnchorElement]
  var requestedRanges: [String] = []

  init(_ nodes: [AnchorElement]) {
    self.nodes = nodes
  }

  func node(_ element: AXUIElement) -> AnchorElement {
    nodes.first { CFEqual($0.element, element) }!
  }

  func focusedElement() -> AXUIElement? { nodes.first?.element }
  func refreshedFocusedElement(after element: AXUIElement?) -> AXUIElement? { element }
  func ancestorElements(of element: AXUIElement, maxDepth: Int) -> [AXUIElement] {
    Array(node(element).ancestors.prefix(maxDepth))
  }
  func childElements(of element: AXUIElement) -> [AXUIElement] { node(element).children }
  func completeChildElements(of element: AXUIElement) -> [AXUIElement]? {
    node(element).childrenReadable ? node(element).children : nil
  }
  func isDialog(_ element: AXUIElement) -> Bool { node(element).dialog }
  func ownedOrLinkedElements(of element: AXUIElement) -> [AXUIElement]? {
    node(element).relationshipsReadable ? node(element).owns + node(element).links : nil
  }
  func role(of element: AXUIElement) -> String? { node(element).role }
  func stringValue(of element: AXUIElement) -> String? { node(element).text }
  func isExplicitlyEditable(_ element: AXUIElement) -> Bool { false }
  func insertionPointLine(of element: AXUIElement) -> Int? { node(element).insertionLine }
  func isWindowElement(_ element: AXUIElement?) -> Bool {
    element.map { node($0).role == kAXWindowRole } ?? false
  }
  func isEditableTextRole(_ role: String?) -> Bool {
    AccessibilityElementReader().isEditableTextRole(role)
  }
  func isSingleLineTextRole(_ role: String?) -> Bool {
    AccessibilityElementReader().isSingleLineTextRole(role)
  }
  func elementRect(for element: AXUIElement) -> CGRect? { node(element).rect }
  func selectedTextRange(for element: AXUIElement) -> CFRange? { node(element).selection }
  func selectedTextMarkerRange(for element: AXUIElement) -> AXTextMarkerRange? {
    guard node(element).markerBounds != nil else { return nil }
    var byte: UInt8 = 0
    let marker = AXTextMarkerCreate(kCFAllocatorDefault, &byte, 1)
    return AXTextMarkerRangeCreate(kCFAllocatorDefault, marker, marker)
  }
  func boundsForRangeValue(_ rangeValue: AXValue, in element: AXUIElement) -> CGRect? {
    var range = CFRange()
    guard AXValueGetValue(rangeValue, .cfRange, &range) else { return nil }
    let key = "\(range.location):\(range.length)"
    requestedRanges.append(key)
    return node(element).bounds[key]
  }
  func stringForRangeValue(_ rangeValue: AXValue, in element: AXUIElement) -> String? { nil }
  func lineNumber(for index: Int, in element: AXUIElement) -> Int? { 1 }
  func rangeForLine(_ line: Int, in element: AXUIElement) -> CFRange? { node(element).lineRange }
  func textMarkerSelectionBounds(
    for selectedTextMarkerRange: AXTextMarkerRange, in element: AXUIElement
  ) -> CGRect? { node(element).markerBounds }
}

private func ownedInputFixture() -> (
  result: AnchorElement, list: AnchorElement, input: AnchorElement, dialog: AnchorElement,
  nodes: [AnchorElement]
) {
  let result = AnchorElement(1)
  result.role = kAXStaticTextRole
  result.rect = CGRect(x: 477, y: 204, width: 552, height: 48)
  result.insertionLine = 0
  result.selection = CFRange(location: 0, length: 0)
  result.markerBounds = .zero
  let list = AnchorElement(2)
  list.role = kAXListRole
  list.rect = CGRect(x: 469, y: 168, width: 574, height: 329)
  list.children = [result.element]
  let dialog = AnchorElement(3)
  dialog.role = kAXGroupRole
  dialog.dialog = true
  dialog.rect = CGRect(x: 468, y: 119, width: 576, height: 420)
  let input = AnchorElement(4)
  input.role = "AXComboBox"
  input.rect = CGRect(x: 478, y: 127, width: 556, height: 34)
  input.owns = [list.element]
  dialog.children = [list.element, input.element]
  result.ancestors = [list.element, dialog.element]
  return (result, list, input, dialog, [result, list, input, dialog])
}
