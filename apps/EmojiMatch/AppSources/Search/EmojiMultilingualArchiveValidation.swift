import Foundation

nonisolated enum EmojiMultilingualArchiveValidation {
  private typealias Failure = EmojiMultilingualModelStore.Failure

  static func validate(_ archive: URL, descriptor: EmojiMultilingualDownloadDescriptor) throws {
    try descriptor.validate()
    let size = try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize
    guard size.map(Int64.init) == descriptor.bytes else { throw Failure.invalidInstallation }
    let data = try Data(contentsOf: archive, options: .mappedIfSafe)
    try validate(data, descriptor: descriptor)
  }

  static func validate(_ data: Data, descriptor: EmojiMultilingualDownloadDescriptor) throws {
    try descriptor.validate()
    guard Int64(data.count) == descriptor.bytes, data.count >= 22 else {
      throw Failure.invalidInstallation
    }
    let reader = Reader(data: data)
    let end = data.count - 22
    guard try reader.u32(end) == 0x0605_4b50,
      try reader.u16(end + 4) == 0, try reader.u16(end + 6) == 0,
      try reader.u16(end + 8) == descriptor.files.count,
      try reader.u16(end + 10) == descriptor.files.count,
      try reader.u16(end + 20) == 0
    else { throw Failure.invalidInstallation }
    let centralSize = try reader.u32(end + 12)
    let centralStart = try reader.u32(end + 16)
    guard centralStart <= end, centralSize == end - centralStart else {
      throw Failure.invalidInstallation
    }
    var cursor = centralStart
    var localCursor = 0
    var seen = Set<String>()
    for _ in descriptor.files {
      try Task.checkCancellation()
      guard cursor <= end - 46, try reader.u32(cursor) == 0x0201_4b50 else {
        throw Failure.invalidInstallation
      }
      let version = try reader.u16(cursor + 6)
      let flags = try reader.u16(cursor + 8)
      let method = try reader.u16(cursor + 10)
      let crc = try reader.u32(cursor + 16)
      let compressed = try reader.u32(cursor + 20)
      let expanded = try reader.u32(cursor + 24)
      let nameSize = try reader.u16(cursor + 28)
      let extraSize = try reader.u16(cursor + 30)
      let commentSize = try reader.u16(cursor + 32)
      let attributes = try reader.u32(cursor + 38)
      let offset = try reader.u32(cursor + 42)
      let unixType = (attributes >> 16) & 0xf000
      guard [10, 20, 45].contains(version), flags == 0 || flags == 0x800,
        method == 0 || method == 8, extraSize == 0, commentSize == 0,
        try reader.u16(cursor + 34) == 0,
        attributes & 0x10 == 0, unixType == 0 || unixType == 0x8000,
        nameSize > 0, nameSize <= end - cursor - 46, offset == localCursor
      else { throw Failure.invalidInstallation }
      let name = try reader.bytes(cursor + 46, nameSize)
      guard let path = String(data: name, encoding: .utf8), Data(path.utf8) == name,
        name.allSatisfy({ $0 >= 32 && $0 < 127 }),
        let identity = descriptor.files[path], Int64(expanded) == identity.bytes,
        seen.insert(path.lowercased()).inserted,
        compressed < centralStart, expanded == 0 || compressed > 0,
        method != 0 || compressed == expanded
      else { throw Failure.invalidInstallation }
      guard localCursor <= centralStart - 30,
        try reader.u32(localCursor) == 0x0403_4b50,
        try reader.u16(localCursor + 4) == version,
        try reader.u16(localCursor + 6) == flags,
        try reader.u16(localCursor + 8) == method,
        try reader.u32(localCursor + 10) == reader.u32(cursor + 12),
        try reader.u32(localCursor + 14) == crc,
        try reader.u16(localCursor + 26) == nameSize
      else { throw Failure.invalidInstallation }
      let localCompressed = try reader.u32(localCursor + 18)
      let localExpanded = try reader.u32(localCursor + 22)
      let localExtra = try reader.u16(localCursor + 28)
      guard try reader.bytes(localCursor + 30, nameSize) == name else {
        throw Failure.invalidInstallation
      }
      let extra = localCursor + 30 + nameSize
      if localCompressed == 0xffff_ffff && localExpanded == 0xffff_ffff {
        guard version == 45, localExtra == 20,
          try reader.u16(extra) == 1, try reader.u16(extra + 2) == 16,
          try reader.u64(extra + 4) == UInt64(expanded),
          try reader.u64(extra + 12) == UInt64(compressed)
        else { throw Failure.invalidInstallation }
      } else {
        guard localExtra == 0, localCompressed == compressed, localExpanded == expanded else {
          throw Failure.invalidInstallation
        }
      }
      let payload = extra + localExtra
      guard payload <= centralStart, compressed <= centralStart - payload else {
        throw Failure.invalidInstallation
      }
      localCursor = payload + compressed
      cursor += 46 + nameSize
    }
    guard cursor == end, localCursor == centralStart else {
      throw Failure.invalidInstallation
    }
  }

  private struct Reader {
    let data: Data

    func bytes(_ offset: Int, _ count: Int) throws -> Data {
      guard offset >= 0, count >= 0, offset <= data.count, count <= data.count - offset else {
        throw Failure.invalidInstallation
      }
      return data.subdata(in: offset..<(offset + count))
    }

    func u16(_ offset: Int) throws -> Int {
      let bytes = try bytes(offset, 2)
      return Int(bytes[0]) | (Int(bytes[1]) << 8)
    }

    func u32(_ offset: Int) throws -> Int {
      let bytes = try bytes(offset, 4)
      return bytes.enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset * 8)) }
    }

    func u64(_ offset: Int) throws -> UInt64 {
      let bytes = try bytes(offset, 8)
      return bytes.enumerated().reduce(0) { $0 | (UInt64($1.element) << ($1.offset * 8)) }
    }
  }
}
