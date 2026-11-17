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

  @Test func searchFieldRecoversFromWindowFocusWithoutRelaxingDeliveryValidation() throws {
    let fixture = DestinationFixture()
    fixture.range = CFRange(location: 0, length: 0)
    let original = try #require(fixture.element)
    let destination = try #require(fixture.capture())
    fixture.loseFocusToWindow()
    #expect(fixture.capture() == nil)
    #expect(!destination.isValidForDelivery())

    fixture.onFocus = { [unowned fixture] in
      #expect(fixture.activations == 1)
      fixture.element = original
    }
    #expect(destination.restoreFocus())
    let focused = try #require(fixture.focusRequests.first)
    #expect(fixture.focusRequests.count == 1)
    #expect(CFEqual(focused, original))
    #expect(destination.isValidForDelivery())
  }

  @Test func ownedPickerActivatesRecipientBeforeReassertingFieldFocus() throws {
    let fixture = DestinationFixture()
    let recipient = try otherApplication()
    fixture.frontmost = recipient
    fixture.ownProcessIdentifier = NSRunningApplication.current.processIdentifier
    let destination = try #require(fixture.capture())
    fixture.loseFocusToWindow()
    fixture.frontmost = .current
    fixture.onActivate = { [unowned fixture] in fixture.frontmost = recipient }
    fixture.onFocus = { [unowned fixture] in
      #expect(fixture.frontmost?.processIdentifier == recipient.processIdentifier)
    }
    #expect(destination.restoreFocus())
    #expect(fixture.activations == 1)
    #expect(fixture.focusRequests.count == 1)
    #expect(!destination.isValidForDelivery())
  }

  @Test func activationCanRestoreFieldWithoutWritingAXFocus() throws {
    let fixture = DestinationFixture()
    let original = try #require(fixture.element)
    let destination = try #require(fixture.capture())
    fixture.loseFocusToWindow()
    fixture.onActivate = { [unowned fixture] in fixture.element = original }

    #expect(destination.restoreFocus())
    #expect(fixture.activations == 1)
    #expect(fixture.focusRequests.isEmpty)
    #expect(destination.isValidForDelivery())
  }

  @Test func failedAXFocusWriteIsRejected() throws {
    let fixture = DestinationFixture()
    let destination = try #require(fixture.capture())
    fixture.loseFocusToWindow()
    fixture.focusSucceeds = false
    #expect(!destination.restoreFocus())
    #expect(fixture.focusRequests.count == 1)
    #expect(!destination.isValidForDelivery())
  }

  @Test func recoveryRequiresCapturedWindowIdentity() throws {
    let fixture = DestinationFixture()
    fixture.elementWindow = nil
    let destination = try #require(fixture.capture())
    fixture.elementWindow = fixture.window
    fixture.loseFocusToWindow()
    #expect(!destination.restoreFocus())
    #expect(fixture.activations == 0)
    #expect(fixture.focusRequests.isEmpty)
  }

  enum RecoveryVeto: CaseIterable {
    case rawFocusUnavailable, rawFocusElsewhere, semanticField, currentWindowUnavailable
    case currentWindowChanged, elementWindowUnavailable, elementWindowChanged
    case changedSelection, lostSelection, gainedSelection, ineligible, readOnly, terminated
    case externalApplication, foregroundUnavailable
  }

  @Test(arguments: RecoveryVeto.allCases)
  func unsafeWindowFocusNeverActivatesOrReasserts(veto: RecoveryVeto) throws {
    let fixture = DestinationFixture()
    if veto == .gainedSelection { fixture.range = nil }
    let destination = try #require(fixture.capture())
    fixture.loseFocusToWindow()
    switch veto {
    case .rawFocusUnavailable: fixture.rawFocus = nil
    case .rawFocusElsewhere: fixture.rawFocus = fixture.otherElement
    case .semanticField: fixture.element = fixture.otherElement
    case .currentWindowUnavailable: fixture.currentWindow = nil
    case .currentWindowChanged: fixture.currentWindow = fixture.otherElement
    case .elementWindowUnavailable: fixture.elementWindow = nil
    case .elementWindowChanged: fixture.elementWindow = fixture.otherElement
    case .changedSelection: fixture.range = CFRange(location: 3, length: 6)
    case .lostSelection: fixture.range = nil
    case .gainedSelection: fixture.range = CFRange(location: 0, length: 0)
    case .ineligible: fixture.editable = false
    case .readOnly: fixture.writable = false
    case .terminated: fixture.alive = false
    case .externalApplication: fixture.frontmost = try otherApplication()
    case .foregroundUnavailable: fixture.frontmost = nil
    }
    #expect(!destination.restoreFocus())
    #expect(fixture.activations == 0)
    #expect(fixture.focusRequests.isEmpty)
  }

  @Test func unavailableNumericSelectionPreventsRecovery() throws {
    let fixture = DestinationFixture()
    fixture.range = nil
    let destination = try #require(fixture.capture())
    fixture.loseFocusToWindow()
    fixture.onFocus = { [unowned fixture] in
      fixture.element = AXUIElementCreateApplication(NSRunningApplication.current.processIdentifier)
    }
    #expect(!destination.restoreFocus())
    #expect(fixture.focusRequests.isEmpty)
    #expect(!destination.isValidForDelivery())
  }

  @Test func recoveryRechecksWindowAndControlAfterReadingSelection() throws {
    let fixture = DestinationFixture()
    let destination = try #require(fixture.capture())
    fixture.loseFocusToWindow()
    fixture.onRangeRead = { [unowned fixture] in fixture.currentWindow = fixture.otherElement }
    #expect(!destination.restoreFocus())
    fixture.currentWindow = fixture.window
    fixture.onRangeRead = { [unowned fixture] in fixture.element = fixture.otherElement }
    #expect(!destination.restoreFocus())
    #expect(fixture.activations == 0)
    #expect(fixture.focusRequests.isEmpty)
  }

  @Test func recoveryRechecksForegroundAfterReadingWindow() throws {
    let fixture = DestinationFixture()
    let external = try otherApplication()
    let destination = try #require(fixture.capture())
    fixture.loseFocusToWindow()
    fixture.onFocusedWindowRead = { [unowned fixture] in fixture.frontmost = external }
    #expect(!destination.restoreFocus())
    #expect(fixture.activations == 0)
    #expect(fixture.focusRequests.isEmpty)
  }

  enum ActivationChange: CaseIterable {
    case foreground, window, rawFocus, semanticFocus, selection, editability, activationFailed
  }

  @Test(arguments: ActivationChange.allCases)
  func activationChangesVetoAXFocus(change: ActivationChange) throws {
    let fixture = DestinationFixture()
    let external = change == .foreground ? try otherApplication() : nil
    let destination = try #require(fixture.capture())
    fixture.loseFocusToWindow()
    fixture.onActivate = { [unowned fixture] in
      switch change {
      case .foreground:
        fixture.onFocusedWindowRead = { [unowned fixture] in fixture.frontmost = external }
      case .window:
        fixture.onRawFocusRead = { [unowned fixture] in
          fixture.currentWindow = fixture.otherElement
        }
      case .rawFocus:
        fixture.onRangeRead = { [unowned fixture] in fixture.rawFocus = fixture.otherElement }
      case .semanticFocus:
        fixture.onRangeRead = { [unowned fixture] in fixture.element = fixture.otherElement }
      case .selection: fixture.range = CFRange(location: 3, length: 6)
      case .editability: fixture.editable = false
      case .activationFailed: fixture.activationSucceeds = false
      }
    }
    #expect(!destination.restoreFocus())
    #expect(fixture.activations == 1)
    #expect(fixture.focusRequests.isEmpty)
  }

  @Test func recoveryRejectsNewFieldDuringPostActivationWindowRead() throws {
    let fixture = DestinationFixture()
    let destination = try #require(fixture.capture())
    fixture.loseFocusToWindow()
    fixture.onActivate = { [unowned fixture] in
      var reads = 0
      fixture.onFocusedWindowRead = { [unowned fixture] in
        reads += 1
        if reads == 2 {
          fixture.element = fixture.otherElement
          fixture.rawFocus = fixture.otherElement
        }
      }
    }
    #expect(!destination.restoreFocus())
    #expect(fixture.activations == 1)
    #expect(fixture.focusRequests.isEmpty)
  }

  @Test func deliveryRejectsWindowChangeDuringFocusWrite() throws {
    let fixture = DestinationFixture()
    let original = try #require(fixture.element)
    let destination = try #require(fixture.capture())
    fixture.loseFocusToWindow()
    fixture.onFocus = { [unowned fixture] in
      fixture.element = original
      fixture.elementWindow = fixture.otherElement
      fixture.currentWindow = fixture.otherElement
    }
    #expect(destination.restoreFocus())
    #expect(!destination.isValidForDelivery())
  }

  private func otherApplication() throws -> NSRunningApplication {
    try #require(
      NSWorkspace.shared.runningApplications.first {
        $0.processIdentifier != NSRunningApplication.current.processIdentifier
      })
  }
}

private final class DestinationFixture {
  let window = AXUIElementCreateSystemWide()
  let otherElement = AXUIElementCreateApplication(
    NSRunningApplication.current.processIdentifier + 1)
  var frontmost: NSRunningApplication? = .current
  var element: AXUIElement? = AXUIElementCreateApplication(
    NSRunningApplication.current.processIdentifier)
  lazy var currentWindow: AXUIElement? = window
  lazy var elementWindow: AXUIElement? = window
  var rawFocus: AXUIElement?
  var range: CFRange? = CFRange(location: 2, length: 6)
  var editable = true
  var writable = true
  var alive = true
  var textReads = 0
  var activations = 0
  var activationSucceeds = true
  var focusSucceeds = true
  var focusRequests: [AXUIElement] = []
  var ownProcessIdentifier: pid_t = -1
  var onFocusedElementRead: (() -> Void)?
  var onFocusedWindowRead: (() -> Void)?
  var onRawFocusRead: (() -> Void)?
  var onRangeRead: (() -> Void)?
  var onActivate: (() -> Void)?
  var onFocus: (() -> Void)?

  func loseFocusToWindow() {
    element = nil
    rawFocus = window
  }

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
          onActivate?()
          return activationSucceeds
        },
        ownProcessIdentifier: ownProcessIdentifier,
        rawFocusedElement: { [unowned self] _ in
          onRawFocusRead?()
          return rawFocus
        },
        focusedWindow: { [unowned self] _ in
          onFocusedWindowRead?()
          return currentWindow
        },
        elementWindow: { [unowned self] _ in elementWindow },
        hasWritableValue: { [unowned self] _ in writable },
        focus: { [unowned self] element in
          focusRequests.append(element)
          onFocus?()
          return focusSucceeds
        }
      )
    )
  }
}
