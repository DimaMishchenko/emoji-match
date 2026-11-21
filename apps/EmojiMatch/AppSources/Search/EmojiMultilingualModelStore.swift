import Foundation
import Observation

nonisolated struct EmojiMultilingualDownloadDescriptor: Codable, Sendable, Equatable {
  struct FileIdentity: Codable, Sendable, Equatable {
    let sha256: String
    let bytes: Int64
  }

  let schema: Int
  let url: URL
  let sha256: String
  let bytes: Int64
  let modelRevision: String
  let files: [String: FileIdentity]

  func validate() throws {
    guard schema == 1, bytes > 0, bytes <= 1_073_741_824, files.count <= 128,
      modelRevision == EmojiModelResourceValidation.Profile.multilingual.revision,
      Self.isDigest(sha256), Self.acceptsDownloadURL(url),
      files["multilingual-manifest.json"] != nil, !files.isEmpty,
      Set(files.keys.map { $0.lowercased() }).count == files.count,
      files.allSatisfy({ path, identity in
        Self.isRelativeFilePath(path) && Self.isDigest(identity.sha256) && identity.bytes >= 0
          && identity.bytes <= 1_073_741_824
      })
    else { throw EmojiMultilingualModelStore.Failure.invalidDescriptor }
  }

  static func acceptsDownloadURL(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
      url.port == nil || url.port == 443,
      let host = url.host?.lowercased()
    else { return false }
    return ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"]
      .contains(host)
  }

  private static func isDigest(_ value: String) -> Bool {
    value.utf8.count == 64
      && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }

  private static func isRelativeFilePath(_ path: String) -> Bool {
    !path.isEmpty && path.utf8.allSatisfy { $0 >= 32 && $0 < 127 }
      && !path.contains("\\") && !path.contains("\0")
      && path.split(separator: "/", omittingEmptySubsequences: false)
        .allSatisfy {
          !$0.isEmpty && $0 != "." && $0 != ".."
        }
  }
}

@MainActor @Observable final class EmojiMultilingualModelStore {
  nonisolated enum Failure: Error, Equatable, LocalizedError {
    case notInstalled
    case invalidDescriptor
    case invalidDownload
    case invalidInstallation
    case downloadFailed
    case removalFailed
    case insufficientSpace

    var errorDescription: String? {
      switch self {
      case .notInstalled: "Download the multilingual model to use multilingual semantic search."
      case .invalidDescriptor: "The multilingual model download is unavailable in this app version."
      case .invalidDownload:
        "The multilingual model download could not be verified. Try downloading again."
      case .invalidInstallation:
        "The multilingual model could not be installed. Try downloading again."
      case .downloadFailed:
        "The multilingual model download failed. Check your connection and try again."
      case .insufficientSpace: "There isn’t enough disk space to install the multilingual model."
      case .removalFailed: "The multilingual model could not be removed. Try again."
      }
    }
  }

  enum State: Equatable {
    case notInstalled
    case checking
    case downloading(progress: Double)
    case installing
    case cancelling
    case ready
    case failed(String)
  }

  nonisolated struct Operations: Sendable {
    var download:
      @Sendable (EmojiMultilingualDownloadDescriptor, URL, @escaping @Sendable (Double) -> Void)
        async throws -> Void
    var install: @Sendable (URL, URL, EmojiMultilingualDownloadDescriptor) async throws -> Void
    var validate: @Sendable (URL, EmojiMultilingualDownloadDescriptor) async throws -> Void

    static var live: Self {
      Self(
        download: { descriptor, destination, progress in
          try await EmojiMultilingualModelInstallation.download(
            descriptor: descriptor, destination: destination, progress: progress)
        },
        install: { archive, destination, descriptor in
          try await EmojiMultilingualModelInstallation.install(
            archive: archive, destination: destination, descriptor: descriptor)
        },
        validate: { directory, descriptor in
          try await EmojiMultilingualModelInstallation.validate(directory, descriptor: descriptor)
        })
    }
  }

  private(set) var state: State = .notInstalled
  private let descriptor: EmojiMultilingualDownloadDescriptor
  private let root: URL
  private let operations: Operations
  @ObservationIgnored private var operation: Task<URL, Error>?
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var removing = false
  @ObservationIgnored private var readyDirectory: URL?

  init(
    descriptor: EmojiMultilingualDownloadDescriptor, applicationSupportRoot: URL,
    operations: Operations = .live
  ) throws {
    try descriptor.validate()
    self.descriptor = descriptor
    root = applicationSupportRoot
    self.operations = operations
  }

  convenience init(
    descriptorURL: URL, applicationSupportRoot: URL, operations: Operations = .live
  ) throws {
    guard descriptorURL.isFileURL else { throw Failure.invalidDescriptor }
    do {
      try self.init(
        descriptor: JSONDecoder()
          .decode(
            EmojiMultilingualDownloadDescriptor.self, from: Data(contentsOf: descriptorURL)),
        applicationSupportRoot: applicationSupportRoot, operations: operations)
    } catch {
      throw Failure.invalidDescriptor
    }
  }

  static func live(
    bundle: Bundle = .main, applicationSupportRoot: URL? = nil
  ) throws -> EmojiMultilingualModelStore {
    #if DEBUG
      guard applicationSupportRoot != nil else { throw Failure.invalidDescriptor }
    #endif
    guard
      let name = bundle.object(forInfoDictionaryKey: "EmojiMultilingualDownloadDescriptor")
        as? String,
      let descriptorURL = bundle.url(forResource: name, withExtension: "json")
    else { throw Failure.invalidDescriptor }
    let root =
      try applicationSupportRoot
      ?? FileManager.default
      .url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
      )
      .appending(path: bundle.bundleIdentifier ?? "EmojiMatch", directoryHint: .isDirectory)
      .appending(path: "Models", directoryHint: .isDirectory)
    return try Self(descriptorURL: descriptorURL, applicationSupportRoot: root)
  }

  var downloadBytes: Int64 { descriptor.bytes }

  var installedBytesEstimate: Int64 {
    descriptor.files.values.reduce(0) { $0 + $1.bytes }
      + (descriptor.files["Multilingual.mlpackage/Data/com.apple.CoreML/weights/weight.bin"]?.bytes
        ?? 0)
  }

  func availableResourceDirectory() async throws -> URL {
    guard !removing else { throw Failure.notInstalled }
    if let readyDirectory { return readyDirectory }
    if case .checking = state, let operation { return try await operation.value }
    guard operation == nil else { throw Failure.notInstalled }
    let token = UUID()
    generation = token
    state = .checking
    let directory = installationDirectory
    let descriptor = descriptor
    let validate = operations.validate
    let task = Task { () throws -> URL in
      do {
        try await Task.detached {
          guard FileManager.default.fileExists(atPath: directory.path) else {
            throw Failure.notInstalled
          }
          try Task.checkCancellation()
        }
        .value
        try await validate(directory, descriptor)
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        readyDirectory = directory
        state = .ready
        operation = nil
        return directory
      } catch {
        if generation == token {
          operation = nil
          state =
            error as? Failure == .notInstalled
            ? .notInstalled : .failed(Failure.invalidInstallation.localizedDescription)
        }
        throw error is CancellationError
          ? error : (error as? Failure ?? Failure.invalidInstallation)
      }
    }
    operation = task
    return try await task.value
  }

  func startDownload() {
    guard operation == nil, !removing else { return }
    let token = UUID()
    generation = token
    state = .downloading(progress: 0)
    let descriptor = descriptor
    let root = root
    let operations = operations
    let destination = installationDirectory
    operation = Task { [self] in
      do {
        let directory = try await Self.performDownload(
          descriptor: descriptor, root: root, destination: destination, operations: operations,
          progress: { [weak self] progress in
            Task { @MainActor [weak self] in
              guard let self, self.generation == token,
                case .downloading = self.state
              else { return }
              self.state = .downloading(progress: min(1, max(0, progress)))
            }
          },
          installing: { [weak self] in
            guard let self, self.generation == token else { return }
            self.state = .installing
          })
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        readyDirectory = directory
        state = .ready
        operation = nil
        return directory
      } catch {
        if generation == token {
          operation = nil
          if error is CancellationError {
            state = readyDirectory == nil ? .notInstalled : .ready
          } else {
            let failure = error as? Failure ?? .downloadFailed
            state = .failed(failure.localizedDescription)
          }
        }
        throw error
      }
    }
  }

  func cancel() async {
    let task = operation
    let token = UUID()
    generation = token
    task?.cancel()
    if task != nil { state = .cancelling }
    _ = try? await task?.value
    guard generation == token else { return }
    operation = nil
    state = readyDirectory == nil ? .notInstalled : .ready
  }

  func remove() async throws {
    guard !removing else { throw Failure.removalFailed }
    removing = true
    defer { removing = false }
    await cancel()
    readyDirectory = nil
    let directory = installationDirectory
    do {
      try await Task.detached {
        if FileManager.default.fileExists(atPath: directory.path) {
          try FileManager.default.removeItem(at: directory)
        }
      }
      .value
      state = .notInstalled
    } catch {
      state = .failed(Failure.removalFailed.localizedDescription)
      throw Failure.removalFailed
    }
  }

  private var installationDirectory: URL {
    root.appending(path: "Multilingual", directoryHint: .isDirectory)
  }

  private nonisolated static func performDownload(
    descriptor: EmojiMultilingualDownloadDescriptor, root: URL, destination: URL,
    operations: Operations, progress: @escaping @Sendable (Double) -> Void,
    installing: @escaping @MainActor @Sendable () -> Void
  ) async throws -> URL {
    let task = Task.detached {
      let manager = FileManager.default
      try manager.createDirectory(at: root, withIntermediateDirectories: true)
      let sourceBytes = descriptor.files.values.reduce(Int64(0)) { $0 + $1.bytes }
      let compiledBytes =
        descriptor.files["Multilingual.mlpackage/Data/com.apple.CoreML/weights/weight.bin"]?.bytes
        ?? 0
      let requiredBytes = descriptor.bytes + sourceBytes + compiledBytes + 67_108_864
      let capacity =
        try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        .volumeAvailableCapacityForImportantUsage
      if let capacity, capacity < requiredBytes { throw Failure.insufficientSpace }
      var excludedRoot = root
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try excludedRoot.setResourceValues(values)
      let temporary = root.appending(
        path: ".install-" + UUID().uuidString, directoryHint: .isDirectory)
      try manager.createDirectory(at: temporary, withIntermediateDirectories: false)
      defer { try? manager.removeItem(at: temporary) }
      let archive = temporary.appending(path: "model.zip")
      let staged = temporary.appending(path: "resources", directoryHint: .isDirectory)
      try await operations.download(descriptor, archive, progress)
      try Task.checkCancellation()
      try EmojiMultilingualModelInstallation.verifyArchive(archive, descriptor: descriptor)
      await installing()
      try await operations.install(archive, staged, descriptor)
      try await operations.validate(staged, descriptor)
      try Task.checkCancellation()
      var excludedStaged = staged
      try excludedStaged.setResourceValues(values)
      if manager.fileExists(atPath: destination.path) {
        _ = try manager.replaceItemAt(destination, withItemAt: staged)
      } else {
        try manager.moveItem(at: staged, to: destination)
      }
      return destination
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }
}
