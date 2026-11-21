import DesignSystem
import SwiftUI

struct EmojiMultilingualModelSettings: View {
  let model: EmojiMultilingualModelStore?
  let onRemove: () async throws -> Void
  @State private var removalError: String?
  @State private var removing = false

  var body: some View {
    if let model {
      Group {
        switch model.state {
        case .notInstalled:
          HStack {
            Text("Not downloaded").foregroundStyle(Color.ds.textSecondary)
            Spacer()
            Button("Download") { model.startDownload() }
          }
        case .checking:
          ProgressView("Checking language model…").controlSize(.small)
        case .downloading(let progress):
          ProgressView(value: progress) {
            Text("Downloading language model…")
          } currentValueLabel: {
            Text(progress, format: .percent.precision(.fractionLength(0)))
          }
          Button("Cancel") { Task { await model.cancel() } }
        case .installing:
          ProgressView("Installing language model…").controlSize(.small)
          Button("Cancel") { Task { await model.cancel() } }
        case .cancelling:
          ProgressView("Cancelling…").controlSize(.small)
        case .ready:
          HStack {
            Text("Available offline").foregroundStyle(Color.ds.textSecondary)
            Spacer()
            Button("Remove", role: .destructive) {
              removing = true
              removalError = nil
              Task {
                defer { removing = false }
                do { try await onRemove() } catch { removalError = error.localizedDescription }
              }
            }
            .disabled(removing)
          }
        case .failed(let message):
          Text(message).font(.caption).foregroundStyle(Color.ds.textSecondary)
          Button("Try Again") { model.startDownload() }
        }
        if let removalError {
          Text(removalError).font(.caption).foregroundStyle(Color.ds.textSecondary)
        }
      }
      .task {
        if model.state == .notInstalled { _ = try? await model.availableResourceDirectory() }
      }
    } else {
      Text(EmojiMultilingualModelFeedback.unavailableMessage)
        .font(.caption).foregroundStyle(Color.ds.textSecondary)
    }
  }
}

enum EmojiMultilingualModelFeedback {
  static let unavailableMessage =
    "The multilingual language model is unavailable in this app version."

  static func canDownload(_ state: EmojiMultilingualModelStore.State?) -> Bool {
    switch state {
    case .notInstalled?, .failed?: true
    default: false
    }
  }

  static func result(
    _ result: EmojiSearchProviderResult, state: EmojiMultilingualModelStore.State?
  ) -> EmojiSearchProviderResult {
    guard result.provider == .multilingual else { return result }
    switch state {
    case .ready?: return result
    case .checking?: return progress("Checking language model…")
    case .downloading(let fraction)?:
      return progress("Downloading language model… \(Int(min(1, max(0, fraction)) * 100))%")
    case .installing?: return progress("Installing language model…")
    case .cancelling?: return progress("Cancelling language model download…")
    case .notInstalled?:
      let issue = EmojiSearchIssue(.modelNotInstalled)
      return .init(provider: .multilingual, matches: [], failure: issue.message, issue: issue)
    case .failed(let message)?:
      return .init(
        provider: .multilingual, matches: [], failure: message,
        issue: EmojiSearchIssue(.modelNotInstalled))
    case nil:
      return .init(provider: .multilingual, matches: [], failure: unavailableMessage)
    }
  }

  static func shouldRefresh(
    previous: EmojiMultilingualModelStore.State?, current: EmojiMultilingualModelStore.State?,
    result: EmojiSearchProviderResult
  ) -> Bool {
    guard current == .ready, previous != .ready, result.provider == .multilingual else {
      return false
    }
    switch previous {
    case .checking?:
      return !result.isPending && !result.isLoading && result.issue?.kind == .modelNotInstalled
    case .installing?, .downloading?: return true
    default: return false
    }
  }

  private static func progress(_ message: String) -> EmojiSearchProviderResult {
    .init(provider: .multilingual, matches: [], isLoading: true, progressMessage: message)
  }
}
