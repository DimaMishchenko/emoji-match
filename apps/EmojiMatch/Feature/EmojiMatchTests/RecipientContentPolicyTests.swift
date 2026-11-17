import AppKit
import ApplicationServices
import Testing

@testable import EmojiMatch

@Suite struct RecipientContentPolicyTests {
  @Test func explicitSourceCodeContextIsUnicodeOnlyAcrossApplications() {
    let field = PolicyElement(1, role: kAXTextAreaRole)
    field.attributes["AXTextualContext"] = "AXTextualContextSourceCode" as CFString
    let input = RecipientContentPolicy.inputTraits(for: field.element, attribute: reader([field]))
    for bundle in [nil, "com.apple.dt.Xcode", "test.other.editor"] {
      let assessment = RecipientContentPolicy.assess(bundleIdentifier: bundle, input: input)
      #expect(assessment == .sourceCode)
      #expect(!assessment.allowsRichContent)
    }
  }

  @Test func missingOrDifferentTextualContextDoesNotClaimRichSupportOrRejection() {
    let field = PolicyElement(1, role: kAXTextAreaRole)
    let parent = PolicyElement(2, role: kAXGroupRole)
    field.attributes[kAXParentAttribute] = parent.element
    parent.attributes["AXTextualContext"] = "AXTextualContextSourceCode" as CFString
    for context in [nil, "AXTextualContextWordProcessing", "future-context"] as [String?] {
      field.attributes["AXTextualContext"] = context.map { $0 as CFString }
      let input = RecipientContentPolicy.inputTraits(
        for: field.element, attribute: reader([field, parent]))
      let assessment = RecipientContentPolicy.assess(
        bundleIdentifier: "com.apple.dt.Xcode", input: input)
      #expect(assessment == .unknown)
      #expect(assessment.allowsRichContent)
    }
  }

  @Test func semanticSearchDecisionsSurviveAppAndDOMClassRenaming() {
    let searches: [RecipientContentPolicy.InputTraits] = [
      .init(role: kAXComboBoxRole, isWebContent: true, isInSearchLandmark: true),
      .init(role: kAXTextFieldRole, subrole: "AXSearchField", isWebContent: true),
      .init(role: kAXComboBoxRole, isWebContent: true, ownsDialogResultList: true)
    ]
    for bundle in [nil, "com.spotify.client", "com.t3tools.t3code", "test.other.editor"] {
      for search in searches {
        #expect(
          RecipientContentPolicy.assess(bundleIdentifier: bundle, input: search) == .webSearch)
        #expect(
          !RecipientContentPolicy.assess(bundleIdentifier: bundle, input: search)
            .allowsRichContent)
      }
    }
    let field = PolicyElement(1, role: kAXComboBoxRole)
    let landmark = PolicyElement(2, role: kAXGroupRole)
    field.attributes[kAXParentAttribute] = landmark.element
    landmark.attributes[kAXSubroleAttribute] = "AXLandmarkSearch" as CFString
    for classes in [[], ["old-class"], ["new", "unrelated"]] {
      field.attributes["AXDOMClassList"] = classes as CFArray
      let input = RecipientContentPolicy.inputTraits(
        for: field.element, attribute: reader([field, landmark]))
      #expect(RecipientContentPolicy.assess(bundleIdentifier: nil, input: input) == .webSearch)
    }
  }

  @Test func knownRichRecipientsAndNativeSearchRemainUnknownAndAvailable() {
    let inputs: [RecipientContentPolicy.InputTraits] = [
      .init(role: kAXTextAreaRole),
      .init(role: kAXTextAreaRole, isWebContent: true),
      .init(role: kAXTextFieldRole, subrole: "AXSearchField"),
      .init(role: kAXComboBoxRole),
      .init(role: kAXTextFieldRole, isWebContent: true),
      .init(role: kAXComboBoxRole, isWebContent: true),
      .init(
        role: kAXTextFieldRole, subrole: "AXSearchField", isWebContent: true,
        hasMultilineEditableAncestor: true),
      .init()
    ]
    for bundle in [
      nil, "com.apple.finder", "com.apple.Notes", "com.apple.TextEdit",
      "com.apple.Safari", "com.t3tools.t3code", "com.spotify.client"
    ] {
      for input in inputs {
        let assessment = RecipientContentPolicy.assess(bundleIdentifier: bundle, input: input)
        #expect(assessment == .unknown)
        #expect(assessment.allowsRichContent)
      }
    }
  }

  @Test func terminalExceptionDoesNotClassifyOtherNativeTextAreas() {
    let input = RecipientContentPolicy.InputTraits(role: kAXTextAreaRole)
    #expect(
      RecipientContentPolicy.assess(bundleIdentifier: "com.apple.Terminal", input: input)
        == .terminal)
    #expect(
      !RecipientContentPolicy.assess(bundleIdentifier: "com.apple.Terminal", input: input)
        .allowsRichContent)
    #expect(
      RecipientContentPolicy.assess(bundleIdentifier: "test.editor", input: input) == .unknown)
  }

  @Test func dialogOwnerRequiresListWithinSameNearestDialog() {
    let field = PolicyElement(1, role: kAXComboBoxRole)
    let dialog = PolicyElement(2, role: kAXGroupRole)
    let list = PolicyElement(3, role: kAXListRole)
    let other = PolicyElement(4, role: kAXGroupRole)
    field.attributes["AXDOMClassList"] = [] as CFArray
    field.attributes[kAXParentAttribute] = dialog.element
    dialog.attributes[kAXSubroleAttribute] = "AXApplicationDialog" as CFString
    list.attributes[kAXParentAttribute] = dialog.element
    other.attributes[kAXSubroleAttribute] = "AXApplicationDialog" as CFString
    let read = reader([field, dialog, list, other])
    for relationship in ["AXOwns", "AXLinkedUIElements"] {
      field.attributes[relationship] = [list.element] as CFArray
      let input = RecipientContentPolicy.inputTraits(for: field.element, attribute: read)
      #expect(input.ownsDialogResultList)
      #expect(RecipientContentPolicy.assess(bundleIdentifier: nil, input: input) == .webSearch)
      list.attributes[kAXParentAttribute] = other.element
      let outside = RecipientContentPolicy.inputTraits(for: field.element, attribute: read)
      #expect(!outside.ownsDialogResultList)
      #expect(RecipientContentPolicy.assess(bundleIdentifier: nil, input: outside) == .unknown)
      list.attributes[kAXParentAttribute] = dialog.element
      field.attributes.removeValue(forKey: relationship)
    }
  }

  @Test func incompleteMetadataAndTraversalBoundsPreserveUnknown() {
    let field = PolicyElement(1, role: kAXComboBoxRole)
    let list = PolicyElement(2, role: kAXListRole)
    field.attributes["AXDOMClassList"] = [] as CFArray
    field.attributes["AXOwns"] = Array(repeating: list.element, count: 129) as CFArray
    let nodes = [field, list] + (3...16).map { PolicyElement(pid_t($0), role: kAXGroupRole) }
    for index in 0..<(nodes.count - 1) {
      nodes[index].attributes[kAXParentAttribute] = nodes[index + 1].element
    }
    nodes.last!.attributes[kAXSubroleAttribute] = "AXLandmarkSearch" as CFString
    nodes.last!.attributes[kAXParentAttribute] = field.element
    let input = RecipientContentPolicy.inputTraits(for: field.element, attribute: reader(nodes))
    #expect(!input.isInSearchLandmark)
    #expect(!input.ownsDialogResultList)
    #expect(RecipientContentPolicy.assess(bundleIdentifier: nil, input: input) == .unknown)
    field.attributes[kAXParentAttribute] = field.element
    #expect(
      !RecipientContentPolicy.inputTraits(for: field.element, attribute: reader(nodes))
        .isInSearchLandmark)
  }

  @Test func webAreaAncestryWorksWithoutDOMClassesAndKeepsEditableWrappers() {
    let field = PolicyElement(1, role: kAXTextFieldRole)
    let web = PolicyElement(2, role: "AXWebArea")
    field.attributes[kAXSubroleAttribute] = "AXSearchField" as CFString
    field.attributes[kAXParentAttribute] = web.element
    let read = reader([field, web])
    let input = RecipientContentPolicy.inputTraits(for: field.element, attribute: read)
    #expect(input.isWebContent)
    #expect(RecipientContentPolicy.assess(bundleIdentifier: nil, input: input) == .webSearch)
    web.attributes[kAXRoleAttribute] = kAXTextAreaRole as CFString
    field.attributes["AXDOMClassList"] = [] as CFArray
    let nested = RecipientContentPolicy.inputTraits(for: field.element, attribute: read)
    #expect(nested.hasMultilineEditableAncestor)
    #expect(RecipientContentPolicy.assess(bundleIdentifier: nil, input: nested) == .unknown)
  }
}

private final class PolicyElement {
  let element: AXUIElement
  var attributes: [String: CFTypeRef]

  init(_ identifier: pid_t, role: String) {
    element = AXUIElementCreateApplication(identifier)
    attributes = [kAXRoleAttribute: role as CFString]
  }
}

private func reader(_ nodes: [PolicyElement]) -> (AXUIElement, String) -> CFTypeRef? {
  { element, name in nodes.first { CFEqual($0.element, element) }?.attributes[name] }
}
