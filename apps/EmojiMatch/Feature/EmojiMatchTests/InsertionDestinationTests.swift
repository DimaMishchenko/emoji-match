import AppKit
import ApplicationServices
import Testing

@testable import EmojiMatch

@Suite struct InsertionDestinationTests {
  @Test func captureBoundsSelectionAndOptOutNeverReadsText() throws {
    let fixture = DestinationFixture()
    let destination = try #require(fixture.capture())
    #expect(destination.selectedText == "chosen")
    #expect(destination.initialSelectedRange?.length == 6)
    #expect(fixture.textReads == 1)
    #expect(fixture.capture(includeSelectedText: false)?.selectedText == nil)
    fixture.range = CFRange(location: 0, length: 1025)
    #expect(fixture.capture()?.selectedText == nil)
    #expect(fixture.textReads == 1)
  }

  @Test func captureRejectsSecureOrUnsupportedControlWithoutReading() {
    let fixture = DestinationFixture()
    fixture.editable = false
    #expect(fixture.capture() == nil)
    #expect(fixture.textReads == 0)
  }

  @Test func changedOrDestroyedControlAndChangedSelectionInvalidateDelivery() throws {
    let fixture = DestinationFixture()
    let destination = try #require(fixture.capture())
    fixture.range = CFRange(location: 6, length: 1)
    #expect(!destination.isValidForDelivery())
    #expect(!destination.restoreFocus())
    fixture.range = CFRange(location: 2, length: 6)
    #expect(destination.isValidForDelivery())
    fixture.element = AXUIElementCreateSystemWide()
    #expect(!destination.isValidForDelivery())
    fixture.element = nil
    #expect(!destination.isValidForDelivery())
  }

  @Test func lostSelectionExposureAndTerminatedApplicationInvalidateDelivery() throws {
    let fixture = DestinationFixture()
    let destination = try #require(fixture.capture())
    fixture.range = nil
    #expect(!destination.isValidForDelivery())
    fixture.range = CFRange(location: 2, length: 6)
    fixture.alive = false
    #expect(!destination.isValidForDelivery())
    #expect(!destination.restoreFocus())
  }

  @Test func unavailableFrontmostNeverRestoresOrDelivers() throws {
    let fixture = DestinationFixture()
    let destination = try #require(fixture.capture())
    fixture.frontmost = nil
    #expect(!destination.restoreFocus())
    #expect(!destination.isValidForDelivery())
    #expect(fixture.activations == 0)
  }

  @Test func restorationFromOurReceiverOnlyActivatesUnchangedOriginal() throws {
    let fixture = DestinationFixture()
    let original = try #require(
      NSWorkspace.shared.runningApplications.first {
        $0.processIdentifier != NSRunningApplication.current.processIdentifier
      })
    fixture.frontmost = original
    fixture.ownProcessIdentifier = NSRunningApplication.current.processIdentifier
    let destination = try #require(fixture.capture())
    fixture.frontmost = .current
    #expect(destination.restoreFocus())
    #expect(fixture.activations == 1)
    #expect(!destination.isValidForDelivery())
    fixture.frontmost = original
    #expect(destination.isValidForDelivery())
  }

  @Test func externalApplicationSwitchNeverStealsFocus() throws {
    let fixture = DestinationFixture()
    let destination = try #require(fixture.capture())
    let external = try #require(
      NSWorkspace.shared.runningApplications.first {
        $0.processIdentifier != NSRunningApplication.current.processIdentifier
      }
    )
    fixture.frontmost = external
    #expect(!destination.restoreFocus())
    #expect(!destination.isValidForDelivery())
    #expect(fixture.activations == 0)
  }

  @Test func alreadyFrontmostRecipientStillRestoresKeyboardFocus() throws {
    let fixture = DestinationFixture()
    let destination = try #require(fixture.capture())
    #expect(destination.restoreFocus())
    #expect(fixture.activations == 1)
  }

  @Test func switchDuringAccessibilityValidationCancelsActivation() throws {
    let fixture = DestinationFixture()
    let destination = try #require(fixture.capture())
    let external = try #require(
      NSWorkspace.shared.runningApplications.first {
        $0.processIdentifier != NSRunningApplication.current.processIdentifier
      })
    fixture.onFocusedElementRead = { [unowned fixture] in fixture.frontmost = external }
    #expect(!destination.restoreFocus())
    #expect(fixture.activations == 0)
  }

  @Test func switchDuringDeliveryValidationIsRejected() throws {
    let fixture = DestinationFixture()
    let destination = try #require(fixture.capture())
    let external = try #require(
      NSWorkspace.shared.runningApplications.first {
        $0.processIdentifier != NSRunningApplication.current.processIdentifier
      })
    fixture.onFocusedElementRead = { [unowned fixture] in fixture.frontmost = external }
    #expect(!destination.isValidForDelivery())
  }

  @Test func controlSwitchDuringRangeReadIsRejected() throws {
    let fixture = DestinationFixture()
    let destination = try #require(fixture.capture())
    fixture.onRangeRead = { [unowned fixture] in fixture.element = AXUIElementCreateSystemWide() }
    #expect(!destination.isValidForDelivery())
  }
}

private final class DestinationFixture {
  var frontmost: NSRunningApplication? = .current
  var element: AXUIElement? = AXUIElementCreateApplication(
    NSRunningApplication.current.processIdentifier)
  var range: CFRange? = CFRange(location: 2, length: 6)
  var editable = true
  var alive = true
  var textReads = 0
  var activations = 0
  var ownProcessIdentifier: pid_t = -1
  var onFocusedElementRead: (() -> Void)?
  var onRangeRead: (() -> Void)?

  func capture(includeSelectedText: Bool = true) -> InsertionDestination? {
    InsertionDestination.capture(
      includeSelectedText: includeSelectedText,
      dependencies: .init(
        frontmostApplication: { [unowned self] in frontmost },
        focusedElement: { [unowned self] _ in
          onFocusedElementRead?()
          return element
        },
        selectedRange: { [unowned self] _ in
          onRangeRead?()
          return range
        },
        selectedText: { [unowned self] _, _ in
          textReads += 1
          return "chosen"
        },
        isEditable: { [unowned self] _ in editable }, isAlive: { [unowned self] _ in alive },
        activate: { [unowned self] _ in
          activations += 1
          return true
        },
        ownProcessIdentifier: ownProcessIdentifier
      )
    )
  }
}
