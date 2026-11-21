import Foundation
import Testing

@testable import EmojiKit

@Suite struct EmojiKitTests {
  @Test func parserRejectsDuplicateIDsAndMalformedVersions() throws {
    let header = "# group: Smileys & Emotion\n# subgroup: face-smiling\n"
    let line = "1F600 ; fully-qualified # 😀 E1.0 grinning face\n"
    #expect(throws: (any Error).self) {
      try UnicodeEmojiParser.parseEmojiTest(Data((header + line + line).utf8))
    }
    for invalid in ["Ebad grinning face", "E1.0", "E1 grinning face"] {
      #expect(throws: (any Error).self) {
        try UnicodeEmojiParser.parseEmojiTest(
          Data((header + "1F600 ; fully-qualified # 😀 " + invalid).utf8))
      }
    }
  }

  @Test func parserKeepsVariantOrderAndMultipleToneSlots() throws {
    let fixture = """
      # group: People & Body
      # subgroup: hands
      1F91D ; fully-qualified # 🤝 E3.0 handshake
      1FAF1 1F3FF 200D 1FAF2 1F3FB ; fully-qualified # 🫱🏿‍🫲🏻 E14.0 handshake: dark skin tone, light skin tone
      1FAF1 1F3FB 200D 1FAF2 1F3FF ; fully-qualified # 🫱🏻‍🫲🏿 E14.0 handshake: light skin tone, dark skin tone
      """
    let first = try UnicodeEmojiParser.parseEmojiTest(Data(fixture.utf8))
    #expect(first == (try UnicodeEmojiParser.parseEmojiTest(Data(fixture.utf8))))
    #expect(first.count == 1)
    #expect(first[0].skinToneSupport == .multiple)
    #expect(first[0].skinToneVariants.map(\.tones) == [[.dark, .light], [.light, .dark]])
  }

  @Test func pinnedCommandRequiresConcreteNumericVersions() throws {
    let command = try #require(
      try FetchPinnedCommand.parseAsRoot([
        "--unicode-version", "18.0", "--cldr-tag", "49.0.0", "--locales", "en,cs", "--dry-run"
      ]) as? FetchPinnedCommand)
    #expect(command.unicodeVersion == "18.0")
    #expect(command.cldrTag == "49.0.0")
    #expect(command.dryRun)
    #expect(throws: (any Error).self) {
      try FetchPinnedCommand.parseAsRoot(["--unicode-version", "latest", "--cldr-tag", "main"])
    }
  }

  @Test func pinnedGenerationIsDeterministicWithoutReleaseDiscovery() async throws {
    let release = EmojiDataRelease(
      unicodeEmojiVersion: "18.0", cldrVersion: "49", cldrTag: "49.0.0")
    let annotations =
      #"{"annotations":{"annotations":{"😀":{"tts":["grinning face"],"default":["grin"]}}}}"#
    let client = StubHTTPClient(responses: [
      release.unicodeBaseURL.appending(path: "emoji-test.txt").absoluteString: .success(
        "# Version: 18.0\n# group: Smileys & Emotion\n# subgroup: face-smiling\n1F600 ; fully-qualified # 😀 E1.0 grinning face"
      ),
      release.unicodeBaseURL.appending(path: "emoji-sequences.txt").absoluteString: .failure(404),
      release.unicodeBaseURL.appending(path: "emoji-zwj-sequences.txt").absoluteString: .failure(
        404),
      EmojiDataSource.unicodePropertiesBaseURL(for: "18.0").appending(path: "emoji-data.txt")
        .absoluteString: .failure(404),
      EmojiDataSource.unicodePropertiesBaseURL(for: "18.0")
        .appending(path: "emoji-variation-sequences.txt").absoluteString: .failure(404),
      release.cldrBaseURL.appending(path: "cldr-annotations-full/annotations/en/annotations.json")
        .absoluteString: .success(annotations),
      release.cldrBaseURL
        .appending(path: "cldr-annotations-derived-full/annotationsDerived/en/annotations.json")
        .absoluteString: .failure(404)
    ])
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let paths = try CLIOutputPaths(
      outputRoot: directory.path, metadataPath: nil, emojisPath: nil, localizationsPath: nil)
    let generator = EmojiGenerator(dataLoader: EmojiDataLoader(httpClient: client))
    let first = try await generator.fetch(
      release: release, paths: paths, localeSelection: .explicit(["en"]), defaultLocale: "en",
      force: false, dryRun: false)
    let second = try await generator.fetch(
      release: release, paths: paths, localeSelection: .explicit(["en"]), defaultLocale: "en",
      force: false, dryRun: false)
    #expect(first.changedFiles.count == 4)
    #expect(second.changedFiles.isEmpty)
    let metadataData = try Data(contentsOf: URL(fileURLWithPath: paths.metadataPath))
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let metadata = try decoder.decode(GeneratedMetadata.self, from: metadataData)
    #expect(metadata.sourceFiles.count == 2)
    #expect(metadata.sourceFiles.allSatisfy { $0.sha256.count == 64 })
    let dryRoot = directory.appending(path: "dry-run")
    let dryPaths = try CLIOutputPaths(
      outputRoot: dryRoot.path, metadataPath: nil, emojisPath: nil, localizationsPath: nil)
    _ = try await generator.fetch(
      release: release, paths: dryPaths, localeSelection: .explicit(["en"]), defaultLocale: "en",
      force: false, dryRun: true)
    #expect(!FileManager.default.fileExists(atPath: dryRoot.path))
  }

  @Test func localeSelectionParsesAll() throws {
    #expect(try LocaleSelection(argument: nil) == .explicit(["en"]))
    #expect(try LocaleSelection(argument: "all") == .all)
  }

  @Test func localeSelectionParsesExplicitList() throws {
    #expect(try LocaleSelection(argument: "cs,de") == .explicit(["en", "cs", "de"]))
  }

  @Test func outputPathsUseRootAndOverrides() throws {
    let derived = try CLIOutputPaths(
      outputRoot: "/tmp/out",
      metadataPath: nil,
      emojisPath: nil,
      localizationsPath: nil
    )
    let overridden = try CLIOutputPaths(
      outputRoot: "/tmp/out",
      metadataPath: "/tmp/custom/meta.json",
      emojisPath: "/tmp/custom/emojis.json",
      localizationsPath: "/tmp/custom/localizations"
    )

    #expect(derived.metadataPath == "/tmp/out/metadata.json")
    #expect(derived.emojisPath == "/tmp/out/emojis.json")
    #expect(derived.localizationsPath == "/tmp/out/localizations")
    #expect(overridden.metadataPath == "/tmp/custom/meta.json")
    #expect(overridden.emojisPath == "/tmp/custom/emojis.json")
    #expect(overridden.localizationsPath == "/tmp/custom/localizations")
  }

  @Test func normalizeIDsFromScalars() {
    #expect(UnicodeEmojiParser.normalizeID(from: ["1f469", "200d", "1f4bb"]) == "1F469-200D-1F4BB")
  }

  @Test func parseEmojiTestFixture() throws {
    let fixture = """
      # group: Smileys & Emotion
      # subgroup: face-smiling
      1F600                                                  ; fully-qualified     # 😀 E6.1 grinning face
      # group: Objects
      # subgroup: light & video
      2B50                                                   ; fully-qualified     # ⭐ E5.1 star
      """

    let emojis = try UnicodeEmojiParser.parseEmojiTest(Data(fixture.utf8))

    #expect(emojis.map(\.id) == ["1F600", "2B50"])
    #expect(emojis.map(\.sortOrder) == [1, 2])
    #expect(emojis.last?.group == "Objects")
    #expect(emojis.first?.fallbackName == "grinning face")
  }

  @Test func parseEmojiTestCollapsesSkinToneVariantsIntoLogicalEntries() throws {
    let fixture = """
      # group: People & Body
      # subgroup: hand-fingers-closed
      1F44D                                                  ; fully-qualified     # 👍 E0.6 thumbs up
      1F44D 1F3FB                                            ; fully-qualified     # 👍🏻 E1.0 thumbs up: light skin tone
      1F44D 1F3FF                                            ; fully-qualified     # 👍🏿 E1.0 thumbs up: dark skin tone
      # subgroup: handshake
      1F91D                                                  ; fully-qualified     # 🤝 E3.0 handshake
      1FAF1 1F3FB 200D 1FAF2 1F3FB                           ; fully-qualified     # 🫱🏻‍🫲🏻 E14.0 handshake: light skin tone, light skin tone
      1FAF1 1F3FD 200D 1FAF2 1F3FF                           ; fully-qualified     # 🫱🏽‍🫲🏿 E14.0 handshake: medium skin tone, dark skin tone
      """

    let emojis = try UnicodeEmojiParser.parseEmojiTest(Data(fixture.utf8))
    let thumbsUp = try #require(emojis.first(where: { $0.id == "1F44D" }))
    let handshake = try #require(emojis.first(where: { $0.id == "1F91D" }))

    #expect(emojis.count == 2)
    #expect(thumbsUp.skinToneSupport == .single)
    #expect(thumbsUp.skinToneVariants.map(\.tones) == [[.light], [.dark]])
    #expect(handshake.skinToneSupport == .multiple)
    #expect(handshake.skinToneVariants.map(\.tones) == [[.light, .light], [.medium, .dark]])
  }

  @Test func preservesSequenceIdentityAndComponentsWithoutNameGrouping() throws {
    let fixture = """
      # group: People & Body
      # subgroup: person
      1F575 FE0F ; fully-qualified # 🕵️ E0.7 detective
      1F575 1F3FB ; fully-qualified # 🕵🏻 E2.0 deliberately different name: light skin tone
      1F575 FE0F 200D 2642 FE0F ; fully-qualified # 🕵️‍♂️ E4.0 man detective
      1F575 1F3FB 200D 2642 FE0F ; fully-qualified # 🕵🏻‍♂️ E4.0 detective: light skin tone
      1F575 ; unqualified # 🕵 E0.7 detective
      # group: Component
      # subgroup: skin-tone
      1F3FB ; component # 🏻 E1.0 light skin tone
      """
    let emojis = try UnicodeEmojiParser.parseEmojiTest(Data(fixture.utf8))
    #expect(emojis.map(\.id) == ["1F575-FE0F", "1F575-FE0F-200D-2642-FE0F", "1F3FB"])
    #expect(emojis.map { $0.skinToneVariants.count } == [1, 1, 0])
    #expect(emojis[0].skinToneVariants[0].id.rawValue == "1F575-1F3FB")
    #expect(emojis[1].skinToneVariants[0].id.rawValue == "1F575-1F3FB-200D-2642-FE0F")
  }

  @Test func rejectsOrphanToneSequencesInsteadOfInventingBases() {
    let fixture = """
      # group: People & Body
      # subgroup: hand
      1F44D 1F3FB ; fully-qualified # 👍🏻 E1.0 thumbs up: light skin tone
      """
    #expect(throws: (any Error).self) {
      try UnicodeEmojiParser.parseEmojiTest(Data(fixture.utf8))
    }
  }

  @Test func unicodeReleaseHeaderResolvesModernPinnedLocation() throws {
    #expect(
      try UnicodeReleaseResolver.version(fromEmojiTest: Data("# Version: 18.0\n".utf8)) == "18.0")
    #expect(
      EmojiDataSource.unicodeBaseURL(for: "18.0").absoluteString
        == "https://unicode.org/Public/18.0.0/emoji/")
  }

  @Test func generatedSkinToneVariantEncodesRawValueShape() throws {
    let data = try JSONEncoder()
      .encode(
        GeneratedSkinToneVariant(
          id: .init(rawValue: "1F44D-1F3FB"),
          value: "👍🏻",
          tones: [.light]
        )
      )

    #expect(String(decoding: data, as: UTF8.self).contains(#""id":"1F44D-1F3FB""#))
  }

  @Test func parseAvailableLocalesFixture() throws {
    let fixture = """
      {
        "availableLocales": {
          "full": ["de", "en", "cs"]
        }
      }
      """

    let locales = try CLDRParser.availableLocales(from: Data(fixture.utf8))

    #expect(locales == ["cs", "de", "en"])
  }

  @Test func parseLocalizationFixture() throws {
    let fixture = #"""
      {
        "annotations": {
          "annotations": {
            "😀": {
              "default": ["face", "grin"],
              "tts": "grinning face"
            }
          }
        }
      }
      """#

    let localization = try CLDRParser.parseLocalization(data: Data(fixture.utf8), locale: "en")

    #expect(localization["1F600"]?.name == "grinning face")
    #expect(localization["1F600"]?.searchTokens == ["face", "grin"])
  }

  @Test func cldrReleaseResolverFindsLatestTagFromTagsJSON() throws {
    let json = """
      [
        { "name": "46.1.0" },
        { "name": "47.0.0" },
        { "name": "45.0.0" },
        { "name": "99.0.0-BETA1" },
        { "name": "release-100" }
      ]
      """

    let tag = try CLDRReleaseResolver.latestTag(fromTagsJSON: Data(json.utf8))

    #expect(tag == "47.0.0")
    #expect(CLDRReleaseResolver.version(fromTag: tag) == "47")
  }

  @Test func discoveryUsesLatestHeaderAndStableCLDRTag() async throws {
    let loader = EmojiDataLoader(
      httpClient: StubHTTPClient(responses: [
        EmojiDataSource.unicodeLatestTestURL.absoluteString: .success("# Version: 18.0"),
        EmojiDataSource.cldrTagsURL.absoluteString: .success(
          #"[{"name":"49.0.0"},{"name":"50.0.0-BETA1"}]"#)
      ]))
    let release = try await loader.fetchLatestRelease()
    #expect(
      release == EmojiDataRelease(unicodeEmojiVersion: "18.0", cldrVersion: "49", cldrTag: "49.0.0")
    )
  }

  @Test func pinnedUnicodeHeaderMustMatchDiscoveredRelease() async throws {
    let release = EmojiDataRelease(
      unicodeEmojiVersion: "18.0", cldrVersion: "49", cldrTag: "49.0.0")
    let loader = EmojiDataLoader(
      httpClient: StubHTTPClient(responses: [
        release.unicodeBaseURL.appending(path: "emoji-test.txt").absoluteString: .success(
          "# Version: 17.0")
      ]))
    await #expect(throws: (any Error).self) {
      try await loader.fetchUnicodeSourceFiles(release: release)
    }
  }

  @Test func fetchUnicodeSourceFilesIgnoresMissingOptionalValidationFiles() async throws {
    let release = EmojiDataRelease(
      unicodeEmojiVersion: "16.0",
      cldrVersion: "47",
      cldrTag: "47.0.0"
    )
    let fetcher = EmojiDataLoader(
      httpClient: StubHTTPClient(
        responses: [
          release.unicodeBaseURL.appending(path: "emoji-test.txt").absoluteString: .success(
            "# Version: 16.0"),
          release.unicodeBaseURL.appending(path: "emoji-sequences.txt").absoluteString: .failure(
            404),
          release.unicodeBaseURL.appending(path: "emoji-zwj-sequences.txt").absoluteString:
            .success(
              "zwj"
            ),
          "https://unicode.org/Public/16.0.0/ucd/emoji/emoji-variation-sequences.txt":
            .failure(404),
          "https://unicode.org/Public/16.0.0/ucd/emoji/emoji-data.txt": .failure(404)
        ]
      )
    )

    let files = try await fetcher.fetchUnicodeSourceFiles(release: release)

    #expect(files.map(\.name) == ["emoji-test.txt", "emoji-zwj-sequences.txt"])
  }

  @Test func fetchAvailableLocalesUsesAnnotationLocaleCoverage() async throws {
    let release = EmojiDataRelease(
      unicodeEmojiVersion: "16.0",
      cldrVersion: "47",
      cldrTag: "47.0.0"
    )
    let fetcher = EmojiDataLoader(
      httpClient: StubHTTPClient(
        responses: [
          EmojiDataSource.cldrContentsURL(
            package: "cldr-annotations-full",
            directory: "annotations",
            tag: release.cldrTag
          )
          .absoluteString: .success(
            """
            [
              { "name": "en", "type": "dir" },
              { "name": "de", "type": "dir" }
            ]
            """
          ),
          EmojiDataSource.cldrContentsURL(
            package: "cldr-annotations-derived-full",
            directory: "annotationsDerived",
            tag: release.cldrTag
          )
          .absoluteString: .success(
            """
            [
              { "name": "en", "type": "dir" },
              { "name": "cs", "type": "dir" }
            ]
            """
          )
        ]
      )
    )

    let locales = try await fetcher.fetchAvailableLocales(release: release)

    #expect(locales == ["cs", "de", "en"])
  }

  @Test func fetchLocalizationSourcesAllowsDerivedOnlyLocale() async throws {
    let release = EmojiDataRelease(
      unicodeEmojiVersion: "16.0",
      cldrVersion: "47",
      cldrTag: "47.0.0"
    )
    let fetcher = EmojiDataLoader(
      httpClient: StubHTTPClient(
        responses: [
          release.cldrBaseURL
            .appending(path: "cldr-annotations-full/annotations/aa/annotations.json")
            .absoluteString: .failure(404),
          release.cldrBaseURL
            .appending(path: "cldr-annotations-derived-full/annotationsDerived/aa/annotations.json")
            .absoluteString: .success(
              """
              { "annotations": { "annotations": {} } }
              """
            )
        ]
      )
    )

    let files = try await fetcher.fetchLocalizationSources(locale: "aa", release: release)

    #expect(files.count == 1)
    #expect(files.first?.url.absoluteString.contains("cldr-annotations-derived-full") == true)
  }

  @Test func keycapEmojiUsesBaseCharacterLocalizationFallback() throws {
    let generator = EmojiGenerator()
    let direct = [
      "0023": GeneratedLocalizationEntry(name: "hash sign", searchTokens: ["hash", "sign"])
    ]

    let merged = try generator.mergeLocalizations(
      direct: direct,
      derived: [:],
      locale: "en",
      emojiIDs: ["0023-FE0F-20E3"]
    )

    #expect(merged["0023-FE0F-20E3"]?.name == "hash sign")
  }

  @Test func effectiveLocalizationFallsBackToEnglish() throws {
    let generator = EmojiGenerator()
    let emoji = GeneratedBaseEmoji(
      id: "1F600",
      value: "😀",
      group: "Smileys & Emotion",
      subgroup: "face-smiling",
      unicodeVersion: "6.1",
      sortOrder: 1,
      fallbackName: "grinning face"
    )

    let effective = try generator.effectiveLocalization(
      for: emoji,
      locale: "de",
      direct: [:],
      derived: [:],
      english: GeneratedLocalizationEntry(name: "grinning face", searchTokens: ["face", "grin"])
    )

    #expect(effective.name == "grinning face")
    #expect(effective.searchTokens == ["face", "grin", "grinning face"])
  }

  @Test func emptyDerivedDisplayNameFallsBackToEnglish() throws {
    let emoji = GeneratedBaseEmoji(
      id: "1F468-200D-1F466", value: "👨‍👦", group: "People & Body", subgroup: "family",
      unicodeVersion: "4.0", sortOrder: 1, fallbackName: "family: man, boy")
    let english = GeneratedLocalizationEntry(
      name: "family: man, boy", searchTokens: ["family", "man", "boy"])
    let result = try EmojiGenerator()
      .effectiveLocalization(
        for: emoji, locale: "es-MX", direct: [:],
        derived: [emoji.id: GeneratedLocalizationEntry(name: "", searchTokens: ["familia"])],
        english: english)
    #expect(result.name == english.name)
    #expect(result.searchTokens.contains("family"))
  }

  @Test func effectiveLocalizationSynthesizesFallbackWhenEnglishIsMissing() throws {
    let generator = EmojiGenerator()
    let emoji = GeneratedBaseEmoji(
      id: "1F600",
      value: "😀",
      group: "Smileys & Emotion",
      subgroup: "face-smiling",
      unicodeVersion: "6.1",
      sortOrder: 1,
      fallbackName: "grinning face"
    )

    let effective = try generator.effectiveLocalization(
      for: emoji,
      locale: "en",
      direct: [:],
      derived: [:],
      english: nil
    )

    #expect(effective.name == "grinning face")
    #expect(effective.searchTokens.contains("grinning face"))
    #expect(effective.searchTokens.contains("face"))
  }

  @Test func writerSkipsUnchangedBytesAndForcesRewrite() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let paths = try CLIOutputPaths(
      outputRoot: directory.path,
      metadataPath: nil,
      emojisPath: nil,
      localizationsPath: nil
    )
    let bundle = GeneratedBundle(
      metadata: GeneratedMetadata(
        schemaVersion: 2,
        unicodeEmojiVersion: "17.0",
        cldrVersion: "47",
        generatedAt: Date(timeIntervalSince1970: 0),
        defaultLocaleIdentifier: "en",
        availableLocaleIdentifiers: ["en"],
        sourceFiles: []
      ),
      emojis: [
        GeneratedBaseEmoji(
          id: "1F600",
          value: "😀",
          group: "Smileys & Emotion",
          subgroup: "face-smiling",
          unicodeVersion: "6.1",
          sortOrder: 1,
          skinToneSupport: .none,
          skinToneVariants: []
        )
      ],
      localizations: [
        "en": GeneratedLocalizationFile(
          localeIdentifier: "en",
          entries: [
            "1F600": GeneratedLocalizationEntry(
              name: "grinning face", searchTokens: ["face", "grin"])
          ]
        )
      ]
    )
    let writer = BundleWriter()

    let first = try writer.write(bundle: bundle, paths: paths, force: false, dryRun: false)
    let second = try writer.write(bundle: bundle, paths: paths, force: false, dryRun: false)
    let forced = try writer.write(bundle: bundle, paths: paths, force: true, dryRun: false)

    #expect(first.changedFiles.count == 4)
    #expect(second.changedFiles.isEmpty)
    #expect(forced.changedFiles.count == 4)
  }

  @Test func fetchLatestCommandParsesLocalesOption() throws {
    let command = try #require(
      try FetchLatestCommand.parseAsRoot(["--locales", "en,cs", "--dry-run"])
        as? FetchLatestCommand
    )

    #expect(command.locales == "en,cs")
    #expect(command.dryRun)
  }
}

private struct StubHTTPClient: HTTPDataLoading {
  enum Response {
    case success(String)
    case failure(Int)
  }

  let responses: [String: Response]

  func get(_ url: URL) async throws -> (Data, URLResponse) {
    guard let response = responses[url.absoluteString] else {
      throw NSError(
        domain: "StubHTTPClient",
        code: 1,
        userInfo: [
          NSLocalizedDescriptionKey: "Missing stub response for \(url.absoluteString)"
        ]
      )
    }

    switch response {
    case .success(let body):
      return (
        Data(body.utf8),
        try #require(
          HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
          )
        )
      )
    case .failure(let statusCode):
      return (
        Data(),
        try #require(
          HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
          )
        )
      )
    }
  }
}
