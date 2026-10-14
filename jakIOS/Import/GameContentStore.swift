import Foundation
import UniformTypeIdentifiers

extension UTType {
    static let jakDiscImage = UTType(filenameExtension: "iso") ?? .data
}

struct ImportedGameContent: Sendable {
    enum Kind: Sendable {
        case discImage
        case extractedDirectory
    }

    let kind: Kind
    let location: URL
}

enum GameContentStoreError: LocalizedError {
    case unsupportedSelection
    case unrecognizedDiscImage
    case incompleteGameDirectory
    case destinationUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedSelection:
            return "Choose a Jak and Daxter ISO file or an extracted game-data folder."
        case .unrecognizedDiscImage:
            return "This file is not a recognizable ISO-9660 or UDF disc image."
        case .incompleteGameDirectory:
            return "The selected folder does not look like extracted Jak 1 game data. It must contain DGO and SYSTEM.CNF."
        case .destinationUnavailable:
            return "The app could not create its private game-data folder."
        }
    }
}

actor GameContentStore {
    private let fileManager = FileManager.default
    private let pcTextVersionMarker = ".jakios-pc-text-dev-menu-v11"

    func importContent(from sourceURL: URL) throws -> ImportedGameContent {
        let hasSecurityAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let resourceValues = try sourceURL.resourceValues(forKeys: [.isDirectoryKey])
        let isDirectory = resourceValues.isDirectory == true
        let isDiscImage = sourceURL.pathExtension.caseInsensitiveCompare("iso") == .orderedSame

        guard isDirectory || isDiscImage else {
            throw GameContentStoreError.unsupportedSelection
        }

        try validateSource(sourceURL, isDirectory: isDirectory)

        let contentDirectory = try importedContentDirectory()
        let destinationURL = contentDirectory
            .appendingPathComponent("extracted-jak1", isDirectory: true)

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        if isDirectory {
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            let unpackedURL = destinationURL.appendingPathComponent("unpacked-dgo", isDirectory: true)
            try? Jak1DGOExtractor.extractAllDGOs(inDirectory: destinationURL, toOutputDirectory: unpackedURL)
            buildPCText(in: destinationURL)
        } else {
            let temporaryURL = contentDirectory
                .appendingPathComponent("extracted-jak1.partial", isDirectory: true)
            if fileManager.fileExists(atPath: temporaryURL.path) {
                try fileManager.removeItem(at: temporaryURL)
            }

            do {
                try ISO9660Extractor.extract(from: sourceURL, to: temporaryURL)
                try validateSource(temporaryURL, isDirectory: true)
                try fileManager.moveItem(at: temporaryURL, to: destinationURL)

                let unpackedURL = destinationURL.appendingPathComponent("unpacked-dgo", isDirectory: true)
                try? Jak1DGOExtractor.extractAllDGOs(inDirectory: destinationURL, toOutputDirectory: unpackedURL)
                buildPCText(in: destinationURL)
            } catch {
                try? fileManager.removeItem(at: temporaryURL)
                throw error
            }
        }

        return ImportedGameContent(
            kind: isDirectory ? .extractedDirectory : .discImage,
            location: destinationURL
        )
    }

    /// Checks private storage without actor scheduling so launch UI can start in the correct state.
    nonisolated static func existingImportedContentSnapshot() -> ImportedGameContent? {
        let fileManager = FileManager.default
        guard let applicationSupportDirectory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }

        let destinationURL = applicationSupportDirectory
            .appendingPathComponent("OpenGOAL", isDirectory: true)
            .appendingPathComponent("ImportedContent", isDirectory: true)
            .appendingPathComponent("extracted-jak1", isDirectory: true)
        let dgoURL = destinationURL.appendingPathComponent("DGO", isDirectory: true)
        let systemConfigurationURL = destinationURL.appendingPathComponent("SYSTEM.CNF")
        var isDGOFolder: ObjCBool = false
        guard fileManager.fileExists(atPath: dgoURL.path, isDirectory: &isDGOFolder),
              isDGOFolder.boolValue,
              fileManager.fileExists(atPath: systemConfigurationURL.path) else {
            return nil
        }

        return ImportedGameContent(kind: .extractedDirectory, location: destinationURL)
    }

    /// Returns previously imported content and performs any required bundled-content maintenance.
    func existingImportedContent() -> ImportedGameContent? {
        guard let content = Self.existingImportedContentSnapshot() else {
            return nil
        }
        let destinationURL = content.location
        do {
            try removeRetiredExperimentalLevels(in: destinationURL)
        } catch {
            print("jakIOS: retired experimental level removal failed: \(error.localizedDescription)")
        }
        // Rebuild once when bundled menu text changes, including for previously imported content.
        let pcTextURL = destinationURL.appendingPathComponent(Jak1PCTextBuilder.outputDirectoryName, isDirectory: true)
        let versionMarkerURL = pcTextURL.appendingPathComponent(pcTextVersionMarker)
        if !fileManager.fileExists(atPath: versionMarkerURL.path) {
            buildPCText(in: destinationURL)
        }
        return ImportedGameContent(kind: .extractedDirectory, location: destinationURL)
    }

    /// True once the imported game holds the level files built from its disc (see buildLevelsIfNeeded).
    nonisolated static func hasBuiltLevels(in content: ImportedGameContent) -> Bool {
        Jak1LevelBuilder.hasBuiltLevels(inGameDirectory: content.location)
    }

    /// Converts the disc's levels into the renderer's level files (fr3/Jak1Level-*.fr3z) with OpenGOAL's
    /// level extractor; the app bundle ships none. Runs once per import, and once for imports made by
    /// builds that still bundled the levels.
    func buildLevelsIfNeeded(
        in content: ImportedGameContent,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) throws {
        guard !Self.hasBuiltLevels(in: content) else {
            return
        }
        try Jak1LevelBuilder.buildLevels(inGameDirectory: content.location) { completed, total, _ in
            progress(completed, total)
        }
    }

    /// Builds the PC-port text files (menu options, SECRETS, ...). Without them the game still runs
    /// on the disc text, so a failure only costs those strings.
    private func buildPCText(in gameDirectory: URL) {
        do {
            try Jak1PCTextBuilder.buildPCText(inGameDirectory: gameDirectory)
            let pcTextURL = gameDirectory.appendingPathComponent(
                Jak1PCTextBuilder.outputDirectoryName,
                isDirectory: true
            )
            try Data().write(to: pcTextURL.appendingPathComponent(pcTextVersionMarker))
        } catch {
            print("jakIOS: PC text build failed: \(error.localizedDescription)")
        }
    }

    /// Deletes the Eroded Coast level that older builds copied into the imported game. The level is
    /// removed from this build (parked in Parked/ErodedCoast), and the host refuses to load it anyway.
    private func removeRetiredExperimentalLevels(in gameDirectory: URL) throws {
        let retiredPaths = [
            "DGO/ERO.DGO",
            "unpacked-dgo/ERO.DGO",
            "unpacked-dgo/ERO",
        ]
        for path in retiredPaths {
            let url = gameDirectory.appendingPathComponent(path)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
    }

    private func validateSource(_ sourceURL: URL, isDirectory: Bool) throws {
        if isDirectory {
            let dgoURL = sourceURL.appendingPathComponent("DGO", isDirectory: true)
            let systemConfigurationURL = sourceURL.appendingPathComponent("SYSTEM.CNF")
            var isDGOFolder: ObjCBool = false
            let hasDGOFolder = fileManager.fileExists(
                atPath: dgoURL.path,
                isDirectory: &isDGOFolder
            ) && isDGOFolder.boolValue
            let hasSystemConfiguration = fileManager.fileExists(atPath: systemConfigurationURL.path)
            guard hasDGOFolder && hasSystemConfiguration else {
                throw GameContentStoreError.incompleteGameDirectory
            }
            return
        }

        let handle = try FileHandle(forReadingFrom: sourceURL)
        defer {
            try? handle.close()
        }
        let header = try handle.read(upToCount: 68 * 1_024) ?? Data()
        guard hasSupportedDiscVolumeDescriptor(in: header) else {
            throw GameContentStoreError.unrecognizedDiscImage
        }
    }

    private func hasSupportedDiscVolumeDescriptor(in header: Data) -> Bool {
        // ISO-9660's primary volume descriptor is sector 16, bytes 1...5.
        if descriptorIdentifier(in: header, sector: 16) == "CD001" {
            return true
        }

        // UDF's volume-recognition sequence normally follows sector 16.
        for sector in 16...32 {
            let identifier = descriptorIdentifier(in: header, sector: sector)
            if identifier == "NSR02" || identifier == "NSR03" {
                return true
            }
        }
        return false
    }

    private func descriptorIdentifier(in header: Data, sector: Int) -> String? {
        let offset = sector * 2_048 + 1
        let endOffset = offset + 5
        guard header.count >= endOffset else {
            return nil
        }
        return String(data: header[offset..<endOffset], encoding: .ascii)
    }

    private func importedContentDirectory() throws -> URL {
        guard let applicationSupportDirectory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw GameContentStoreError.destinationUnavailable
        }

        let directory = applicationSupportDirectory
            .appendingPathComponent("OpenGOAL", isDirectory: true)
            .appendingPathComponent("ImportedContent", isDirectory: true)

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
