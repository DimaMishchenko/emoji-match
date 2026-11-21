import DesignSystem
import SwiftUI

struct EmojiSearchSettingsView: View {
  @Bindable var settings: AppSettings
  @State private var credentials: EmojiSearchCredentialModel
  @State private var key = ""
  private let onCredentialsChanged: () -> Void
  private let multilingualModel: EmojiMultilingualModelStore?
  private let onRemoveMultilingualModel: () async throws -> Void

  init(
    settings: AppSettings, onCredentialsChanged: @escaping () -> Void = {},
    multilingualModel: EmojiMultilingualModelStore? = nil,
    onRemoveMultilingualModel: @escaping () async throws -> Void
  ) {
    self.settings = settings
    self.multilingualModel = multilingualModel
    self.onRemoveMultilingualModel = onRemoveMultilingualModel
    self.onCredentialsChanged = onCredentialsChanged
    _credentials = State(
      initialValue: EmojiSearchCredentialModel(
        credentials: .keychain(service: settings.searchCredentialService)))
  }

  var body: some View {
    Form {
      Section {
        Toggle(EmojiSearchProvider.lexical.title, isOn: $settings.lexicalSearchEnabled)
        Toggle(EmojiSearchProvider.miniLM.title, isOn: $settings.miniLMSearchEnabled)
        Toggle(EmojiSearchProvider.multilingual.title, isOn: $settings.multilingualSearchEnabled)
      } header: {
        Text("On This Mac")
      } footer: {
        explanation(
          "Private, on-device search. MiniLM handles English; E5 handles other or uncertain queries. Only the applicable enabled model runs."
        )
      }
      Section {
        EmojiMultilingualModelSettings(
          model: multilingualModel, onRemove: onRemoveMultilingualModel)
      } header: {
        Text("Multilingual Model")
      } footer: {
        if let model = multilingualModel {
          let download = ByteCountFormatter.string(
            fromByteCount: model.downloadBytes, countStyle: .file)
          let installed = ByteCountFormatter.string(
            fromByteCount: model.installedBytesEstimate, countStyle: .file)
          explanation(
            "\(download) download · about \(installed) installed. Downloaded from GitHub; no searches are sent. Works offline once installed."
          )
        }
      }
      Section {
        Toggle(EmojiSearchProvider.luna.title, isOn: $settings.lunaSearchEnabled)
        Toggle(EmojiSearchProvider.duckDuckGo.title, isOn: $settings.duckDuckGoSearchEnabled)
        if settings.lunaSearchEnabled || credentials.hasSavedKey {
          if settings.lunaSearchEnabled {
            SecureField(credentials.hasSavedKey ? "Replace API key" : "API key", text: $key)
              .textContentType(.password)
              .onSubmit(saveKey)
          }
          HStack {
            if settings.lunaSearchEnabled {
              Button("Save Key", action: saveKey)
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if credentials.hasSavedKey {
              Button("Remove Key", role: .destructive) {
                credentials.remove(provider: .luna)
                key = ""
                onCredentialsChanged()
              }
            }
          }
          if let message = credentials.message {
            explanation(message)
          } else if credentials.hasSavedKey {
            explanation("Key saved in Keychain.")
          }
        }
      } header: {
        Text("Online")
      } footer: {
        explanation(
          "Online sources receive your search and language preferences, including selected-text prefill. Luna uses your key and may incur charges. Web Search uses DuckDuckGo without a key; site data stays on this Mac and throttling can pause searches."
        )
      }
      Section {
        Toggle("Group results by provider", isOn: $settings.groupSearchResultsByProvider)
      } footer: {
        explanation("Sections may repeat emoji.")
      }
    }
    .formStyle(.grouped)
    .safeAreaInset(edge: .bottom, alignment: .leading) {
      Text("Changes apply when you reopen the picker.")
        .font(.caption).foregroundStyle(Color.ds.textSecondary)
        .padding(.horizontal, .ds.spacing.md).padding(.vertical, .ds.spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    .onAppear { credentials.refresh(provider: .luna) }
    .onDisappear { key = "" }
    .onChange(of: settings.lunaSearchEnabled) { _, enabled in
      if !enabled { key = "" }
    }
  }

  private func explanation(_ text: String) -> some View {
    Text(text).font(.caption).foregroundStyle(Color.ds.textSecondary)
  }

  private func saveKey() {
    if credentials.save(key, provider: .luna) {
      key = ""
      onCredentialsChanged()
    }
  }
}
