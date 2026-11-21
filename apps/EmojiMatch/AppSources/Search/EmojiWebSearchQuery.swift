import Foundation
import NaturalLanguage

nonisolated enum EmojiWebSearchQuery {
  static func language(for query: String, localeIdentifier: String) -> String {
    let scalars = query.unicodeScalars
    if scalars.contains(where: { (0x3040...0x30FF).contains($0.value) }) { return "ja" }
    if scalars.contains(where: { (0xAC00...0xD7AF).contains($0.value) }) { return "ko" }
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(query)
    let letters = scalars.filter(\.properties.isAlphabetic)
    let localeLanguage = Locale(identifier: localeIdentifier).language.languageCode?.identifier
    let hasHan = scalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) })
    if hasHan, letters.count <= 2, let localeLanguage, ["ja", "zh"].contains(localeLanguage) {
      return localeLanguage
    }
    let hasNonLatinScript = letters.contains {
      $0.value > 0x024F && !(0x1E00...0x1EFF).contains($0.value)
    }
    if let language = recognizer.dominantLanguage,
      (hasNonLatinScript || letters.count >= 12),
      (recognizer.languageHypotheses(withMaximum: 1)[language] ?? 0) >= 0.75
    {
      switch language {
      case .simplifiedChinese, .traditionalChinese: return "zh"
      default: return language.rawValue
      }
    }
    if hasHan { return "zh" }
    return localeLanguage ?? "en"
  }

  static func text(for query: String, localeIdentifier: String) -> String {
    switch language(for: query, localeIdentifier: localeIdentifier) {
    case "en": return "emoji for \(query) copy and paste"
    case "uk": return "\(query) емодзі"
    case "ru": return "\(query) эмодзи"
    case "ja": return "\(query) 絵文字"
    case "ko": return "\(query) 이모지"
    case "zh":
      let locale = Locale(identifier: localeIdentifier)
      let traditional =
        locale.language.script?.identifier == "Hant"
        || ["TW", "HK", "MO"].contains(locale.region?.identifier ?? "")
      return "\(query) \(traditional ? "表情符號" : "表情符号")"
    case "ar": return "\(query) إيموجي"
    case "hi": return "\(query) इमोजी"
    case "fr": return "\(query) émoji"
    default: return "\(query) emoji"
    }
  }

  static func regionLocale(for query: String, localeIdentifier: String) -> String {
    let language = language(for: query, localeIdentifier: localeIdentifier)
    guard language != Locale(identifier: localeIdentifier).language.languageCode?.identifier else {
      return localeIdentifier
    }
    return [
      "uk": "uk_UA", "ru": "ru_RU", "ja": "ja_JP", "ko": "ko_KR", "zh": "zh_CN",
      "fr": "fr_FR", "de": "de_DE", "es": "es_ES", "pt": "pt_PT", "cs": "cs_CZ",
      "ar": "ar_SA", "hi": "hi_IN", "tr": "tr_TR"
    ][language] ?? language
  }
}
