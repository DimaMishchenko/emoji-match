import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import EmojiMatch

@Suite struct InlineStickerImageTests {
  @Test(arguments: [UTType.png.identifier, UTType.jpeg.identifier])
  func rectangularStaticImagesProduceDecodableHEICWithIdentityAndTransparentPadding(
    typeIdentifier: String
  ) throws {
    for (width, height) in [(160, 80), (80, 160)] {
      let data = try encodedImage(width: width, height: height, typeIdentifier: typeIdentifier)
      let identifier = InlineStickerImage.stableIdentifier(for: data)
      let description = "Rectangle sticker 🟠 \(width)×\(height)"
      let glyph = try #require(
        try InlineStickerImage.convert(data, identifier: identifier, description: description))
      #expect(glyph.contentIdentifier == identifier)
      #expect(glyph.contentDescription == description)
      #expect(glyph.imageContent != data)
      let source = try #require(CGImageSourceCreateWithData(glyph.imageContent as CFData, nil))
      #expect(CGImageSourceGetType(source) as String? == UTType.heic.identifier)
      #expect(CGImageSourceGetCount(source) == 1)
      let properties = try #require(
        CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?)
      let tiff = try #require(properties[kCGImagePropertyTIFFDictionary] as? NSDictionary)
      #expect(tiff[kCGImagePropertyTIFFDocumentName] as? String == identifier)
      #expect(tiff[kCGImagePropertyTIFFImageDescription] as? String == description)
      let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
      #expect(image.width == 160)
      #expect(image.height == 160)
      let pixels = try rgbaPixels(image)
      for y in stride(from: 8, to: 152, by: 8) {
        for x in stride(from: 8, to: 152, by: 8) {
          let acrossShortAxis = width > height ? y : x
          let offset = (y * image.width + x) * 4
          if acrossShortAxis < 32 || acrossShortAxis > 128 {
            #expect(pixels[offset + 3] < 10)
          } else if acrossShortAxis > 48 && acrossShortAxis < 112 {
            #expect(pixels[offset + 3] > 245)
            #expect(pixels[offset] > 180)
            #expect(pixels[offset + 1] < 80)
            #expect(pixels[offset + 2] < 80)
          }
        }
      }
    }
  }

  @Test func transparentSourcePixelsRemainTransparentInsideSquareCanvas() throws {
    let data = try encodedImage(width: 160, height: 80, transparentCenter: true)
    let glyph = try #require(
      try InlineStickerImage.convert(
        data, identifier: "transparent", description: "Transparent center")
    )
    let image = try decodedImage(glyph.imageContent)
    let pixels = try rgbaPixels(image)
    for y in stride(from: 64, to: 96, by: 8) {
      for x in stride(from: 64, to: 96, by: 8) {
        #expect(pixels[(y * image.width + x) * 4 + 3] < 10)
      }
    }
    #expect(pixels[(80 * image.width + 16) * 4 + 3] > 245)
    #expect(pixels[(16 * image.width + 80) * 4 + 3] < 10)
  }

  @Test func oversizedRectanglesFitWithin512PixelsWithoutChangingAspectRatio() throws {
    for (width, height) in [(2048, 1024), (1024, 2048)] {
      let data = try encodedImage(width: width, height: height)
      let glyph = try #require(
        try InlineStickerImage.convert(data, identifier: "large", description: "Large rectangle"))
      let image = try decodedImage(glyph.imageContent)
      #expect(image.width == 512)
      #expect(image.height == 512)
      let pixels = try rgbaPixels(image)
      for shortAxis in [32, 96, 160, 224, 288, 352, 416, 480] {
        let x = width > height ? 256 : shortAxis
        let y = width > height ? shortAxis : 256
        let alpha = pixels[(y * image.width + x) * 4 + 3]
        #expect(shortAxis > 128 && shortAxis < 384 ? alpha > 245 : alpha < 10)
      }
    }
  }

  @Test func stableIdentifiersRepeatForIdenticalBytesAndChangeWithContent() throws {
    let first = try encodedImage(width: 64, height: 32)
    let second = try encodedImage(width: 64, height: 32, transparentCenter: true)
    #expect(first != second)
    let identifier = InlineStickerImage.stableIdentifier(for: first)
    #expect(InlineStickerImage.stableIdentifier(for: Data(first)) == identifier)
    #expect(InlineStickerImage.stableIdentifier(for: second) != identifier)
    #expect(UUID(uuidString: identifier) != nil)
  }

  @Test func exifRotationTurnsAWideJPEGIntoTallContentWithoutStretching() throws {
    let data = try encodedImage(
      width: 160, height: 80, typeIdentifier: UTType.jpeg.identifier, orientation: 6)
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let properties = try #require(
      CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?)
    #expect((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue == 6)
    let glyph = try #require(
      try InlineStickerImage.convert(data, identifier: "rotated", description: "Rotated rectangle"))
    let image = try decodedImage(glyph.imageContent)
    #expect(image.width == 160)
    #expect(image.height == 160)
    let pixels = try rgbaPixels(image)
    for y in [16, 80, 144] {
      for x in [8, 24, 64, 80, 96, 136, 152] {
        let alpha = pixels[(y * image.width + x) * 4 + 3]
        #expect(x > 40 && x < 120 ? alpha > 245 : alpha < 10)
      }
    }
  }

  @Test func partialAlphaSurvivesHEICAlongsideTransparentPadding() throws {
    let data = try encodedImage(width: 160, height: 80, alpha: 0.5)
    let glyph = try #require(
      try InlineStickerImage.convert(data, identifier: "partial-alpha", description: "Half opacity")
    )
    let image = try decodedImage(glyph.imageContent)
    let pixels = try rgbaPixels(image)
    for y in [64, 80, 96] {
      for x in [32, 80, 128] {
        let alpha = pixels[(y * image.width + x) * 4 + 3]
        #expect(alpha > 100 && alpha < 155)
      }
    }
    #expect(pixels[(16 * image.width + 80) * 4 + 3] < 10)
  }

  @Test func generatedHEICSurvivesRTFDAndNativeTextViewImportExactly() throws {
    _ = NSApplication.shared
    let data = try encodedImage(width: 144, height: 72)
    let glyph = try #require(
      try InlineStickerImage.convert(
        data, identifier: InlineStickerImage.stableIdentifier(for: data),
        description: "Generated sticker 🟠"))
    let attributed = NSAttributedString(adaptiveImageGlyph: glyph, attributes: [:])
    let rtfd = try attributed.data(
      from: NSRange(location: 0, length: attributed.length),
      documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
    let restored = try NSAttributedString(
      data: rtfd, options: [.documentType: NSAttributedString.DocumentType.rtfd],
      documentAttributes: nil)
    try expectExactGlyph(in: restored, matching: glyph)

    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    #expect(board.setData(rtfd, forType: .rtfd))
    let textView = NSTextView(frame: CGRect(x: 0, y: 0, width: 300, height: 100))
    textView.isRichText = true
    textView.importsGraphics = true
    #expect(textView.supportsAdaptiveImageGlyph)
    #expect(textView.readSelection(from: board))
    try expectExactGlyph(in: #require(textView.textStorage), matching: glyph)
  }

  @Test(arguments: [1, 2])
  func gifFramesAreNeverConvertedAndOriginalBytesRemainIntact(frameCount: Int) throws {
    let data = try encodedImage(
      width: 64, height: 32, typeIdentifier: UTType.gif.identifier, frameCount: frameCount)
    let original = Data(data)
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    #expect(CGImageSourceGetCount(source) == frameCount)
    #expect(
      try InlineStickerImage.convert(data, identifier: "gif", description: "Original GIF") == nil)
    #expect(data == original)
    let restored = try #require(CGImageSourceCreateWithData(original as CFData, nil))
    #expect(CGImageSourceGetType(restored) as String? == UTType.gif.identifier)
    #expect(CGImageSourceGetCount(restored) == frameCount)
    if frameCount == 2 {
      let first = try rgbaPixels(#require(CGImageSourceCreateImageAtIndex(restored, 0, nil)))
      let second = try rgbaPixels(#require(CGImageSourceCreateImageAtIndex(restored, 1, nil)))
      #expect(first != second)
    }
  }

  @Test func multiframeTIFFIsNotFlattenedIntoAStaticGlyph() throws {
    let data = try encodedImage(
      width: 64, height: 32, typeIdentifier: UTType.tiff.identifier, frameCount: 2)
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    #expect(CGImageSourceGetCount(source) == 2)
    #expect(
      try InlineStickerImage.convert(data, identifier: "tiff", description: "Multiple frames")
        == nil)
  }

  @Test func invalidImageDataThrowsInsteadOfReturningAnAnimationFallback() {
    for data in [Data(), Data([0, 1, 2, 3]), Data("not an image".utf8)] {
      #expect(throws: InlineStickerImage.ConversionError.invalidImage) {
        try InlineStickerImage.convert(data, identifier: "invalid", description: "Invalid image")
      }
    }
  }

  private func encodedImage(
    width: Int, height: Int, typeIdentifier: String = UTType.png.identifier,
    transparentCenter: Bool = false, frameCount: Int = 1, orientation: Int = 1, alpha: CGFloat = 1
  ) throws -> Data {
    let context = try #require(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let data = NSMutableData()
    let destination = try #require(
      CGImageDestinationCreateWithData(data, typeIdentifier as CFString, frameCount, nil))
    for frame in 0..<frameCount {
      context.setFillColor(
        CGColor(red: frame == 0 ? 1 : 0, green: 0, blue: frame == 0 ? 0 : 1, alpha: alpha))
      context.fill(CGRect(x: 0, y: 0, width: width, height: height))
      if transparentCenter {
        context.clear(
          CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
      }
      let image = try #require(context.makeImage())
      let properties: [CFString: Any] = [
        kCGImagePropertyOrientation: orientation,
        kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]
      ]
      CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    }
    try #require(CGImageDestinationFinalize(destination))
    return data as Data
  }

  private func decodedImage(_ data: Data) throws -> CGImage {
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
  }

  private func rgbaPixels(_ image: CGImage) throws -> [UInt8] {
    let context = try #require(
      CGContext(
        data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let bytes = try #require(context.data)
    return Array(
      UnsafeBufferPointer(
        start: bytes.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
  }

  private func expectExactGlyph(
    in attributed: NSAttributedString, matching glyph: NSAdaptiveImageGlyph
  )
    throws
  {
    try #require(attributed.length == 1)
    let restored = try #require(
      attributed.attribute(.adaptiveImageGlyph, at: 0, effectiveRange: nil) as? NSAdaptiveImageGlyph
    )
    #expect(restored.imageContent == glyph.imageContent)
    #expect(restored.contentIdentifier == glyph.contentIdentifier)
    #expect(restored.contentDescription == glyph.contentDescription)
    #expect(attributed.attribute(.attachment, at: 0, effectiveRange: nil) == nil)
  }
}
