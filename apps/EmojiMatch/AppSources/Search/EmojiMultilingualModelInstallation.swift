import CoreML
import CryptoKit
import Foundation

nonisolated enum EmojiMultilingualModelInstallation {
  private typealias Failure = EmojiMultilingualModelStore.Failure

  @concurrent static func download(
    descriptor: EmojiMultilingualDownloadDescriptor, destination: URL,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws {
    try descriptor.validate()
    let delegate = RedirectPolicy()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.timeoutIntervalForRequest = 60
    configuration.timeoutIntervalForResource = 1800
    let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: descriptor.url)
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    let (bytes, response) = try await session.bytes(for: request)
    try validateResponse(response, descriptor: descriptor)
    try await write(bytes, descriptor: descriptor, destination: destination, progress: progress)
  }

  @concurrent static func write<Bytes: AsyncSequence & Sendable>(
    _ bytes: Bytes, descriptor: EmojiMultilingualDownloadDescriptor, destination: URL,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws where Bytes.Element == UInt8 {
    guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
      throw Failure.downloadFailed
    }
    let file = try FileHandle(forWritingTo: destination)
    defer { try? file.close() }
    var chunk = Data()
    chunk.reserveCapacity(65_536)
    var count: Int64 = 0
    var lastPercent = -1
    for try await byte in bytes {
      try Task.checkCancellation()
      guard count < descriptor.bytes else { throw Failure.invalidDownload }
      chunk.append(byte)
      count += 1
      if chunk.count == 65_536 {
        try file.write(contentsOf: chunk)
        chunk.removeAll(keepingCapacity: true)
        let percent = Int(Double(count) / Double(descriptor.bytes) * 100)
        if percent != lastPercent {
          lastPercent = percent
          progress(Double(count) / Double(descriptor.bytes))
        }
      }
    }
    try Task.checkCancellation()
    try file.write(contentsOf: chunk)
    guard count == descriptor.bytes else { throw Failure.invalidDownload }
    progress(1)
  }

  static func validateResponse(
    _ response: URLResponse, descriptor: EmojiMultilingualDownloadDescriptor
  ) throws {
    guard let response = response as? HTTPURLResponse,
      response.statusCode == 200, let url = response.url,
      EmojiMultilingualDownloadDescriptor.acceptsDownloadURL(url)
    else { throw Failure.invalidDownload }
    if let length = response.value(forHTTPHeaderField: "Content-Length") {
      guard Int64(length) == descriptor.bytes else { throw Failure.invalidDownload }
    }
  }

  static func verifyArchive(_ archive: URL, descriptor: EmojiMultilingualDownloadDescriptor) throws
  {
    try verifyFile(archive, identity: .init(sha256: descriptor.sha256, bytes: descriptor.bytes))
  }

  @concurrent static func install(
    archive: URL, destination: URL, descriptor: EmojiMultilingualDownloadDescriptor
  ) async throws {
    try Task.checkCancellation()
    try EmojiMultilingualArchiveValidation.validate(archive, descriptor: descriptor)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = ["-x", "-k", "--noqtn", archive.path, destination.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try await runExtraction(process)
    try Task.checkCancellation()
    try validateInventory(destination, descriptor: descriptor, compiledAllowed: false)
    try EmojiModelResourceValidation.validate(directory: destination, profile: .multilingual)
    let compiled = try await MLModel.compileModel(
      at: destination.appending(path: "Multilingual.mlpackage"))
    defer { try? FileManager.default.removeItem(at: compiled) }
    try Task.checkCancellation()
    let configuration = MLModelConfiguration()
    configuration.computeUnits = .cpuOnly
    let model = try MLModel(contentsOf: compiled, configuration: configuration)
    guard let metadata = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String],
      metadata["revision"] == descriptor.modelRevision
    else { throw Failure.invalidInstallation }
    try FileManager.default.moveItem(
      at: compiled, to: destination.appending(path: "Multilingual.mlmodelc"))
  }

  @concurrent static func runExtraction(_ process: Process) async throws {
    let extraction = Extraction(process: process)
    try await withTaskCancellationHandler {
      try extraction.start()
      process.waitUntilExit()
      try Task.checkCancellation()
      guard process.terminationStatus == 0 else { throw Failure.invalidInstallation }
    } onCancel: {
      extraction.cancel()
    }
  }

  private final class Extraction: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var cancelled = false

    init(process: Process) { self.process = process }

    func start() throws {
      lock.lock()
      defer { lock.unlock() }
      guard !cancelled else { throw CancellationError() }
      try process.run()
    }

    func cancel() {
      lock.lock()
      defer { lock.unlock() }
      cancelled = true
      if process.isRunning { process.terminate() }
    }
  }

  @concurrent static func validate(
    _ directory: URL, descriptor: EmojiMultilingualDownloadDescriptor
  ) async throws {
    try descriptor.validate()
    try validateInventory(directory, descriptor: descriptor, compiledAllowed: true)
    try EmojiModelResourceValidation.validate(directory: directory, profile: .multilingual)
  }

  static func validateInventory(
    _ directory: URL, descriptor: EmojiMultilingualDownloadDescriptor, compiledAllowed: Bool
  ) throws {
    let manager = FileManager.default
    let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]
    let rootValues = try directory.resourceValues(forKeys: keys)
    guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true,
      let enumerator = manager.enumerator(atPath: directory.path)
    else { throw Failure.invalidInstallation }
    var seen = Set<String>()
    let expectedDirectories = Set(
      descriptor.files.keys.flatMap { path in
        let parts = path.split(separator: "/")
        return (1..<parts.count).map { parts.prefix($0).joined(separator: "/") }
      })
    for case let path as String in enumerator {
      try Task.checkCancellation()
      let file = directory.appending(path: path)
      let values = try file.resourceValues(forKeys: keys)
      guard values.isSymbolicLink != true else { throw Failure.invalidInstallation }
      let generated =
        compiledAllowed
        && (path == "Multilingual.mlmodelc" || path.hasPrefix("Multilingual.mlmodelc/"))
      if values.isDirectory == true {
        guard generated || expectedDirectories.contains(path) else {
          throw Failure.invalidInstallation
        }
      } else {
        guard values.isRegularFile == true else { throw Failure.invalidInstallation }
        if generated { continue }
        guard let identity = descriptor.files[path] else { throw Failure.invalidInstallation }
        try verifyFile(file, identity: identity)
        seen.insert(path)
      }
    }
    guard seen == Set(descriptor.files.keys) else { throw Failure.invalidInstallation }
  }

  private static func verifyFile(
    _ url: URL, identity: EmojiMultilingualDownloadDescriptor.FileIdentity
  ) throws {
    let size = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
    )
    guard size.isRegularFile == true, size.isSymbolicLink != true,
      size.fileSize.map(Int64.init) == identity.bytes
    else { throw Failure.invalidDownload }
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    var hash = SHA256()
    var count: Int64 = 0
    while let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty {
      try Task.checkCancellation()
      count += Int64(chunk.count)
      guard count <= identity.bytes else { throw Failure.invalidDownload }
      hash.update(data: chunk)
    }
    guard count == identity.bytes,
      hash.finalize().map({ String(format: "%02x", $0) }).joined() == identity.sha256
    else { throw Failure.invalidDownload }
  }

  private final class RedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
      _ session: URLSession, task: URLSessionTask,
      willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
      completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
      completionHandler(
        request.url.map(EmojiMultilingualDownloadDescriptor.acceptsDownloadURL) == true
          ? request : nil)
    }
  }
}
