import CryptoKit
import Foundation
import Testing

@testable import EmojiMatch

@MainActor @Suite struct EmojiMultilingualModelStoreTests {
  private nonisolated struct Fixture: Sendable {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let archive = Data("pinned archive".utf8)
    let files = [
      "multilingual-manifest.json": Data("manifest fixture".utf8),
      "Multilingual.mlpackage/Manifest.json": Data("package fixture".utf8),
      "licenses/LICENSE.txt": Data("license fixture".utf8)
    ]

    var descriptor: EmojiMultilingualDownloadDescriptor {
      EmojiMultilingualDownloadDescriptor(
        schema: 1,
        url: URL(string: "https://github.com/example/models/releases/download/v1/e5.zip")!,
        sha256: Self.hash(archive), bytes: Int64(archive.count),
        modelRevision: EmojiModelResourceValidation.Profile.multilingual.revision,
        files: files.mapValues { .init(sha256: Self.hash($0), bytes: Int64($0.count)) })
    }

    var installed: URL { root.appending(path: "Multilingual") }

    func writeResources(to directory: URL) throws {
      for (name, data) in files {
        let url = directory.appending(path: name)
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
      }
    }

    var operations: EmojiMultilingualModelStore.Operations {
      .init(
        download: { _, destination, progress in
          try archive.write(to: destination)
          progress(1)
        },
        install: { _, destination, _ in try writeResources(to: destination) },
        validate: { directory, descriptor in
          try EmojiMultilingualModelInstallation.validateInventory(
            directory, descriptor: descriptor, compiledAllowed: false)
        })
    }

    func clean() { try? FileManager.default.removeItem(at: root) }

    func temporaryItems() throws -> [String] {
      guard FileManager.default.fileExists(atPath: root.path) else { return [] }
      return try FileManager.default.contentsOfDirectory(atPath: root.path)
        .filter { $0.hasPrefix(".install-") }
    }

    static func hash(_ data: Data) -> String {
      SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
  }

  private actor Gate {
    private(set) var calls = 0
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
      calls += 1
      if released { return }
      await withCheckedContinuation { continuation = $0 }
    }

    func release() {
      released = true
      continuation?.resume()
      continuation = nil
    }
  }

  private func waitUntil(_ predicate: () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !(await predicate()) {
      guard ContinuousClock.now < deadline else { throw WaitFailure.timeout }
      try await Task.sleep(for: .milliseconds(2))
    }
  }

  private enum WaitFailure: Error { case timeout }

  private func waitForCompletion(_ store: EmojiMultilingualModelStore) async throws {
    try await waitUntil {
      switch store.state {
      case .checking, .downloading, .installing, .cancelling: false
      default: true
      }
    }
  }

  @Test func initializationAndAbsentLookupNeverDownload() async throws {
    let fixture = Fixture()
    defer { fixture.clean() }
    var operations = fixture.operations
    operations.download = { _, _, _ in Issue.record("Lookup attempted a network download") }
    let store = try EmojiMultilingualModelStore(
      descriptor: fixture.descriptor, applicationSupportRoot: fixture.root, operations: operations)
    #expect(store.state == .notInstalled)
    #expect(!FileManager.default.fileExists(atPath: fixture.root.path))
    await #expect(throws: EmojiMultilingualModelStore.Failure.notInstalled) {
      _ = try await store.availableResourceDirectory()
    }
    #expect(store.state == .notInstalled)
  }

  @Test func descriptorURLMustBeLocalAndFailuresAreOwned() throws {
    let fixture = Fixture()
    defer { fixture.clean() }
    #expect(throws: EmojiMultilingualModelStore.Failure.invalidDescriptor) {
      _ = try EmojiMultilingualModelStore(
        descriptorURL: fixture.descriptor.url, applicationSupportRoot: fixture.root,
        operations: fixture.operations)
    }
    try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
    let descriptorURL = fixture.root.appending(path: "descriptor.json")
    try Data("invalid".utf8).write(to: descriptorURL)
    #expect(throws: EmojiMultilingualModelStore.Failure.invalidDescriptor) {
      _ = try EmojiMultilingualModelStore(
        descriptorURL: descriptorURL, applicationSupportRoot: fixture.root,
        operations: fixture.operations)
    }
    try JSONEncoder().encode(fixture.descriptor).write(to: descriptorURL)
    let store = try EmojiMultilingualModelStore(
      descriptorURL: descriptorURL, applicationSupportRoot: fixture.root,
      operations: fixture.operations)
    #expect(store.state == .notInstalled)
  }

  @Test func explicitDownloadInstallsOfflineAndCleansTemporaryFiles() async throws {
    let fixture = Fixture()
    defer { fixture.clean() }
    let store = try EmojiMultilingualModelStore(
      descriptor: fixture.descriptor, applicationSupportRoot: fixture.root,
      operations: fixture.operations)
    store.startDownload()
    try await waitForCompletion(store)
    #expect(store.state == .ready)
    #expect(try await store.availableResourceDirectory().path == fixture.installed.path)
    #expect(try fixture.temporaryItems().isEmpty)
    #expect(
      try fixture.installed.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        == true)
    let reopened = try EmojiMultilingualModelStore(
      descriptor: fixture.descriptor, applicationSupportRoot: fixture.root,
      operations: fixture.operations)
    #expect(try await reopened.availableResourceDirectory().path == fixture.installed.path)
    #expect(reopened.state == .ready)
  }

  @Test func concurrentLookupsShareExistingInstallationCheck() async throws {
    let fixture = Fixture()
    defer { fixture.clean() }
    try fixture.writeResources(to: fixture.installed)
    let gate = Gate()
    var operations = fixture.operations
    operations.validate = { _, _ in await gate.wait() }
    let store = try EmojiMultilingualModelStore(
      descriptor: fixture.descriptor, applicationSupportRoot: fixture.root, operations: operations)
    let first = Task { try await store.availableResourceDirectory() }
    try await waitUntil { await gate.calls == 1 }
    let second = Task { try await store.availableResourceDirectory() }
    await Task.yield()
    #expect(store.state == .checking)
    await gate.release()
    #expect(try await first.value.path == fixture.installed.path)
    #expect(try await second.value.path == fixture.installed.path)
    #expect(await gate.calls == 1)
  }

  @Test func repeatedDownloadStartsOnlyOneOperation() async throws {
    let fixture = Fixture()
    defer { fixture.clean() }
    let gate = Gate()
    var operations = fixture.operations
    operations.download = { _, destination, _ in
      await gate.wait()
      try Task.checkCancellation()
      try fixture.archive.write(to: destination)
    }
    let store = try EmojiMultilingualModelStore(
      descriptor: fixture.descriptor, applicationSupportRoot: fixture.root, operations: operations)
    store.startDownload()
    try await waitUntil { await gate.calls == 1 }
    store.startDownload()
    await #expect(throws: EmojiMultilingualModelStore.Failure.notInstalled) {
      _ = try await store.availableResourceDirectory()
    }
    await gate.release()
    try await waitForCompletion(store)
    #expect(await gate.calls == 1)
    #expect(store.state == .ready)
  }

  @Test func archiveHashMismatchNeverReachesExtraction() async throws {
    let fixture = Fixture()
    defer { fixture.clean() }
    var operations = fixture.operations
    operations.download = { _, destination, _ in
      try Data(repeating: 120, count: fixture.archive.count).write(to: destination)
    }
    operations.install = { _, _, _ in Issue.record("Unverified archive reached extraction") }
    let store = try EmojiMultilingualModelStore(
      descriptor: fixture.descriptor, applicationSupportRoot: fixture.root, operations: operations)
    store.startDownload()
    try await waitForCompletion(store)
    #expect(
      store.state
        == .failed(EmojiMultilingualModelStore.Failure.invalidDownload.localizedDescription))
    #expect(try fixture.temporaryItems().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: fixture.installed.path))
  }

  @Test func oversizedAndTruncatedArchivesAreRejected() throws {
    let fixture = Fixture()
    defer { fixture.clean() }
    try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
    let archive = fixture.root.appending(path: "archive")
    for count in [fixture.archive.count - 1, fixture.archive.count + 1] {
      try Data(repeating: 120, count: count).write(to: archive)
      #expect(throws: EmojiMultilingualModelStore.Failure.invalidDownload) {
        try EmojiMultilingualModelInstallation.verifyArchive(
          archive, descriptor: fixture.descriptor)
      }
    }
  }

  @Test func failedReplacementPreservesPreviousInstallation() async throws {
    let fixture = Fixture()
    defer { fixture.clean() }
    try fixture.writeResources(to: fixture.installed)
    var operations = fixture.operations
    operations.install = { _, destination, _ in
      try fixture.writeResources(to: destination)
      throw EmojiMultilingualModelStore.Failure.invalidInstallation
    }
    let store = try EmojiMultilingualModelStore(
      descriptor: fixture.descriptor, applicationSupportRoot: fixture.root, operations: operations)
    _ = try await store.availableResourceDirectory()
    store.startDownload()
    try await waitForCompletion(store)
    #expect(
      store.state
        == .failed(EmojiMultilingualModelStore.Failure.invalidInstallation.localizedDescription))
    #expect(try await store.availableResourceDirectory().path == fixture.installed.path)
    try EmojiMultilingualModelInstallation.validateInventory(
      fixture.installed, descriptor: fixture.descriptor, compiledAllowed: false)
    #expect(try fixture.temporaryItems().isEmpty)
  }

  @Test func successfulReplacementIsTransactional() async throws {
    let fixture = Fixture()
    defer { fixture.clean() }
    try fixture.writeResources(to: fixture.installed)
    let store = try EmojiMultilingualModelStore(
      descriptor: fixture.descriptor, applicationSupportRoot: fixture.root,
      operations: fixture.operations)
    _ = try await store.availableResourceDirectory()
    store.startDownload()
    try await waitForCompletion(store)
    #expect(store.state == .ready)
    try EmojiMultilingualModelInstallation.validateInventory(
      fixture.installed, descriptor: fixture.descriptor, compiledAllowed: false)
    #expect(try fixture.temporaryItems().isEmpty)
  }

  @Test func cancellationPreservesOldInstallAndCleansStaging() async throws {
    let fixture = Fixture()
    defer { fixture.clean() }
    try fixture.writeResources(to: fixture.installed)
    let gate = Gate()
    var operations = fixture.operations
    operations.install = { _, destination, _ in
      try fixture.writeResources(to: destination)
      await gate.wait()
      try Task.checkCancellation()
    }
    let store = try EmojiMultilingualModelStore(
      descriptor: fixture.descriptor, applicationSupportRoot: fixture.root, operations: operations)
    _ = try await store.availableResourceDirectory()
    store.startDownload()
    try await waitUntil { await gate.calls == 1 }
    let cancellation = Task { await store.cancel() }
    await Task.yield()
    await gate.release()
    await cancellation.value
    #expect(store.state == .ready)
    try EmojiMultilingualModelInstallation.validateInventory(
      fixture.installed, descriptor: fixture.descriptor, compiledAllowed: false)
    #expect(try fixture.temporaryItems().isEmpty)
  }

  @Test func removalWaitsForCancellationAndPreventsResurrection() async throws {
    let fixture = Fixture()
    defer { fixture.clean() }
    try fixture.writeResources(to: fixture.installed)
    let gate = Gate()
    var operations = fixture.operations
    operations.download = { _, destination, progress in
      await gate.wait()
      progress(1)
      try fixture.archive.write(to: destination)
    }
    let store = try EmojiMultilingualModelStore(
      descriptor: fixture.descriptor, applicationSupportRoot: fixture.root, operations: operations)
    _ = try await store.availableResourceDirectory()
    store.startDownload()
    try await waitUntil { await gate.calls == 1 }
    let removal = Task { try await store.remove() }
    await Task.yield()
    store.startDownload()
    await gate.release()
    try await removal.value
    #expect(store.state == .notInstalled)
    #expect(!FileManager.default.fileExists(atPath: fixture.installed.path))
    #expect(try fixture.temporaryItems().isEmpty)
    #expect(await gate.calls == 1)
  }

  @Test func inventoryRejectsUnexpectedMissingAndChangedFiles() throws {
    let fixture = Fixture()
    defer { fixture.clean() }
    try fixture.writeResources(to: fixture.installed)
    let extra = fixture.installed.appending(path: "unexpected")
    try Data().write(to: extra)
    #expect(throws: (any Error).self) {
      try EmojiMultilingualModelInstallation.validateInventory(
        fixture.installed, descriptor: fixture.descriptor, compiledAllowed: false)
    }
    try FileManager.default.removeItem(at: extra)
    let manifest = fixture.installed.appending(path: "multilingual-manifest.json")
    try Data(repeating: 120, count: fixture.files["multilingual-manifest.json"]!.count)
      .write(to: manifest)
    #expect(throws: (any Error).self) {
      try EmojiMultilingualModelInstallation.validateInventory(
        fixture.installed, descriptor: fixture.descriptor, compiledAllowed: false)
    }
    try FileManager.default.removeItem(at: manifest)
    #expect(throws: (any Error).self) {
      try EmojiMultilingualModelInstallation.validateInventory(
        fixture.installed, descriptor: fixture.descriptor, compiledAllowed: false)
    }
  }

  @Test func inventoryRejectsFileDirectoryAndRootSymlinks() throws {
    let fixture = Fixture()
    defer { fixture.clean() }
    try fixture.writeResources(to: fixture.installed)
    let manifest = fixture.installed.appending(path: "multilingual-manifest.json")
    try FileManager.default.removeItem(at: manifest)
    try FileManager.default.createSymbolicLink(
      at: manifest, withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
    #expect(throws: (any Error).self) {
      try EmojiMultilingualModelInstallation.validateInventory(
        fixture.installed, descriptor: fixture.descriptor, compiledAllowed: false)
    }
    try FileManager.default.removeItem(at: manifest)
    try fixture.writeResources(to: fixture.installed)
    let directory = fixture.installed.appending(path: "licenses")
    try FileManager.default.removeItem(at: directory)
    try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: fixture.root)
    #expect(throws: (any Error).self) {
      try EmojiMultilingualModelInstallation.validateInventory(
        fixture.installed, descriptor: fixture.descriptor, compiledAllowed: false)
    }
    let rootLink = fixture.root.appending(path: "linked")
    try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: fixture.installed)
    #expect(throws: (any Error).self) {
      try EmojiMultilingualModelInstallation.validateInventory(
        rootLink, descriptor: fixture.descriptor, compiledAllowed: false)
    }
  }

  @Test func descriptorRejectsTraversalAndUnapprovedURLs() throws {
    let fixture = Fixture()
    let data = try JSONEncoder().encode(fixture.descriptor)
    let base = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    for path in ["../escape", "/absolute", "a/../escape", "a//file", "a\\file", "./file", "a/"] {
      var object = base
      var files = try #require(base["files"] as? [String: Any])
      files[path] = ["sha256": fixture.descriptor.sha256, "bytes": 1]
      object["files"] = files
      let descriptor = try JSONDecoder()
        .decode(
          EmojiMultilingualDownloadDescriptor.self,
          from: JSONSerialization.data(withJSONObject: object))
      #expect(throws: EmojiMultilingualModelStore.Failure.invalidDescriptor) {
        try descriptor.validate()
      }
    }
    for url in [
      "http://github.com/a", "https://evil.example/a", "https://github.com.evil.example/a",
      "https://user:password@github.com/a", "https://github.com:444/a"
    ] {
      #expect(!EmojiMultilingualDownloadDescriptor.acceptsDownloadURL(URL(string: url)!))
    }
    for url in [
      "https://github.com/a", "https://release-assets.githubusercontent.com/a?signature=value",
      "https://objects.githubusercontent.com/a"
    ] {
      #expect(EmojiMultilingualDownloadDescriptor.acceptsDownloadURL(URL(string: url)!))
    }
  }

  @Test func responseRejectsStatusRedirectHostAndFalseContentLength() throws {
    let fixture = Fixture()
    for (url, status, headers) in [
      (fixture.descriptor.url, 404, [String: String]()),
      (URL(string: "https://evil.example/a")!, 200, [:]),
      (fixture.descriptor.url, 200, ["Content-Length": "999"]),
      (fixture.descriptor.url, 200, ["Content-Length": "invalid"])
    ] {
      let response = try #require(
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers))
      #expect(throws: EmojiMultilingualModelStore.Failure.invalidDownload) {
        try EmojiMultilingualModelInstallation.validateResponse(
          response, descriptor: fixture.descriptor)
      }
    }
    for headers in [[:], ["Content-Length": String(fixture.archive.count)]] {
      let response = try #require(
        HTTPURLResponse(
          url: fixture.descriptor.url, statusCode: 200, httpVersion: nil, headerFields: headers))
      try EmojiMultilingualModelInstallation.validateResponse(
        response, descriptor: fixture.descriptor)
    }
  }

  @Test func streamingWriterRejectsOverflowAndTruncationWithoutWritingBeyondPin() async throws {
    let fixture = Fixture()
    defer { fixture.clean() }
    try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
    let destination = fixture.root.appending(path: "stream")
    for count in [fixture.archive.count - 1, fixture.archive.count + 1] {
      let stream = AsyncStream<UInt8> { continuation in
        for _ in 0..<count { continuation.yield(120) }
        continuation.finish()
      }
      await #expect(throws: EmojiMultilingualModelStore.Failure.invalidDownload) {
        try await EmojiMultilingualModelInstallation.write(
          stream, descriptor: fixture.descriptor, destination: destination, progress: { _ in })
      }
      let size = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize
      #expect(try #require(size) <= fixture.archive.count)
    }
    let stream = AsyncStream<UInt8> { continuation in
      for byte in fixture.archive { continuation.yield(byte) }
      continuation.finish()
    }
    try await EmojiMultilingualModelInstallation.write(
      stream, descriptor: fixture.descriptor, destination: destination, progress: { _ in })
    try EmojiMultilingualModelInstallation.verifyArchive(
      destination, descriptor: fixture.descriptor)
  }

  @Test func streamingWriterHonorsCancellation() async throws {
    let fixture = Fixture()
    defer { fixture.clean() }
    try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
    let stream = AsyncStream<UInt8> { continuation in
      continuation.yield(120)
      continuation.finish()
    }
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      try await EmojiMultilingualModelInstallation.write(
        stream, descriptor: fixture.descriptor, destination: fixture.root.appending(path: "stream"),
        progress: { _ in })
    }
    await #expect(throws: CancellationError.self) { try await task.value }
  }

  @Test func rawTransportFailureUsesOwnedMessageAndCleansFiles() async throws {
    let fixture = Fixture()
    defer { fixture.clean() }
    var operations = fixture.operations
    operations.download = { _, destination, _ in
      try Data("partial".utf8).write(to: destination)
      throw NSError(domain: "secret-url-query", code: 42)
    }
    let store = try EmojiMultilingualModelStore(
      descriptor: fixture.descriptor, applicationSupportRoot: fixture.root, operations: operations)
    store.startDownload()
    try await waitForCompletion(store)
    #expect(
      store.state
        == .failed(EmojiMultilingualModelStore.Failure.downloadFailed.localizedDescription))
    #expect(try fixture.temporaryItems().isEmpty)
  }
}

extension EmojiMultilingualModelStoreTests {
  private nonisolated struct ZIPFixture {
    var data = Data()
    var localHeaders: [Int] = []
    var centralHeaders: [Int] = []
    var centralStart = 0

    init(files: [String: Data], zip64: Bool = false, renaming: [String: String] = [:]) {
      var directory = Data()
      for (path, contents) in files.sorted(by: { $0.key < $1.key }) {
        let name = Data((renaming[path] ?? path).utf8)
        let offset = data.count
        localHeaders.append(offset)
        let version = zip64 ? 45 : 20
        let crc = Self.crc32(contents)
        data.appendLE(0x0403_4b50, width: 4)
        for value in [version, 0, 0, 0, 0] { data.appendLE(value, width: 2) }
        data.appendLE(crc, width: 4)
        for _ in 0..<2 { data.appendLE(zip64 ? 0xffff_ffff : contents.count, width: 4) }
        data.appendLE(name.count, width: 2)
        data.appendLE(zip64 ? 20 : 0, width: 2)
        data.append(name)
        if zip64 {
          data.appendLE(1, width: 2)
          data.appendLE(16, width: 2)
          for _ in 0..<2 { data.appendLE(contents.count, width: 8) }
        }
        data.append(contents)
        centralHeaders.append(directory.count)
        directory.appendLE(0x0201_4b50, width: 4)
        for value in [0x0314, version, 0, 0, 0, 0] { directory.appendLE(value, width: 2) }
        directory.appendLE(crc, width: 4)
        for _ in 0..<2 { directory.appendLE(contents.count, width: 4) }
        for value in [name.count, 0, 0, 0, 0] { directory.appendLE(value, width: 2) }
        directory.appendLE(0x81a4_0000, width: 4)
        directory.appendLE(offset, width: 4)
        directory.append(name)
      }
      centralStart = data.count
      centralHeaders = centralHeaders.map { $0 + centralStart }
      data.append(directory)
      data.appendLE(0x0605_4b50, width: 4)
      for value in [0, 0, files.count, files.count] { data.appendLE(value, width: 2) }
      data.appendLE(directory.count, width: 4)
      data.appendLE(centralStart, width: 4)
      data.appendLE(0, width: 2)
    }

    private static func crc32(_ data: Data) -> Int {
      var crc: UInt32 = 0xffff_ffff
      for byte in data {
        crc ^= UInt32(byte)
        for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb8_8320 : 0) }
      }
      return Int(crc ^ 0xffff_ffff)
    }
  }

  private func archiveDescriptor(
    _ data: Data, files: [String: Data]
  ) -> EmojiMultilingualDownloadDescriptor {
    let fixture = Fixture()
    return .init(
      schema: 1, url: fixture.descriptor.url, sha256: Fixture.hash(data), bytes: Int64(data.count),
      modelRevision: fixture.descriptor.modelRevision,
      files: files.mapValues { .init(sha256: Fixture.hash($0), bytes: Int64($0.count)) })
  }

  @Test func archiveAcceptsStoredAndLocalZIP64Layouts() throws {
    let files = Fixture().files
    for zip64 in [false, true] {
      let zip = ZIPFixture(files: files, zip64: zip64)
      try EmojiMultilingualArchiveValidation.validate(
        zip.data, descriptor: archiveDescriptor(zip.data, files: files))
    }
  }

  @Test func archiveRejectsAlternateInventoriesAndUnsupportedHeaders() throws {
    let files = Fixture().files
    let original = ZIPFixture(files: files)
    let local = original.localHeaders[0]
    let central = original.centralHeaders[0]
    let mutations: [(Int, Int, Int)] = [
      (local + 30, 46, 1),  // local name differs from the central name
      (central + 46, 46, 1),  // unlisted path
      (central + 38, 0xa1ff_0000, 4),  // Unix symlink
      (central + 38, 0x41ed_0010, 4),  // directory
      (central + 8, 1, 2),  // encryption
      (central + 8, 8, 2),  // trailing data descriptor
      (central + 10, 12, 2),  // unsupported compression
      (central + 30, 1, 2),  // extras can encode alternate names
      (central + 34, 1, 2),  // second volume
      (central + 42, 1, 4),  // hidden leading local data
      (central + 20, original.data.count, 4),  // payload crosses central directory
      (central + 24, 999_999_999, 4),  // declared expansion differs from descriptor
      (local + 22, 999_999_999, 4),  // local expansion differs from central
      (local + 14, 1, 4),  // CRC mismatch
      (original.data.count - 12, files.count + 1, 2),  // entry count
      (original.data.count - 18, 1, 2)  // EOCD volume
    ]
    for (offset, value, width) in mutations {
      var data = original.data
      data.replaceLE(at: offset, value: value, width: width)
      #expect(throws: EmojiMultilingualModelStore.Failure.invalidInstallation) {
        try EmojiMultilingualArchiveValidation.validate(
          data, descriptor: archiveDescriptor(data, files: files))
      }
    }
    for length in [0, 21, original.centralStart, original.data.count - 1] {
      let data = original.data.prefix(length)
      #expect(throws: EmojiMultilingualModelStore.Failure.invalidInstallation) {
        try EmojiMultilingualArchiveValidation.validate(
          Data(data), descriptor: archiveDescriptor(original.data, files: files))
      }
    }
  }

  @Test func archiveRejectsMalformedLocalZIP64Sizes() throws {
    let files = Fixture().files
    let original = ZIPFixture(files: files, zip64: true)
    let local = original.localHeaders[0]
    let nameSize = Int(original.data[local + 26]) | (Int(original.data[local + 27]) << 8)
    let extra = local + 30 + nameSize
    for (offset, value, width) in [
      (local + 28, 0, 2), (extra, 0x7075, 2), (extra + 2, 8, 2),
      (extra + 4, 999_999, 8), (extra + 12, 999_999, 8),
      (local + 18, 1, 4)
    ] {
      var data = original.data
      data.replaceLE(at: offset, value: value, width: width)
      #expect(throws: EmojiMultilingualModelStore.Failure.invalidInstallation) {
        try EmojiMultilingualArchiveValidation.validate(
          data, descriptor: archiveDescriptor(data, files: files))
      }
    }
  }

  @Test func archiveRejectsTraversalDuplicatesAndUndeclaredLocalEntries() throws {
    let contents = Data([1])
    let expected = ["multilingual-manifest.json": contents, "first": contents, "second": contents]
    for path in ["../escape", "/absolute", "a/../escape", "a\\file", "first"] {
      let zip = ZIPFixture(files: expected, renaming: ["second": path])
      #expect(throws: EmojiMultilingualModelStore.Failure.invalidInstallation) {
        try EmojiMultilingualArchiveValidation.validate(
          zip.data, descriptor: archiveDescriptor(zip.data, files: expected))
      }
    }
    let files = ["multilingual-manifest.json": contents, "another-manifest-file.json": contents]
    var zip = ZIPFixture(files: files)
    zip.data.replaceLE(at: zip.centralHeaders[1] + 42, value: 0, width: 4)
    #expect(throws: EmojiMultilingualModelStore.Failure.invalidInstallation) {
      try EmojiMultilingualArchiveValidation.validate(
        zip.data, descriptor: archiveDescriptor(zip.data, files: files))
    }
  }

  @Test func unexpectedHighlyCompressedExpansionIsRejectedBeforeExtraction() async throws {
    let fixture = Fixture()
    defer { fixture.clean() }
    try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
    let name = "multilingual-manifest.json"
    let contents = Data(repeating: 0, count: 2_000_000)
    try contents.write(to: fixture.root.appending(path: name))
    let archive = fixture.root.appending(path: "bomb.zip")
    let zip = Process()
    zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    zip.currentDirectoryURL = fixture.root
    zip.arguments = ["-q", "-X", archive.path, name]
    try await EmojiMultilingualModelInstallation.runExtraction(zip)
    let data = try Data(contentsOf: archive)
    #expect(data.count < contents.count / 100)
    try EmojiMultilingualArchiveValidation.validate(
      data, descriptor: archiveDescriptor(data, files: [name: contents]))
    let descriptor = archiveDescriptor(data, files: [name: Data([0])])
    let destination = fixture.root.appending(path: "extracted")
    await #expect(throws: EmojiMultilingualModelStore.Failure.invalidInstallation) {
      try await EmojiMultilingualModelInstallation.install(
        archive: archive, destination: destination, descriptor: descriptor)
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
  }

  @Test func extractionCancellationReapsOnlyOwnedProcess() async throws {
    let owned = Process()
    owned.executableURL = URL(fileURLWithPath: "/bin/sleep")
    owned.arguments = ["30"]
    let unrelated = Process()
    unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep")
    unrelated.arguments = ["30"]
    try unrelated.run()
    defer {
      if owned.isRunning { owned.terminate(); owned.waitUntilExit() }
      if unrelated.isRunning { unrelated.terminate(); unrelated.waitUntilExit() }
    }
    let task = Task { try await EmojiMultilingualModelInstallation.runExtraction(owned) }
    try await waitUntil { owned.isRunning }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(!owned.isRunning)
    #expect(unrelated.isRunning)
    #expect(owned.terminationReason == .uncaughtSignal)
  }

  @Test func extractionCancelledBeforeLaunchNeverStartsProcess() async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["30"]
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      try await EmojiMultilingualModelInstallation.runExtraction(process)
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(process.processIdentifier == 0)
  }

  @Test func restartIsBlockedUntilCancelledInstallationFinishesCleanup() async throws {
    let fixture = Fixture()
    defer { fixture.clean() }
    let gate = Gate()
    var operations = fixture.operations
    operations.install = { _, destination, _ in
      try fixture.writeResources(to: destination)
      await gate.wait()
      try Task.checkCancellation()
    }
    let store = try EmojiMultilingualModelStore(
      descriptor: fixture.descriptor, applicationSupportRoot: fixture.root, operations: operations)
    store.startDownload()
    try await waitUntil { await gate.calls == 1 }
    let cancellation = Task { await store.cancel() }
    try await waitUntil { store.state == .cancelling }
    store.startDownload()
    #expect(store.state == .cancelling)
    #expect(await gate.calls == 1)
    #expect(try fixture.temporaryItems().count == 1)
    await gate.release()
    await cancellation.value
    #expect(store.state == .notInstalled)
    #expect(try fixture.temporaryItems().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: fixture.installed.path))
    store.startDownload()
    try await waitForCompletion(store)
    #expect(store.state == .ready)
    #expect(await gate.calls == 2)
  }
}

extension Data {
  fileprivate nonisolated mutating func appendLE(_ value: Int, width: Int) {
    for shift in 0..<width { append(UInt8(truncatingIfNeeded: value >> (shift * 8))) }
  }

  fileprivate nonisolated mutating func replaceLE(at offset: Int, value: Int, width: Int) {
    var bytes = Data()
    bytes.appendLE(value, width: width)
    replaceSubrange(offset..<(offset + width), with: bytes)
  }
}
