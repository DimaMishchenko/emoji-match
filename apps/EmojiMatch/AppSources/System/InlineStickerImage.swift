import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

enum InlineStickerImage {
  enum ConversionError: Error {
    case invalidImage
    case encodingFailed
    case invalidGlyph
  }

  static func stableIdentifier(for data: Data) -> String {
    let hex = SHA256.hash(data: data).prefix(16).map { String(format: "%02X", $0) }.joined()
    let lengths = [8, 4, 4, 4, 12]
    var cursor = hex.startIndex
    return
      lengths.map { length in
        let end = hex.index(cursor, offsetBy: length)
        defer { cursor = end }
        return String(hex[cursor..<end])
      }
      .joined(separator: "-")
  }

  static func convert(
    _ data: Data, identifier: String, description: String
  ) throws -> NSAdaptiveImageGlyph? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
      throw ConversionError.invalidImage
    }
    let frameCount = CGImageSourceGetCount(source)
    guard frameCount > 0 else { throw ConversionError.invalidImage }
    guard frameCount == 1,
      CGImageSourceGetType(source) as String? != UTType.gif.identifier
    else { return nil }
    guard !identifier.isEmpty, !description.isEmpty,
      let frame = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: 512,
          kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary),
      frame.width > 0, frame.height > 0,
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
    else { throw ConversionError.invalidImage }

    let side = max(frame.width, frame.height)
    guard
      let context = CGContext(
        data: nil, width: side, height: side, bitsPerComponent: 8,
        bytesPerRow: 0, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw ConversionError.invalidImage }
    context.clear(CGRect(x: 0, y: 0, width: side, height: side))
    context.draw(
      frame,
      in: CGRect(
        x: CGFloat(side - frame.width) / 2, y: CGFloat(side - frame.height) / 2,
        width: CGFloat(frame.width), height: CGFloat(frame.height)))
    guard let image = context.makeImage() else { throw ConversionError.invalidImage }
    let encoded = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        encoded, UTType.heic.identifier as CFString, 1, nil)
    else { throw ConversionError.encodingFailed }
    let properties: [CFString: Any] = [
      kCGImageDestinationLossyCompressionQuality: 0.95,
      kCGImagePropertyTIFFDictionary: [
        kCGImagePropertyTIFFDocumentName: identifier,
        kCGImagePropertyTIFFImageDescription: description
      ]
    ]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw ConversionError.encodingFailed }
    let imageContent = encoded as Data
    let glyph = NSAdaptiveImageGlyph(imageContent: imageContent)
    guard glyph.contentIdentifier == identifier, glyph.contentDescription == description,
      glyph.imageContent == imageContent
    else { throw ConversionError.invalidGlyph }
    return glyph
  }
}
