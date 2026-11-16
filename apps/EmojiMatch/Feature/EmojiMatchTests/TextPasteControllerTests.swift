import AppKit
import ApplicationServices
import ImageIO
import Testing
import WebKit

@testable import EmojiMatch

@Suite struct TextPasteControllerTests {
  @Test func richMenuPastePerformsExactlyOnceWithoutPIDFallback() throws {
    let harness = PasteHarness()
    defer { harness.board.releaseGlobally() }
    let menu = PasteMenuFixture()
    harness.richPaste = { pid, validate in
      RecipientPasteCommand.perform(for: pid, validate: validate, dependencies: menu.dependencies)
    }
    let (selection, bytes) = try richSelection()
    #expect(harness.session.paste(selection, data: bytes, to: try destination()))
    #expect(menu.presses == 1)
    #expect(harness.events.isEmpty)
    #expect(harness.richPasteCalls == 1)
    #expect(harness.callbacks.count == 1)
    harness.callbacks[0]()
    #expect(harness.board.string(forType: .string) == "original")
  }

  @Test func failedMenuPressNeverRetriesAndRestoresClipboard() throws {
    let harness = PasteHarness()
    defer { harness.board.releaseGlobally() }
    let menu = PasteMenuFixture()
    menu.pressSucceeds = false
    harness.richPaste = { pid, validate in
      RecipientPasteCommand.perform(for: pid, validate: validate, dependencies: menu.dependencies)
    }
    let (selection, bytes) = try richSelection()
    #expect(!harness.session.paste(selection, data: bytes, to: try destination()))
    #expect(menu.presses == 1)
    #expect(harness.events.isEmpty)
    #expect(harness.callbacks.isEmpty)
    #expect(harness.board.string(forType: .string) == "original")
  }

  @Test func unavailableMenuFallsBackToPIDOnce() throws {
    let harness = PasteHarness()
    defer { harness.board.releaseGlobally() }
    let menu = PasteMenuFixture()
    menu.command = "x"
    harness.richPaste = { pid, validate in
      RecipientPasteCommand.perform(for: pid, validate: validate, dependencies: menu.dependencies)
    }
    let (selection, bytes) = try richSelection()
    #expect(harness.session.paste(selection, data: bytes, to: try destination()))
    #expect(menu.presses == 0)
    #expect(harness.events == [NSRunningApplication.current.processIdentifier])
    #expect(harness.richPasteCalls == 1)
    #expect(harness.callbacks.count == 1)
  }

  @Test func focusChangeDuringDiscoveryAbortsMenuAndUnavailableFallback() throws {
    for available in [true, false] {
      let harness = PasteHarness()
      defer { harness.board.releaseGlobally() }
      let menu = PasteMenuFixture()
      menu.command = available ? "v" : "x"
      menu.onDiscovery = { harness.destinationValid = false }
      harness.richPaste = { pid, validate in
        RecipientPasteCommand.perform(for: pid, validate: validate, dependencies: menu.dependencies)
      }
      let (selection, bytes) = try richSelection()
      #expect(!harness.session.paste(selection, data: bytes, to: try destination()))
      #expect(menu.presses == 0)
      #expect(harness.events.isEmpty)
      #expect(harness.callbacks.isEmpty)
      #expect(harness.board.string(forType: .string) == "original")
    }
  }

  @Test func clipboardChangeDuringDiscoveryPreventsEitherPasteAndPreservesCopy() throws {
    let harness = PasteHarness()
    defer { harness.board.releaseGlobally() }
    let menu = PasteMenuFixture()
    menu.onDiscovery = {
      harness.board.clearContents()
      _ = harness.board.setString("intervening copy", forType: .string)
    }
    harness.richPaste = { pid, validate in
      RecipientPasteCommand.perform(for: pid, validate: validate, dependencies: menu.dependencies)
    }
    let (selection, bytes) = try richSelection()
    #expect(!harness.session.paste(selection, data: bytes, to: try destination()))
    #expect(menu.presses == 0)
    #expect(harness.events.isEmpty)
    #expect(harness.board.string(forType: .string) == "intervening copy")
  }

  @Test func plainTextSkipsMenuDiscovery() throws {
    let harness = PasteHarness()
    defer { harness.board.releaseGlobally() }
    harness.richPaste = { _, _ in .failed }
    #expect(harness.session.paste(emoji, to: try destination()))
    #expect(harness.richPasteCalls == 0)
    #expect(harness.events.count == 1)
  }

  @Test func menuRequiresUniqueEnabledPrimaryCommandWithPressAction() {
    for failure in ["duplicate", "disabled", "no action", "modifiers", "wrong role", "too many"] {
      let menu = PasteMenuFixture()
      switch failure {
      case "duplicate": menu.duplicate = true
      case "disabled": menu.enabled = false
      case "no action": menu.hasPress = false
      case "modifiers": menu.modifiers = 1
      case "wrong role": menu.itemRole = kAXMenuRole
      default: menu.oversized = true
      }
      var validations = 0
      #expect(
        RecipientPasteCommand.perform(
          for: 1,
          validate: {
            validations += 1; return true
          }, dependencies: menu.dependencies)
          == .unavailable)
      #expect(menu.presses == 0)
      #expect(validations == 0)
    }
  }

  @Test func menuDoesNotDescendIntoRecentOrNestedSubmenus() {
    let menu = PasteMenuFixture()
    menu.command = "x"
    #expect(
      RecipientPasteCommand.perform(for: 1, validate: { true }, dependencies: menu.dependencies)
        == .unavailable)
    #expect(menu.presses == 0)
    #expect(!menu.childrenRead.contains(5))
  }

  @Test func adaptiveGlyphOffersRichAndPNGRepresentationsForOnePasteAndCopy() throws {
    _ = NSApplication.shared
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("Fixtures/InsertionOriginalAdaptiveGlyph.heic")
    let bytes = try Data(contentsOf: fixture)
    let glyph = NSAdaptiveImageGlyph(imageContent: bytes)
    let selection = EmojiSelection(
      id: "glyph", value: "description must not become text",
      asset: EmojiAssetReference(
        kind: .adaptiveGlyph, identifier: glyph.contentIdentifier, typeIdentifier: "public.heic")
    )
    let harness = PasteHarness()
    defer { harness.board.releaseGlobally() }

    for copying in [false, true] {
      if copying {
        #expect(harness.session.copy(selection, data: bytes))
      } else {
        #expect(harness.session.paste(selection, data: bytes, to: try destination()))
      }
      let item = try #require(harness.board.pasteboardItems?.first)
      #expect(harness.board.pasteboardItems?.count == 1)
      #expect(Set(item.types) == Set([.rtfd, .init("public.heic"), .png]))
      #expect(item.availableType(from: [.rtfd, .png]) == .rtfd)
      #expect(item.availableType(from: [.png]) == .png)
      #expect(item.availableType(from: [.string]) == nil)
      #expect(harness.board.string(forType: .string) == nil)
      #expect(item.data(forType: .init("public.heic")) == bytes)

      let rtfd = try #require(item.data(forType: .rtfd))
      let rich = try NSAttributedString(
        data: rtfd, options: [.documentType: NSAttributedString.DocumentType.rtfd],
        documentAttributes: nil)
      #expect(rich.length == 1)
      let restoredGlyph = try #require(
        rich.attribute(.adaptiveImageGlyph, at: 0, effectiveRange: nil) as? NSAdaptiveImageGlyph)
      #expect(restoredGlyph.contentIdentifier == glyph.contentIdentifier)
      #expect(restoredGlyph.imageContent == bytes)

      let png = try #require(item.data(forType: .png))
      #expect(png.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]))
      let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
      #expect(CGImageSourceGetType(source) as String? == "public.png")
      let fallback = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
      let originalSource = try #require(CGImageSourceCreateWithData(bytes as CFData, nil))
      let original = try #require(CGImageSourceCreateImageAtIndex(originalSource, 0, nil))
      #expect(original.width == 160)
      #expect(original.height == 160)
      #expect(fallback.width == 24)
      #expect(fallback.height == 24)
      let originalPixels = try pixels(of: original)
      #expect(Set(try pixels(of: fallback)).count > 16)
      #expect(Set(originalPixels).count > 16)
      #expect(try Data(contentsOf: fixture) == bytes)
      #expect(harness.events.count == 1)
      #expect(harness.callbacks.count == 1)
    }
    harness.callbacks[0]()
    #expect(harness.board.data(forType: .png) != nil)
    #expect(harness.events.count == 1)
    #expect(harness.callbacks.count == 1)
    #expect(try Data(contentsOf: fixture) == bytes)
  }

  @Test func webImageFallbackHasEmojiSizedIntrinsicDimensions() async throws {
    _ = NSApplication.shared
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("Fixtures/InsertionOriginalAdaptiveGlyph.heic")
    let bytes = try Data(contentsOf: fixture)
    let glyph = NSAdaptiveImageGlyph(imageContent: bytes)
    let selection = EmojiSelection(
      id: "glyph", value: "description",
      asset: EmojiAssetReference(
        kind: .adaptiveGlyph, identifier: glyph.contentIdentifier, typeIdentifier: "public.heic"))
    let harness = PasteHarness()
    defer { harness.board.releaseGlobally() }
    #expect(harness.session.copy(selection, data: bytes))
    let png = try #require(harness.board.data(forType: .png))
    let source = try #require(CGImageSourceCreateWithData(bytes as CFData, nil))
    let original = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let highResolutionPNG = NSMutableData()
    let destination = try #require(
      CGImageDestinationCreateWithData(highResolutionPNG, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(
      destination, original,
      [kCGImagePropertyDPIWidth: 480, kCGImagePropertyDPIHeight: 480] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    let webView = WKWebView(frame: .init(x: 0, y: 0, width: 300, height: 100))
    defer { webView.stopLoading() }
    let result = try await webView.callAsyncJavaScript(
      """
      document.body.innerHTML = '<div contenteditable style="font:28px system-ui"></div>';
      const dimensions = [];
      for (const url of urls) {
        const image = new Image();
        image.src = url;
        await image.decode();
        document.querySelector('div').append(image);
        const bounds = image.getBoundingClientRect();
        dimensions.push([image.naturalWidth, image.naturalHeight, bounds.width, bounds.height]);
      }
      return dimensions;
      """,
      arguments: [
        "urls": [png, highResolutionPNG as Data]
          .map {
            "data:image/png;base64," + $0.base64EncodedString()
          }
      ],
      in: nil, contentWorld: .page)
    let dimensions = try #require(result as? [[Int]])
    #expect(dimensions == [[24, 24, 24, 24], [160, 160, 160, 160]])
  }

  @Test func nativeControlsNegotiateAdaptiveGlyphOrImageAttachment() throws {
    _ = NSApplication.shared
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("Fixtures/InsertionOriginalAdaptiveGlyph.heic")
    let bytes = try Data(contentsOf: fixture)
    let glyph = NSAdaptiveImageGlyph(imageContent: bytes)
    let selection = EmojiSelection(
      id: "glyph", value: "description",
      asset: EmojiAssetReference(
        kind: .adaptiveGlyph, identifier: glyph.contentIdentifier, typeIdentifier: "public.heic"))
    let harness = PasteHarness()
    defer { harness.board.releaseGlobally() }
    #expect(harness.session.copy(selection, data: bytes))

    let rich = NSTextView(frame: .init(x: 0, y: 0, width: 300, height: 100))
    rich.isRichText = true
    rich.importsGraphics = true
    #expect(rich.readSelection(from: harness.board))
    #expect(rich.string.utf16.count == 1)
    let restored = try #require(
      rich.textStorage?.attribute(.adaptiveImageGlyph, at: 0, effectiveRange: nil)
        as? NSAdaptiveImageGlyph)
    #expect(restored.contentIdentifier == glyph.contentIdentifier)
    #expect(restored.imageContent == bytes)

    let imageOnly = PNGOnlyTextView(frame: rich.frame)
    imageOnly.isRichText = true
    imageOnly.importsGraphics = true
    #expect(!imageOnly.supportsAdaptiveImageGlyph)
    #expect(imageOnly.readSelection(from: harness.board))
    #expect(imageOnly.string.utf16.count == 1)
    #expect(
      imageOnly.textStorage?.attribute(.adaptiveImageGlyph, at: 0, effectiveRange: nil) == nil)
    #expect(
      imageOnly.textStorage?.attribute(.attachment, at: 0, effectiveRange: nil)
        is NSTextAttachment)
    #expect(harness.events.isEmpty)
  }

  @Test func invalidAdaptiveGlyphAssetsNeverMutateClipboard() throws {
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("Fixtures/InsertionOriginalAdaptiveGlyph.heic")
    let bytes = try Data(contentsOf: fixture)
    let identifier = NSAdaptiveImageGlyph(imageContent: bytes).contentIdentifier
    for (data, assetIdentifier, type) in [
      (Data?.none, identifier, "public.heic"),
      (Data([1, 2, 3]), identifier, "public.heic"),
      (bytes, "wrong identifier", "public.heic"),
      (bytes, identifier, "public.png")
    ] {
      let harness = PasteHarness()
      defer { harness.board.releaseGlobally() }
      let selection = EmojiSelection(
        id: "invalid", value: "description",
        asset: EmojiAssetReference(
          kind: .adaptiveGlyph, identifier: assetIdentifier, typeIdentifier: type))
      let count = harness.board.changeCount
      #expect(!harness.session.copy(selection, data: data))
      #expect(!harness.session.paste(selection, data: data, to: try destination()))
      #expect(harness.board.changeCount == count)
      #expect(harness.board.string(forType: .string) == "original")
      #expect(harness.events.isEmpty)
      #expect(harness.callbacks.isEmpty)
      #expect(harness.validationCalls == 0)
    }
  }

  @Test func interveningCopySurvivesDelayedRestore() throws {
    let harness = PasteHarness()
    defer { harness.board.releaseGlobally() }
    #expect(harness.session.paste(emoji, to: try destination()))
    harness.board.clearContents()
    #expect(harness.board.setString("new user copy", forType: .string))
    harness.callbacks[0]()
    #expect(harness.board.string(forType: .string) == "new user copy")
  }

  @Test func overlappingPastesRestoreOriginalAndIgnoreStaleCallbacks() throws {
    let harness = PasteHarness()
    defer { harness.board.releaseGlobally() }
    #expect(harness.session.paste(emoji, to: try destination()))
    #expect(harness.session.paste(EmojiSelection(id: "b", value: "second"), to: try destination()))
    harness.callbacks[0]()
    #expect(harness.board.string(forType: .string) == "second")
    harness.callbacks[1]()
    #expect(harness.board.string(forType: .string) == "original")
    #expect(harness.events.count == 2)
    #expect(harness.events.allSatisfy { $0 == NSRunningApplication.current.processIdentifier })
  }

  @Test func deliberateCopyCancelsPasteRestoration() throws {
    let harness = PasteHarness()
    defer { harness.board.releaseGlobally() }
    #expect(harness.session.paste(emoji, to: try destination()))
    #expect(harness.session.copy(EmojiSelection(id: "copy", value: "keep")))
    harness.callbacks[0]()
    #expect(harness.board.string(forType: .string) == "keep")
    #expect(harness.events.count == 1)
  }

  @Test func externalCopyBetweenPastesBecomesNewRestorationSnapshot() throws {
    let harness = PasteHarness()
    defer { harness.board.releaseGlobally() }
    #expect(harness.session.paste(emoji, to: try destination()))
    harness.board.clearContents()
    #expect(harness.board.setString("external", forType: .string))
    #expect(harness.session.paste(emoji, to: try destination()))
    harness.callbacks[1]()
    harness.callbacks[0]()
    #expect(harness.board.string(forType: .string) == "external")
  }

  @Test func writeAndEventFailuresRestoreOriginalWithoutScheduling() throws {
    for failure in ["write", "event"] {
      let harness = PasteHarness()
      defer { harness.board.releaseGlobally() }
      harness.failNextWrite = failure == "write"
      harness.postSucceeds = failure != "event"
      #expect(!harness.session.paste(emoji, to: try destination()))
      #expect(harness.board.string(forType: .string) == "original")
      #expect(harness.callbacks.isEmpty)
      #expect(harness.events.isEmpty)
    }
  }

  @Test func staleDestinationAfterWriteRollsBackWithoutPosting() throws {
    let harness = PasteHarness()
    defer { harness.board.releaseGlobally() }
    harness.failValidationOnCall = 2
    #expect(!harness.session.paste(emoji, to: try destination()))
    #expect(harness.board.string(forType: .string) == "original")
    #expect(harness.events.isEmpty)
  }

  @Test func restorationWriteFailureIsReported() throws {
    let harness = PasteHarness()
    defer { harness.board.releaseGlobally() }
    #expect(harness.session.paste(emoji, to: try destination()))
    harness.failNextWrite = true
    harness.callbacks[0]()
    #expect(harness.session.restorationFailed)
  }

  @Test func deniedFocusDoesNotTouchClipboard() throws {
    let harness = PasteHarness()
    defer { harness.board.releaseGlobally() }
    harness.restoreAllowed = false
    let count = harness.board.changeCount
    #expect(!harness.session.paste(emoji, to: try destination()))
    #expect(harness.board.changeCount == count)
    #expect(harness.events.isEmpty)
  }

  @Test func missingRichBytesDoesNotFlattenOrTouchClipboard() {
    let harness = PasteHarness()
    defer { harness.board.releaseGlobally() }
    let count = harness.board.changeCount
    let selection = EmojiSelection(
      id: "rich", value: "description",
      asset: EmojiAssetReference(kind: .image, identifier: "image", typeIdentifier: "public.png")
    )
    #expect(!harness.session.copy(selection))
    #expect(harness.board.changeCount == count)
  }

  @Test func restorePreservesMultipleItemsAndRepresentations() throws {
    let harness = PasteHarness()
    defer { harness.board.releaseGlobally() }
    let first = NSPasteboardItem()
    #expect(first.setString("first", forType: .string))
    let custom = NSPasteboard.PasteboardType("com.example.original")
    #expect(first.setData(Data([0, 1, 2]), forType: custom))
    let second = NSPasteboardItem()
    #expect(second.setString("second", forType: .string))
    harness.board.clearContents()
    #expect(harness.board.writeObjects([first, second]))
    #expect(harness.session.paste(emoji, to: try destination()))
    harness.callbacks[0]()
    #expect(harness.board.pasteboardItems?.count == 2)
    #expect(harness.board.pasteboardItems?.first?.data(forType: custom) == Data([0, 1, 2]))
    #expect(harness.board.pasteboardItems?.last?.string(forType: .string) == "second")
  }

  @Test func failedOverlappingPasteRestoresOriginalAndInvalidatesOlderCallback() throws {
    let harness = PasteHarness()
    defer { harness.board.releaseGlobally() }
    #expect(harness.session.paste(emoji, to: try destination()))
    harness.postSucceeds = false
    #expect(!harness.session.paste(emoji, to: try destination()))
    #expect(harness.board.string(forType: .string) == "original")
    harness.board.clearContents()
    #expect(harness.board.setString("later", forType: .string))
    harness.callbacks[0]()
    #expect(harness.board.string(forType: .string) == "later")
  }
}

private let emoji = EmojiSelection(id: "smile", value: "😀")

private func pixels(of image: CGImage) throws -> Data {
  let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
  var data = Data(count: image.width * image.height * 4)
  try data.withUnsafeMutableBytes { buffer in
    let context = try #require(
      CGContext(
        data: buffer.baseAddress, width: image.width, height: image.height,
        bitsPerComponent: 8, bytesPerRow: image.width * 4, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          | CGBitmapInfo.byteOrder32Big.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
  }
  return data
}

private func destination() throws -> InsertionDestination {
  let element = AXUIElementCreateApplication(NSRunningApplication.current.processIdentifier)
  let dependencies = InsertionDestination.Dependencies(
    frontmostApplication: { .current }, focusedElement: { _ in element },
    selectedRange: { _ in CFRange(location: 0, length: 0) }, selectedText: { _, _ in nil },
    isEditable: { _ in true }, isAlive: { _ in true }, activate: { _ in true },
    ownProcessIdentifier: -1
  )
  return try #require(InsertionDestination.capture(dependencies: dependencies))
}

private final class PasteHarness {
  let board = NSPasteboard.withUniqueName()
  var callbacks: [@MainActor () -> Void] = []
  var events: [pid_t] = []
  var failNextWrite = false
  var postSucceeds = true
  var restoreAllowed = true
  var failValidationOnCall: Int?
  var validationCalls = 0
  var destinationValid = true
  var richPasteCalls = 0
  var richPaste: (pid_t, () -> Bool) -> RecipientPasteCommand.Result = { _, _ in .unavailable }
  lazy var session = TextPasteController.Session(
    dependencies: .init(
      pasteboard: board,
      write: { [unowned self] board, items in
        if failNextWrite {
          failNextWrite = false
          return false
        }
        return board.writeObjects(items)
      },
      postPaste: { [unowned self] pid in
        guard postSucceeds else { return false }
        events.append(pid)
        return true
      },
      schedule: { [unowned self] _, callback in callbacks.append(callback) },
      restoreFocus: { [unowned self] _ in restoreAllowed },
      validate: { [unowned self] _ in
        validationCalls += 1
        return destinationValid && validationCalls != failValidationOnCall
      },
      postRichPaste: { [unowned self] pid, validate in
        richPasteCalls += 1
        return richPaste(pid, validate)
      }
    )
  )

  init() {
    board.clearContents()
    _ = board.setString("original", forType: .string)
  }
}

private final class PNGOnlyTextView: NSTextView {
  override var supportsAdaptiveImageGlyph: Bool { false }
  override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.png] }
}

private func richSelection() throws -> (EmojiSelection, Data) {
  let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Fixtures/InsertionOriginalAdaptiveGlyph.heic")
  let bytes = try Data(contentsOf: fixture)
  let glyph = NSAdaptiveImageGlyph(imageContent: bytes)
  return (
    EmojiSelection(
      id: "glyph", value: "description",
      asset: EmojiAssetReference(
        kind: .adaptiveGlyph, identifier: glyph.contentIdentifier, typeIdentifier: "public.heic")),
    bytes
  )
}

private final class PasteMenuFixture {
  var command = "v"
  var modifiers = 0
  var enabled = true
  var hasPress = true
  var itemRole = kAXMenuItemRole
  var duplicate = false
  var oversized = false
  var pressSucceeds = true
  var presses = 0
  var childrenRead: [pid_t] = []
  var onDiscovery: () -> Void = {}

  var dependencies: RecipientPasteCommand.Dependencies {
    .init(
      application: { _ in AXUIElementCreateApplication(1) },
      attribute: { [unowned self] element, name in
        let id = identifier(element)
        if id == 1 && name == kAXMenuBarAttribute { return AXUIElementCreateApplication(2) }
        if name == kAXRoleAttribute {
          return (id == 4 ? kAXMenuRole : itemRole) as CFString
        }
        if name == kAXMenuItemCmdCharAttribute { return command as CFString }
        if name == kAXMenuItemCmdModifiersAttribute { return modifiers as CFNumber }
        if name == kAXEnabledAttribute { return enabled as CFBoolean }
        return nil
      },
      children: { [unowned self] element, limit in
        let id = identifier(element)
        childrenRead.append(id)
        let ids: [pid_t]
        switch id {
        case 2: ids = [3]
        case 3: ids = [4]
        case 4:
          onDiscovery()
          ids = oversized ? Array(repeating: 5, count: 257) : (duplicate ? [5, 6] : [5])
        case 5: ids = [7]
        case 7: ids = [8]
        default: ids = []
        }
        return ids.count <= limit ? ids.map { AXUIElementCreateApplication($0) } : nil
      },
      supportsPress: { [unowned self] _ in hasPress },
      press: { [unowned self] _ in
        presses += 1
        return pressSucceeds
      }
    )
  }

  private func identifier(_ element: AXUIElement) -> pid_t {
    var id: pid_t = 0
    AXUIElementGetPid(element, &id)
    return id
  }
}
