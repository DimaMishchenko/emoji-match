import AppKit
import ImageIO
import UniformTypeIdentifiers

enum ImportedContent {
  case adaptiveGlyph(NSAdaptiveImageGlyph)
  case image(data: Data, typeIdentifier: String, description: String)
}

enum RichContentImport {
  enum ImportError: Error, Equatable {
    case unsupportedContent
    case invalidContent
  }

  static func read(from pasteboard: NSPasteboard = .general) throws -> [ImportedContent] {
    _ = NSApplication.shared
    var result: [ImportedContent] = []
    var seen = Set<Identity>()
    var malformed = false
    for item in pasteboard.pasteboardItems ?? [] {
      var contents: [ImportedContent] = []
      for (type, documentType) in [
        (NSPasteboard.PasteboardType.rtfd, NSAttributedString.DocumentType.rtfd),
        (.rtf, .rtf)
      ] {
        guard let data = item.data(forType: type) else { continue }
        do {
          let attributed = try NSAttributedString(
            data: data, options: [.documentType: documentType], documentAttributes: nil
          )
          attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) {
            attributes, _, _ in
            if let glyph = attributes[.adaptiveImageGlyph] as? NSAdaptiveImageGlyph {
              contents.append(.adaptiveGlyph(glyph))
            } else if let attachment = attributes[.attachment] as? NSTextAttachment,
              let bytes = attachment.fileWrapper?.regularFileContents ?? attachment.contents,
              let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let type = CGImageSourceGetType(source) as String?,
              isValidImage(bytes, typeIdentifier: type)
            {
              let description = attachment.fileWrapper?.preferredFilename ?? "Imported image"
              contents.append(.image(data: bytes, typeIdentifier: type, description: description))
            }
          }
        } catch {
          malformed = true
        }
        if !contents.isEmpty { break }
      }
      for type in preferredImageTypes(in: item) {
        guard isSupportedImageType(type.rawValue), let data = item.data(forType: type) else {
          continue
        }
        guard isValidImage(data, typeIdentifier: type.rawValue) else {
          malformed = true
          continue
        }
        if contents.isEmpty {
          contents.append(
            .image(data: data, typeIdentifier: type.rawValue, description: "Imported image"))
        } else if frameCount(data) > 1 {
          for index in contents.indices {
            guard case .image(let attachment, _, let description) = contents[index],
              frameCount(attachment) == 1,
              let originalFrame = renderedFirstFrame(attachment),
              originalFrame == renderedFirstFrame(data)
            else { continue }
            contents[index] = .image(
              data: data, typeIdentifier: type.rawValue, description: description)
          }
        }
        break
      }
      for content in contents where seen.insert(identity(of: content)).inserted {
        result.append(content)
      }
    }
    guard !result.isEmpty else {
      throw malformed ? ImportError.invalidContent : ImportError.unsupportedContent
    }
    return result
  }

  private static func frameCount(_ data: Data) -> Int {
    CGImageSourceCreateWithData(data as CFData, nil).map(CGImageSourceGetCount) ?? 0
  }

  private struct ImageFrame: Equatable {
    let width: Int
    let height: Int
    let pixels: Data
  }

  private static func renderedFirstFrame(_ data: Data) -> ImageFrame? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      image.width > 0, image.height > 0, image.width <= 4096, image.height <= 4096,
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
    else { return nil }
    var pixels = Data(count: image.width * image.height * 4)
    let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: image.width, height: image.height,
          bitsPerComponent: 8, bytesPerRow: image.width * 4, space: colorSpace,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue)
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
      return true
    }
    return rendered ? ImageFrame(width: image.width, height: image.height, pixels: pixels) : nil
  }

  private static func preferredImageTypes(
    in item: NSPasteboardItem
  ) -> [NSPasteboard.PasteboardType] {
    let preferences: [UTType] = [.gif, .webP, .heic, .png, .jpeg, .tiff, .bmp]
    return item.types.sorted { first, second in
      func priority(_ identifier: String) -> Int {
        guard let type = UTType(identifier) else { return preferences.count }
        return preferences.firstIndex { type.conforms(to: $0) } ?? preferences.count
      }
      return priority(first.rawValue) < priority(second.rawValue)
    }
  }

  static func isSupportedImageType(_ identifier: String) -> Bool {
    guard let type = UTType(identifier) else { return false }
    return [.png, .jpeg, .gif, .tiff, .heic, .webP, .bmp].contains { type.conforms(to: $0) }
  }

  static func isValidImage(_ data: Data, typeIdentifier: String) -> Bool {
    guard isSupportedImageType(typeIdentifier), let expected = UTType(typeIdentifier),
      let source = CGImageSourceCreateWithData(data as CFData, nil),
      let identifier = CGImageSourceGetType(source), let actual = UTType(identifier as String),
      actual.conforms(to: expected), CGImageSourceGetCount(source) > 0,
      CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
    else { return false }
    return true
  }

  private struct Identity: Hashable {
    let kind: String
    let data: Data
  }

  private static func identity(of content: ImportedContent) -> Identity {
    switch content {
    case .adaptiveGlyph(let glyph):
      Identity(kind: "glyph:\(glyph.contentIdentifier)", data: glyph.imageContent)
    case .image(let data, let typeIdentifier, _):
      Identity(kind: typeIdentifier, data: data)
    }
  }
}
