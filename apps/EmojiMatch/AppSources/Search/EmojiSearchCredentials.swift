import Foundation
import Observation
import Security

struct EmojiSearchCredentials {
  var read: (EmojiSearchProvider) throws -> String?
  var write: (EmojiSearchProvider, String?) throws -> Void

  static func keychain(service: String) -> Self {
    Self(
      read: { provider in
        guard provider == .luna else { return nil }
        let query: [String: Any] = [
          kSecClass as String: kSecClassGenericPassword,
          kSecAttrService as String: service,
          kSecAttrAccount as String: provider.rawValue,
          kSecReturnData as String: true,
          kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
          let key = String(data: data, encoding: .utf8), !key.isEmpty
        else { throw CredentialError.unavailable }
        return key
      },
      write: { provider, key in
        guard provider == .luna else { throw CredentialError.unavailable }
        let query: [String: Any] = [
          kSecClass as String: kSecClassGenericPassword,
          kSecAttrService as String: service,
          kSecAttrAccount as String: provider.rawValue
        ]
        guard let key else {
          let status = SecItemDelete(query as CFDictionary)
          guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialError.unavailable
          }
          return
        }
        let data = Data(key.utf8)
        let status = SecItemUpdate(
          query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
          var item = query
          item[kSecValueData as String] = data
          item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
          guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
            throw CredentialError.unavailable
          }
        } else if status != errSecSuccess {
          throw CredentialError.unavailable
        }
      })
  }

  private enum CredentialError: Error {
    case unavailable
  }
}

@Observable
final class EmojiSearchCredentialModel {
  private(set) var hasSavedKey = false
  private(set) var message: String?
  private let credentials: EmojiSearchCredentials

  init(credentials: EmojiSearchCredentials) {
    self.credentials = credentials
  }

  func refresh(provider: EmojiSearchProvider) {
    message = nil
    guard provider == .luna else {
      hasSavedKey = false
      return
    }
    do {
      hasSavedKey = try credentials.read(provider) != nil
    } catch {
      hasSavedKey = false
      message = "Couldn’t read the saved key from Keychain."
    }
  }

  @discardableResult
  func save(_ key: String, provider: EmojiSearchProvider) -> Bool {
    let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty, provider == .luna else { return false }
    do {
      try credentials.write(provider, key)
      hasSavedKey = true
      message = "Key saved in Keychain."
      return true
    } catch {
      message = "Couldn’t save the key in Keychain."
      return false
    }
  }

  func remove(provider: EmojiSearchProvider) {
    guard provider == .luna else { return }
    do {
      try credentials.write(provider, nil)
      hasSavedKey = false
      message = "Saved key removed."
    } catch {
      message = "Couldn’t remove the saved key from Keychain."
    }
  }
}
