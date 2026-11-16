import AppKit
import ObjectiveC

struct NativeSymbolCategory {
  let id: String
  let title: String
  let image: NSImage?
  let entries: [EmojiSelection]
  let descriptionsByID: [String: String]
}

struct NativeEmojiCategory {
  let id: String
  let title: String
  let image: NSImage?
  let values: [String]
}

enum NativeSymbolCatalog {
  enum LoadError: Error {
    case frameworkUnavailable
    case unsupportedRuntime(String)
    case invalidCategory(String)
    case invalidEntry(String)
  }

  private struct CategoryResource {
    let identifier: String
    let name: String
  }

  private static let resources = [
    CategoryResource(identifier: "SymbolsCategoryLetterlike", name: "LetterlikeSymbols"),
    CategoryResource(identifier: "SymbolsCategoryPictographs", name: "Pictographs"),
    CategoryResource(identifier: "SymbolsCategoryBullets", name: "Bullets"),
    CategoryResource(identifier: "SymbolsCategoryTechnical", name: "TechnicalSymbols"),
    CategoryResource(identifier: "SymbolsCategorySignStandard", name: "SignStandardSymbols")
  ]

  static func loadStickerCategoryImages() throws -> [NSImage] {
    guard
      let framework = Bundle(path: "/System/Library/PrivateFrameworks/CharacterPicker.framework"),
      framework.isLoaded || framework.load(),
      let categoryClass = NSClassFromString("CPKCategoryData"),
      let items = try object(categoryClass, selector: "stickerItems") as? [NSObject],
      (1...2).contains(items.count)
    else { throw LoadError.unsupportedRuntime("stickerItems") }
    return try items.map { item in
      guard let image = try object(item, selector: "image") as? NSImage else {
        throw LoadError.unsupportedRuntime("sticker image")
      }
      return image
    }
  }

  static func load() throws -> [NativeSymbolCategory] {
    guard
      let framework = Bundle(path: "/System/Library/PrivateFrameworks/CharacterPicker.framework"),
      framework.isLoaded || framework.load(),
      let palette = Bundle(path: "/System/Library/Input Methods/CharacterPalette.app"),
      let categoryClass = NSClassFromString("CPKCategoryData"),
      let fontClass = NSClassFromString("CPKFont")
    else {
      throw LoadError.frameworkUnavailable
    }

    guard
      let identifiers = try object(categoryClass, selector: "symbolItemIdentifiers") as? [String],
      let items = try object(categoryClass, selector: "symbolItems") as? [NSObject],
      identifiers.count == items.count,
      Set(identifiers) == Set(resources.map(\.identifier)),
      Set(identifiers).count == identifiers.count
    else {
      throw LoadError.unsupportedRuntime("symbolItems")
    }

    let font = try makeFont(fontClass)
    let database = try NSClassFromString("CPCharacterDatabase")
      .flatMap {
        try object($0, selector: "sharedDatabase")
      }
    return try zip(identifiers, items)
      .map { identifier, item in
        guard
          let resource = resources.first(where: { $0.identifier == identifier }),
          try object(item, selector: "identifier") as? String == identifier
        else {
          throw LoadError.invalidCategory(identifier)
        }

        let data = try categoryData(resource.name, bundle: palette)
        guard let inventory = data["Data"] as? String, !inventory.isEmpty else {
          throw LoadError.invalidCategory(identifier)
        }
        let skipNullGlyphs = data["CVSkipNullGlyphs"] as? Bool == true
        let entries = try inventory.components(separatedBy: ",")
          .compactMap { token in
            let value = try decode(token)
            if skipNullGlyphs, try !hasGlyph(value, font: font) {
              return nil as EmojiSelection?
            }
            let id =
              "symbol:"
              + value.unicodeScalars.map { String($0.value, radix: 16) }
              .joined(
                separator: "-")
            return EmojiSelection(id: id, value: value)
          }
        guard !entries.isEmpty, Set(entries.map(\.id)).count == entries.count else {
          throw LoadError.invalidCategory(identifier)
        }
        return NativeSymbolCategory(
          id: identifier,
          title: palette.localizedString(
            forKey: "CategoryName-\(resource.name)", value: resource.name, table: nil),
          image: try object(item, selector: "image") as? NSImage,
          entries: entries,
          descriptionsByID: try Dictionary(
            uniqueKeysWithValues: entries.compactMap { entry in
              guard let database,
                let info = try object(
                  database, selector: "searchCharacterInfo:", argument: entry.value as NSString)
                  as? [String: Any],
                let description = info["unam"] as? String, !description.isEmpty
              else { return nil }
              return (entry.id, description)
            })
        )
      }
  }

  static func loadEmojiCategories() throws -> [NativeEmojiCategory] {
    guard
      let framework = Bundle(path: "/System/Library/PrivateFrameworks/CharacterPicker.framework"),
      framework.isLoaded || framework.load(),
      let sourceClass = NSClassFromString("CPKDefaultDataSource"),
      let categoryClass = NSClassFromString("CPKCategoryData")
    else {
      throw LoadError.frameworkUnavailable
    }
    guard
      let categories = try object(
        sourceClass, selector: "loadEmojiCategoryData:", argument: "Emoji") as? [[String: Any]],
      let items = try object(categoryClass, selector: "emojiItems") as? [NSObject],
      let identifiers = try object(categoryClass, selector: "emojiItemIdentifiers") as? [String],
      items.count == identifiers.count,
      Set(identifiers).count == identifiers.count
    else {
      throw LoadError.unsupportedRuntime("loadEmojiCategoryData:")
    }
    let result = try categories.map { category in
      guard
        let rawTitle = category["RawTitleText"] as? String, rawTitle.hasPrefix("EMFEmojiCategory"),
        let title = category["TitleText"] as? String,
        let values = category["Data"] as? [String], !values.isEmpty,
        values.allSatisfy({ !$0.isEmpty }),
        Set(values).count == values.count
      else {
        throw LoadError.invalidCategory("Emoji")
      }
      let identifier = String(rawTitle.dropFirst(3))
      guard let index = identifiers.firstIndex(of: identifier),
        try object(items[index], selector: "identifier") as? String == identifier
      else {
        throw LoadError.invalidCategory(identifier)
      }
      return NativeEmojiCategory(
        id: identifier, title: title,
        image: try object(items[index], selector: "image") as? NSImage,
        values: values
      )
    }
    guard result.map(\.id) == identifiers.filter({ $0 != "EmojiCategoryRecents" }) else {
      throw LoadError.unsupportedRuntime("emojiItemIdentifiers")
    }
    return result
  }

  private static func categoryData(_ name: String, bundle: Bundle) throws -> [String: Any] {
    let base = "Category-\(name)"
    let localized = bundle.preferredLocalizations.first.flatMap { language in
      bundle.url(forResource: "\(base)_\(language)", withExtension: "plist")
    }
    guard let url = localized ?? bundle.url(forResource: base, withExtension: "plist") else {
      throw LoadError.invalidCategory(name)
    }
    let plist = try PropertyListSerialization.propertyList(
      from: Data(contentsOf: url), options: [], format: nil)
    guard let root = plist as? [String: Any],
      let category = root["CVCategoryData"] as? [String: Any]
    else {
      throw LoadError.invalidCategory(name)
    }
    return category
  }

  private static func decode(_ token: String) throws -> String {
    guard !token.isEmpty else { throw LoadError.invalidEntry(token) }
    guard token.hasPrefix("0x") else { return token }
    guard let code = UInt32(token.dropFirst(2), radix: 16), let scalar = UnicodeScalar(code) else {
      throw LoadError.invalidEntry(token)
    }
    return String(scalar)
  }

  private static func makeFont(_ fontClass: AnyClass) throws -> NSObject {
    guard let name = try object(fontClass, selector: "defaultFontName") as? NSString else {
      throw LoadError.unsupportedRuntime("defaultFontName")
    }
    let selector = NSSelectorFromString("sharedFontWithName:size:")
    let method = try checkedMethod(
      fontClass, selector: selector, result: "@", arguments: ["@", ":", "@", "d"])
    typealias Function =
      @convention(c) (AnyObject, Selector, NSString, Double) -> Unmanaged<AnyObject>?
    guard
      let font = unsafeBitCast(method_getImplementation(method), to: Function.self)(
        fontClass, selector, name, 16)?
        .takeUnretainedValue() as? NSObject
    else {
      throw LoadError.unsupportedRuntime("sharedFontWithName:size:")
    }
    return font
  }

  private static func hasGlyph(_ value: String, font: NSObject) throws -> Bool {
    let selector = NSSelectorFromString("glyphForString:fallbackFontName:")
    let method = try checkedMethod(
      font, selector: selector, result: "S", arguments: ["@", ":", "@", "^@"])
    typealias Function =
      @convention(c) (
        AnyObject, Selector, NSString, AutoreleasingUnsafeMutablePointer<AnyObject?>?
      ) -> UInt16
    var fallback: AnyObject?
    return unsafeBitCast(method_getImplementation(method), to: Function.self)(
      font, selector, value as NSString, &fallback) != 0
  }

  private static func object(_ receiver: AnyObject, selector name: String) throws -> AnyObject? {
    let selector = NSSelectorFromString(name)
    let method = try checkedMethod(receiver, selector: selector, result: "@", arguments: ["@", ":"])
    typealias Function = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
    return unsafeBitCast(method_getImplementation(method), to: Function.self)(receiver, selector)?
      .takeUnretainedValue()
  }

  private static func object(
    _ receiver: AnyObject, selector name: String, argument: NSString
  ) throws -> AnyObject? {
    let selector = NSSelectorFromString(name)
    let method = try checkedMethod(
      receiver, selector: selector, result: "@", arguments: ["@", ":", "@"])
    typealias Function = @convention(c) (AnyObject, Selector, NSString) -> Unmanaged<AnyObject>?
    return unsafeBitCast(method_getImplementation(method), to: Function.self)(
      receiver, selector, argument)?
      .takeUnretainedValue()
  }

  private static func checkedMethod(
    _ receiver: AnyObject, selector: Selector, result: String, arguments: [String]
  ) throws -> Method {
    guard
      let type = object_getClass(receiver),
      let method = class_getInstanceMethod(type, selector),
      method_getNumberOfArguments(method) == arguments.count
    else {
      throw LoadError.unsupportedRuntime(NSStringFromSelector(selector))
    }
    let returnType = method_copyReturnType(method)
    defer { free(returnType) }
    guard String(cString: returnType) == result else {
      throw LoadError.unsupportedRuntime(NSStringFromSelector(selector))
    }
    for (index, expected) in arguments.enumerated() {
      guard let argument = method_copyArgumentType(method, UInt32(index)) else {
        throw LoadError.unsupportedRuntime(NSStringFromSelector(selector))
      }
      defer { free(argument) }
      guard String(cString: argument) == expected else {
        throw LoadError.unsupportedRuntime(NSStringFromSelector(selector))
      }
    }
    return method
  }
}
