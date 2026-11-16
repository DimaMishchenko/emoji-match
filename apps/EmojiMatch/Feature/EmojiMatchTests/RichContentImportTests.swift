import AppKit
import ImageIO
import Testing

@testable import EmojiMatch

@Suite struct RichContentImportTests {
  @Test func realGlyphCopyAndRTFDImportPreserveOriginalBytesAndIdentity() throws {
    _ = NSApplication.shared
    let data = try glyphFixture()
    let glyph = NSAdaptiveImageGlyph(imageContent: data)
    let selection = EmojiSelection(
      id: "fixture", value: glyph.contentDescription,
      asset: EmojiAssetReference(
        kind: .adaptiveGlyph, identifier: glyph.contentIdentifier,
        typeIdentifier: NSAdaptiveImageGlyph.contentType.identifier
      )
    )
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    let session = copySession(board)
    #expect(session.copy(selection, data: data))
    #expect(board.string(forType: .string) == nil)
    #expect(board.data(forType: .init(NSAdaptiveImageGlyph.contentType.identifier)) == data)
    #expect(board.data(forType: .rtfd) != nil)
    let imported = try RichContentImport.read(from: board)
    #expect(imported.count == 1)
    guard case .adaptiveGlyph(let roundtrip) = try #require(imported.first) else {
      Issue.record("Expected an adaptive glyph")
      return
    }
    #expect(roundtrip.imageContent == data)
    #expect(roundtrip.contentIdentifier == glyph.contentIdentifier)
    #expect(roundtrip.contentDescription == glyph.contentDescription)
  }

  @Test func richImportExtractsGlyphOnlyAndDeduplicatesRepeatedRunsAndItems() throws {
    _ = NSApplication.shared
    let glyph = NSAdaptiveImageGlyph(imageContent: try glyphFixture())
    let attributed = NSMutableAttributedString(string: "surrounding text ")
    attributed.append(NSAttributedString(adaptiveImageGlyph: glyph, attributes: [:]))
    attributed.append(NSAttributedString(string: " more text "))
    attributed.append(NSAttributedString(adaptiveImageGlyph: glyph, attributes: [:]))
    let rtfd = try attributed.data(
      from: NSRange(location: 0, length: attributed.length),
      documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
    )
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    let items = (0..<2)
      .map { _ in
        let item = NSPasteboardItem()
        #expect(item.setData(rtfd, forType: .rtfd))
        #expect(item.setString("surrounding text", forType: .string))
        return item
      }
    #expect(board.writeObjects(items))
    let imported = try RichContentImport.read(from: board)
    #expect(imported.count == 1)
    guard case .adaptiveGlyph(let result) = try #require(imported.first) else {
      Issue.record("Expected only the glyph")
      return
    }
    #expect(result.imageContent == glyph.imageContent)
  }

  @Test func distinctGlyphsKeepTheirOrder() throws {
    _ = NSApplication.shared
    let firstData = try glyphFixture()
    let secondURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("Fixtures/InsertionSecondAdaptiveGlyph.heic")
    let secondData = try Data(contentsOf: secondURL)
    let attributed = NSMutableAttributedString(string: "")
    for data in [firstData, secondData] {
      attributed.append(
        NSAttributedString(
          adaptiveImageGlyph: NSAdaptiveImageGlyph(imageContent: data), attributes: [:]
        ))
    }
    let rtfd = try attributed.data(
      from: NSRange(location: 0, length: attributed.length),
      documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
    )
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    #expect(board.setData(rtfd, forType: .rtfd))
    let imported = try RichContentImport.read(from: board)
    #expect(imported.count == 2)
    let bytes = imported.compactMap { content -> Data? in
      if case .adaptiveGlyph(let glyph) = content { return glyph.imageContent }
      return nil
    }
    #expect(bytes == [firstData, secondData])
  }

  @Test func gifCopyAndImportKeepOriginalRepresentationAndDeduplicateItems() throws {
    let data = try #require(
      Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"))
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    let selection = EmojiSelection(
      id: "gif", value: "description",
      asset: EmojiAssetReference(
        kind: .image, identifier: "gif", typeIdentifier: "com.compuserve.gif")
    )
    #expect(copySession(board).copy(selection, data: data))
    #expect(board.string(forType: .string) == nil)
    #expect(board.data(forType: .init("com.compuserve.gif")) == data)
    let first = NSPasteboardItem()
    let second = NSPasteboardItem()
    #expect(first.setData(data, forType: .init("com.compuserve.gif")))
    #expect(second.setData(data, forType: .init("com.compuserve.gif")))
    board.clearContents()
    #expect(board.writeObjects([first, second]))
    let imported = try RichContentImport.read(from: board)
    #expect(imported.count == 1)
    guard case .image(let actual, let type, _) = try #require(imported.first) else {
      Issue.record("Expected original GIF representation")
      return
    }
    #expect(actual == data)
    #expect(type == "com.compuserve.gif")
  }

  @Test func animatedGIFIsPreferredOverAdvertisedTIFFWithoutReencoding() throws {
    let singleFrame = try #require(
      Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"))
    let source = try #require(CGImageSourceCreateWithData(singleFrame as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let encoded = NSMutableData()
    let encoder = try #require(
      CGImageDestinationCreateWithData(
        encoded, "com.compuserve.gif" as CFString, 2, nil
      ))
    let frameOptions = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]]
    CGImageDestinationAddImage(encoder, image, frameOptions as CFDictionary)
    CGImageDestinationAddImage(encoder, image, frameOptions as CFDictionary)
    #expect(CGImageDestinationFinalize(encoder))
    let animated = encoded as Data
    let animatedSource = try #require(CGImageSourceCreateWithData(animated as CFData, nil))
    #expect(CGImageSourceGetCount(animatedSource) == 2)
    let tiff = try #require(NSBitmapImageRep(cgImage: image).tiffRepresentation)
    let item = NSPasteboardItem()
    #expect(item.setData(tiff, forType: .tiff))
    #expect(item.setData(animated, forType: .init("com.compuserve.gif")))
    #expect(item.types.first == .tiff)
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    #expect(board.writeObjects([item]))
    let imported = try RichContentImport.read(from: board)
    #expect(imported.count == 1)
    guard case .image(let result, let identifier, _) = try #require(imported.first) else {
      Issue.record("Expected animated GIF")
      return
    }
    #expect(identifier == "com.compuserve.gif")
    #expect(result == animated)
    let restored = try #require(CGImageSourceCreateWithData(result as CFData, nil))
    #expect(CGImageSourceGetCount(restored) == 2)

    let rich = NSMutableAttributedString(
      attachment: NSTextAttachment(data: tiff, ofType: "public.tiff"))
    let context = try #require(
      CGContext(
        data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
    let separateImage = try #require(context.makeImage())
    let separateBytes = try #require(
      NSBitmapImageRep(cgImage: separateImage).representation(using: .png, properties: [:]))
    rich.append(
      NSAttributedString(
        attachment: NSTextAttachment(data: separateBytes, ofType: "public.png")))
    let glyph = NSAdaptiveImageGlyph(imageContent: try glyphFixture())
    rich.append(NSAttributedString(adaptiveImageGlyph: glyph, attributes: [:]))
    let richBytes = try rich.data(
      from: NSRange(location: 0, length: rich.length),
      documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
    let richItem = NSPasteboardItem()
    richItem.setData(richBytes, forType: .rtfd)
    richItem.setData(animated, forType: .init("com.compuserve.gif"))
    board.clearContents()
    board.writeObjects([richItem])
    let richImported = try RichContentImport.read(from: board)
    #expect(richImported.count == 3)
    guard case .image(let richResult, let richIdentifier, _) = richImported.first else {
      Issue.record("Expected animated image before glyph"); return
    }
    #expect(richResult == animated)
    #expect(richIdentifier == "com.compuserve.gif")
    guard case .image(let separateResult, let separateType, _) = richImported[1] else {
      Issue.record("Expected separate PNG attachment"); return
    }
    #expect(separateResult == separateBytes)
    #expect(separateType == "public.png")
    guard case .adaptiveGlyph(let preservedGlyph) = richImported.last else {
      Issue.record("Expected preserved adaptive glyph"); return
    }
    #expect(preservedGlyph.imageContent == glyph.imageContent)
  }

  @Test func rtfdImportRetainsOrdinaryAttachmentAlongsideGlyphWithoutDocumentText() throws {
    _ = NSApplication.shared
    let image = try #require(
      Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"))
    let attachment = NSTextAttachment(data: image, ofType: "com.compuserve.gif")
    let attributed = NSMutableAttributedString(string: "surrounding text")
    attributed.append(NSAttributedString(attachment: attachment))
    let glyph = NSAdaptiveImageGlyph(imageContent: try glyphFixture())
    attributed.append(NSAttributedString(adaptiveImageGlyph: glyph, attributes: [:]))
    let bytes = try attributed.data(
      from: NSRange(location: 0, length: attributed.length),
      documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    board.setData(bytes, forType: .rtfd)
    let imported = try RichContentImport.read(from: board)
    #expect(imported.count == 2)
    guard case .image(let restored, let type, _) = imported.first else {
      Issue.record("Expected image attachment first"); return
    }
    #expect(restored == image)
    #expect(type == "com.compuserve.gif")
    guard case .adaptiveGlyph(let restoredGlyph) = imported.last else {
      Issue.record("Expected adaptive glyph second"); return
    }
    #expect(restoredGlyph.imageContent == glyph.imageContent)
  }

  @Test func unsupportedPlainTextAndTextOnlyRichDocumentsAreRejected() throws {
    _ = NSApplication.shared
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    #expect(board.setString("plain text", forType: .string))
    #expect(throws: RichContentImport.ImportError.unsupportedContent) {
      try RichContentImport.read(from: board)
    }
    for (type, documentType) in [
      (NSPasteboard.PasteboardType.rtf, NSAttributedString.DocumentType.rtf),
      (.rtfd, .rtfd)
    ] {
      let text = NSAttributedString(string: "document text")
      let data = try text.data(
        from: NSRange(location: 0, length: text.length),
        documentAttributes: [.documentType: documentType]
      )
      board.clearContents()
      #expect(board.setData(data, forType: type))
      #expect(throws: RichContentImport.ImportError.unsupportedContent) {
        try RichContentImport.read(from: board)
      }
    }
  }

  @Test func malformedImagesAreRejectedAndCannotReplaceClipboard() throws {
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    #expect(board.setData(Data([1, 2, 3]), forType: .png))
    #expect(throws: RichContentImport.ImportError.invalidContent) {
      try RichContentImport.read(from: board)
    }
    board.clearContents()
    #expect(board.setString("keep", forType: .string))
    let invalid = EmojiSelection(
      id: "bad", value: "description",
      asset: EmojiAssetReference(kind: .image, identifier: "bad", typeIdentifier: "public.png")
    )
    #expect(!copySession(board).copy(invalid, data: Data([1, 2, 3])))
    #expect(board.string(forType: .string) == "keep")
  }
}

private func glyphFixture() throws -> Data {
  let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Fixtures/InsertionOriginalAdaptiveGlyph.heic")
  return try Data(contentsOf: url)
}

private func copySession(_ board: NSPasteboard) -> TextPasteController.Session {
  TextPasteController.Session(
    dependencies: .init(
      pasteboard: board, write: { $0.writeObjects($1) },
      postPaste: { _ in
        Issue.record("Copy must not post events")
        return false
      },
      schedule: { _, _ in Issue.record("Copy must not schedule restoration") },
      restoreFocus: { _ in
        Issue.record("Copy must not restore focus")
        return false
      },
      validate: { _ in false }
    )
  )
}
