import AppKit
import Carbon.HIToolbox
import ImageIO
import UniformTypeIdentifiers

enum TextPasteController {
  static let session = Session()

  @discardableResult
  static func paste(
    _ selection: EmojiSelection, data: Data? = nil, to destination: InsertionDestination
  ) -> Bool {
    session.paste(selection, data: data, to: destination)
  }

  @discardableResult
  static func copy(_ selection: EmojiSelection, data: Data? = nil) -> Bool {
    session.copy(selection, data: data)
  }

  final class Session {
    struct Dependencies {
      var pasteboard: NSPasteboard
      var write: (NSPasteboard, [NSPasteboardItem]) -> Bool
      var postPaste: (pid_t) -> Bool
      var schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void
      var restoreFocus: (InsertionDestination) -> Bool
      var validate: (InsertionDestination) -> Bool
      var postRichPaste: (pid_t, () -> Bool) -> RecipientPasteCommand.Result = { _, _ in
        .unavailable
      }

      static var live: Self {
        Self(
          pasteboard: .general,
          write: { $0.writeObjects($1) },
          postPaste: { pid in
            let source = CGEventSource(stateID: .combinedSessionState)
            guard
              let down = CGEvent(
                keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true
              ),
              let up = CGEvent(
                keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false
              )
            else { return false }
            down.flags = .maskCommand
            up.flags = .maskCommand
            down.postToPid(pid)
            up.postToPid(pid)
            return true
          },
          schedule: { delay, action in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
          },
          restoreFocus: { $0.restoreFocus() },
          validate: { $0.isValidForDelivery() },
          postRichPaste: { RecipientPasteCommand.perform(for: $0, validate: $1) }
        )
      }
    }

    private struct Transaction {
      let token: UUID
      let snapshot: PasteboardSnapshot
      let changeCount: Int
    }

    private let dependencies: Dependencies
    private var transaction: Transaction?
    private(set) var restorationFailed = false

    init(dependencies: Dependencies = .live) {
      self.dependencies = dependencies
    }

    @discardableResult
    func paste(
      _ selection: EmojiSelection, data: Data? = nil, to destination: InsertionDestination
    ) -> Bool {
      guard let item = Self.payload(selection, data: data),
        dependencies.restoreFocus(destination), dependencies.validate(destination),
        let operation = beginWrite(item)
      else { return false }
      let validate = {
        self.dependencies.validate(destination)
          && self.dependencies.pasteboard.changeCount == operation.changeCount
      }
      guard validate() else {
        restore(operation)
        return false
      }
      let result =
        selection.asset == nil
        ? RecipientPasteCommand.Result.unavailable
        : dependencies.postRichPaste(destination.application.processIdentifier, validate)
      let performed: Bool
      switch result {
      case .performed:
        performed = true
      case .failed:
        performed = false
      case .unavailable:
        performed = validate() && dependencies.postPaste(destination.application.processIdentifier)
      }
      guard performed else {
        restore(operation)
        return false
      }
      dependencies.schedule(1) { [weak self] in self?.restore(operation) }
      return true
    }

    @discardableResult
    func copy(_ selection: EmojiSelection, data: Data? = nil) -> Bool {
      guard let item = Self.payload(selection, data: data), beginWrite(item) != nil else {
        return false
      }
      transaction = nil
      return true
    }

    private func beginWrite(_ item: NSPasteboardItem) -> Transaction? {
      let board = dependencies.pasteboard
      let snapshot: PasteboardSnapshot
      if let transaction, board.changeCount == transaction.changeCount {
        snapshot = transaction.snapshot
      } else {
        guard let captured = PasteboardSnapshot.capture(from: board) else { return nil }
        snapshot = captured
      }
      transaction = nil
      let token = UUID()
      let cleared = board.clearContents()
      guard dependencies.write(board, [item]) else {
        if board.changeCount == cleared {
          restorationFailed = !snapshot.restore(to: board, write: dependencies.write)
        }
        return nil
      }
      let operation = Transaction(token: token, snapshot: snapshot, changeCount: board.changeCount)
      transaction = operation
      return operation
    }

    private func restore(_ operation: Transaction) {
      guard transaction?.token == operation.token else { return }
      transaction = nil
      guard dependencies.pasteboard.changeCount == operation.changeCount else { return }
      restorationFailed = !operation.snapshot.restore(
        to: dependencies.pasteboard, write: dependencies.write
      )
    }

    private static func payload(_ selection: EmojiSelection, data: Data?) -> NSPasteboardItem? {
      let item = NSPasteboardItem()
      guard let asset = selection.asset else {
        return item.setString(selection.value, forType: .string) ? item : nil
      }
      guard let data else { return nil }
      switch asset.kind {
      case .adaptiveGlyph:
        guard RichContentImport.isValidImage(data, typeIdentifier: asset.typeIdentifier) else {
          return nil
        }
        let glyph = NSAdaptiveImageGlyph(imageContent: data)
        guard glyph.contentIdentifier == asset.identifier, glyph.imageContent == data,
          let png = pngRepresentation(of: data)
        else {
          return nil
        }
        let attributed = NSAttributedString(adaptiveImageGlyph: glyph, attributes: [:])
        guard
          let rtfd = try? attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
          ), item.setData(rtfd, forType: .rtfd),
          item.setData(data, forType: NSPasteboard.PasteboardType(asset.typeIdentifier)),
          item.setData(png, forType: .png)
        else { return nil }
      case .image:
        guard RichContentImport.isValidImage(data, typeIdentifier: asset.typeIdentifier),
          item.setData(data, forType: NSPasteboard.PasteboardType(asset.typeIdentifier))
        else { return nil }
      }
      return item
    }

    private static func pngRepresentation(of data: Data) -> Data? {
      guard let source = CGImageSourceCreateWithData(data as CFData, nil),
        let image = CGImageSourceCreateThumbnailAtIndex(
          source, 0,
          [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 24
          ] as CFDictionary)
      else { return nil }
      let result = NSMutableData()
      guard
        let destination = CGImageDestinationCreateWithData(
          result, UTType.png.identifier as CFString, 1, nil)
      else { return nil }
      CGImageDestinationAddImage(destination, image, nil)
      guard CGImageDestinationFinalize(destination) else { return nil }
      return result as Data
    }
  }
}

private struct PasteboardSnapshot {
  let items: [NSPasteboardItem]

  static func capture(from pasteboard: NSPasteboard) -> Self? {
    let changeCount = pasteboard.changeCount
    var items: [NSPasteboardItem] = []
    for item in pasteboard.pasteboardItems ?? [] {
      let clone = NSPasteboardItem()
      for type in item.types {
        guard let data = item.data(forType: type), clone.setData(data, forType: type) else {
          return nil
        }
      }
      items.append(clone)
    }
    guard pasteboard.changeCount == changeCount else { return nil }
    return Self(items: items)
  }

  func restore(
    to pasteboard: NSPasteboard, write: (NSPasteboard, [NSPasteboardItem]) -> Bool
  ) -> Bool {
    pasteboard.clearContents()
    return items.isEmpty || write(pasteboard, items)
  }
}
