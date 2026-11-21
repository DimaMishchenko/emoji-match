import Foundation
import Testing

@testable import EmojiMatch

struct EmojiSearchCredentialTests {
  @Test func onlyLunaAcceptsCredentials() {
    let fixture = CredentialsFixture()
    let model = EmojiSearchCredentialModel(credentials: fixture.store)
    #expect(!model.save(" \n", provider: .luna))
    #expect(!model.save("mock", provider: .lexical))
    #expect(!model.save("mock", provider: .miniLM))
    #expect(!model.save("mock", provider: .multilingual))
    #expect(!model.save("mock", provider: .duckDuckGo))
    #expect(fixture.values.isEmpty)
    #expect(model.save(" mock-luna \n", provider: .luna))
    #expect(fixture.values[.luna] == "mock-luna")
    model.remove(provider: .luna)
    #expect(fixture.values.isEmpty)
  }

  @Test(arguments: [EmojiSearchProvider.lexical, .miniLM, .multilingual, .duckDuckGo])
  func nonLunaSourcesNeverAccessCredentialStore(provider: EmojiSearchProvider) {
    let fixture = CredentialsFixture()
    let model = EmojiSearchCredentialModel(credentials: fixture.store)
    #expect(model.save("mock-luna", provider: .luna))
    fixture.readCount = 0
    fixture.writeCount = 0
    model.refresh(provider: provider)
    #expect(!model.hasSavedKey)
    #expect(model.message == nil)
    #expect(!model.save("mock", provider: provider))
    model.remove(provider: provider)
    #expect(fixture.readCount == 0)
    #expect(fixture.writeCount == 0)
    #expect(fixture.values[.luna] == "mock-luna")
  }

  @Test func emptySavePreservesExistingKey() {
    let fixture = CredentialsFixture()
    let model = EmojiSearchCredentialModel(credentials: fixture.store)
    #expect(model.save("mock-luna", provider: .luna))
    #expect(!model.save(" \n", provider: .luna))
    #expect(fixture.values[.luna] == "mock-luna")
    #expect(model.hasSavedKey)
    model.refresh(provider: .luna)
    #expect(model.hasSavedKey)
    model.remove(provider: .luna)
    #expect(!model.hasSavedKey)
  }

  @Test func failuresNeverSurfaceCredentialOrBackendErrorDetails() {
    let model = EmojiSearchCredentialModel(
      credentials: EmojiSearchCredentials(
        read: { _ in throw CredentialFixtureError.privateDetail },
        write: { _, _ in throw CredentialFixtureError.privateDetail }))
    model.refresh(provider: .luna)
    #expect(!model.hasSavedKey)
    #expect(model.message == "Couldn’t read the saved key from Keychain.")
    #expect(!model.save("private-key", provider: .luna))
    #expect(!model.hasSavedKey)
    #expect(model.message == "Couldn’t save the key in Keychain.")
    model.remove(provider: .luna)
    #expect(model.message == "Couldn’t remove the saved key from Keychain.")
  }
}

private final class CredentialsFixture {
  var values: [EmojiSearchProvider: String] = [:]
  var readCount = 0
  var writeCount = 0
  var store: EmojiSearchCredentials {
    EmojiSearchCredentials(
      read: {
        self.readCount += 1
        return self.values[$0]
      },
      write: {
        self.writeCount += 1
        self.values[$0] = $1
      })
  }
}

private enum CredentialFixtureError: Error {
  case privateDetail
}
