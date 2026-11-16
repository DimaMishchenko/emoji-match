import ApplicationServices
import Testing

@testable import AccessibilitySupport

@Suite struct AccessibilityElementReaderTests {
  @Test func partialCollectionsCannotEstablishCompleteChildTraversal() {
    let element = AXUIElementCreateApplication(1)
    var reads = 0
    for partial in [kAXVisibleChildrenAttribute, kAXRowsAttribute, kAXContentsAttribute] {
      let reader = AccessibilityElementReader(
        arrayAccess: .init(
          attributeNames: { _ in [partial] },
          elements: { _, _ in
            reads += 1
            return []
          }))
      #expect(reader.completeChildElements(of: element) == nil)
    }
    #expect(reads == 0)
  }

  @Test func fullChildrenWinOverVisibleSubsetAndReadFailureIsNotEmpty() {
    let element = AXUIElementCreateApplication(1)
    let hiddenOwner = AXUIElementCreateApplication(2)
    var readable = true
    var requested: [String] = []
    let reader = AccessibilityElementReader(
      arrayAccess: .init(
        attributeNames: { _ in [kAXVisibleChildrenAttribute, kAXChildrenAttribute] },
        elements: { _, name in
          requested.append(name)
          return readable ? [hiddenOwner] : nil
        }))
    #expect(reader.completeChildElements(of: element)?.count == 1)
    #expect(requested == [kAXChildrenAttribute])
    readable = false
    #expect(reader.completeChildElements(of: element) == nil)
    let leaf = AccessibilityElementReader(
      arrayAccess: .init(attributeNames: { _ in [] }, elements: { _, _ in nil }))
    #expect(leaf.completeChildElements(of: element)?.isEmpty == true)
    let unreadable = AccessibilityElementReader(
      arrayAccess: .init(attributeNames: { _ in nil }, elements: { _, _ in [] }))
    #expect(unreadable.completeChildElements(of: element) == nil)
  }

  @Test func incompleteRelationshipsAndOversizedArraysFailClosed() {
    let element = AXUIElementCreateApplication(1)
    var linksReadable = true
    var count = 1
    let reader = AccessibilityElementReader(
      arrayAccess: .init(
        attributeNames: { _ in ["AXOwns", "AXLinkedUIElements"] },
        elements: { _, name in
          if name == "AXLinkedUIElements" && !linksReadable { return nil }
          return Array(repeating: element, count: count)
        }))
    #expect(reader.ownedOrLinkedElements(of: element)?.count == 1)
    linksReadable = false
    #expect(reader.ownedOrLinkedElements(of: element) == nil)
    linksReadable = true
    count = 129
    #expect(reader.ownedOrLinkedElements(of: element) == nil)
  }
}
