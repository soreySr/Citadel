import Foundation

enum ISO9660ExtractionError: LocalizedError {
    case unsupportedImage
    case malformedImage
    case unsafePath
    case incompleteRead

    var errorDescription: String? {
        switch self {
        case .unsupportedImage:
            return "This disc image does not contain a supported ISO-9660 filesystem."
        case .malformedImage:
            return "The ISO-9660 filesystem is malformed or uses an unsupported layout."
        case .unsafePath:
            return "The disc image contains an unsafe file path."
        case .incompleteRead:
            return "The disc image ended before all requested game data could be read."
        }
    }
}

enum ISO9660Extractor {
    nonisolated private static let sectorSize = 2_048
    nonisolated private static let primaryVolumeDescriptorSector = 16
    nonisolated private static let copyChunkSize = 1_024 * 1_024
    nonisolated private static let maximumDirectoryByteCount = 32 * 1_024 * 1_024

    nonisolated static func extract(from imageURL: URL, to destinationURL: URL) throws {
        let values = try imageURL.resourceValues(forKeys: [.fileSizeKey])
        guard let imageSize = values.fileSize, imageSize > sectorSize * primaryVolumeDescriptorSector else {
            throw ISO9660ExtractionError.unsupportedImage
        }

        let input = try FileHandle(forReadingFrom: imageURL)
        defer {
            try? input.close()
        }

        let descriptor = try read(
            from: input,
            offset: UInt64(primaryVolumeDescriptorSector * sectorSize),
            count: sectorSize
        )
        guard descriptor.count == sectorSize,
              descriptor[0] == 1,
              String(data: descriptor[1..<6], encoding: .ascii) == "CD001" else {
            throw ISO9660ExtractionError.unsupportedImage
        }

        let rootDirectory = try directoryRecord(in: descriptor, at: 156)
        guard rootDirectory.isDirectory else {
            throw ISO9660ExtractionError.malformedImage
        }

        try FileManager.default.createDirectory(
            at: destinationURL,
            withIntermediateDirectories: true
        )

        var visitedDirectoryExtents: Set<UInt32> = []
        try extractDirectory(
            rootDirectory,
            from: input,
            imageSize: UInt64(imageSize),
            to: destinationURL,
            visitedDirectoryExtents: &visitedDirectoryExtents
        )
    }

    nonisolated private static func extractDirectory(
        _ directory: DirectoryRecord,
        from input: FileHandle,
        imageSize: UInt64,
        to destinationURL: URL,
        visitedDirectoryExtents: inout Set<UInt32>
    ) throws {
        guard visitedDirectoryExtents.insert(directory.extent).inserted else {
            throw ISO9660ExtractionError.malformedImage
        }

        let directoryData = try readExtent(
            directory,
            from: input,
            imageSize: imageSize
        )
        var offset = 0
        while offset < directoryData.count {
            let recordLength = Int(directoryData[offset])
            if recordLength == 0 {
                offset = ((offset / sectorSize) + 1) * sectorSize
                continue
            }
            guard recordLength >= 34, offset + recordLength <= directoryData.count else {
                throw ISO9660ExtractionError.malformedImage
            }

            let record = try directoryRecord(in: directoryData, at: offset)
            offset += recordLength

            guard let name = record.name else {
                continue
            }
            let childURL = try childURL(named: name, in: destinationURL)
            if record.isDirectory {
                try FileManager.default.createDirectory(
                    at: childURL,
                    withIntermediateDirectories: true
                )
                try extractDirectory(
                    record,
                    from: input,
                    imageSize: imageSize,
                    to: childURL,
                    visitedDirectoryExtents: &visitedDirectoryExtents
                )
            } else {
                try extractFile(record, from: input, imageSize: imageSize, to: childURL)
            }
        }
    }

    nonisolated private static func extractFile(
        _ file: DirectoryRecord,
        from input: FileHandle,
        imageSize: UInt64,
        to destinationURL: URL
    ) throws {
        guard !file.isMultiExtent else {
            throw ISO9660ExtractionError.malformedImage
        }
        let offset = try extentOffset(file.extent)
        let byteCount = UInt64(file.byteCount)
        guard offset <= imageSize, byteCount <= imageSize - offset else {
            throw ISO9660ExtractionError.incompleteRead
        }

        FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: destinationURL)
        defer {
            try? output.close()
        }

        try input.seek(toOffset: offset)
        var remaining = Int(byteCount)
        while remaining > 0 {
            let count = min(remaining, copyChunkSize)
            let chunk = try input.read(upToCount: count) ?? Data()
            guard !chunk.isEmpty else {
                throw ISO9660ExtractionError.incompleteRead
            }
            try output.write(contentsOf: chunk)
            remaining -= chunk.count
        }
    }

    nonisolated private static func readExtent(
        _ record: DirectoryRecord,
        from input: FileHandle,
        imageSize: UInt64
    ) throws -> Data {
        guard !record.isMultiExtent,
              record.byteCount <= maximumDirectoryByteCount else {
            throw ISO9660ExtractionError.malformedImage
        }
        let offset = try extentOffset(record.extent)
        let byteCount = UInt64(record.byteCount)
        guard offset <= imageSize, byteCount <= imageSize - offset else {
            throw ISO9660ExtractionError.incompleteRead
        }
        return try read(from: input, offset: offset, count: Int(byteCount))
    }

    nonisolated private static func read(from handle: FileHandle, offset: UInt64, count: Int) throws -> Data {
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: count) ?? Data()
        guard data.count == count else {
            throw ISO9660ExtractionError.incompleteRead
        }
        return data
    }

    nonisolated private static func directoryRecord(in data: Data, at offset: Int) throws -> DirectoryRecord {
        guard offset + 34 <= data.count else {
            throw ISO9660ExtractionError.malformedImage
        }
        let recordLength = Int(data[offset])
        let nameLength = Int(data[offset + 32])
        let paddedNameLength = nameLength + (nameLength.isMultiple(of: 2) ? 1 : 0)
        let minimumRecordLength = 33 + paddedNameLength
        guard recordLength >= minimumRecordLength, offset + recordLength <= data.count else {
            throw ISO9660ExtractionError.malformedImage
        }

        let rawName = Data(data[(offset + 33)..<(offset + 33 + nameLength)])
        let name: String?
        if rawName == Data([0]) || rawName == Data([1]) {
            name = nil
        } else {
            guard let decodedName = String(data: rawName, encoding: .ascii) else {
                throw ISO9660ExtractionError.malformedImage
            }
            name = decodedName
                .replacingOccurrences(of: ";1", with: "")
                .replacingOccurrences(of: ";0", with: "")
        }

        return DirectoryRecord(
            extent: littleEndian32(in: data, at: offset + 2),
            byteCount: littleEndian32(in: data, at: offset + 10),
            flags: data[offset + 25],
            name: name
        )
    }

    nonisolated private static func childURL(named name: String, in directoryURL: URL) throws -> URL {
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/"),
              !name.contains("\\") else {
            throw ISO9660ExtractionError.unsafePath
        }
        return directoryURL.appendingPathComponent(name, isDirectory: false)
    }

    nonisolated private static func extentOffset(_ extent: UInt32) throws -> UInt64 {
        let result = UInt64(extent).multipliedReportingOverflow(by: UInt64(sectorSize))
        guard !result.overflow else {
            throw ISO9660ExtractionError.malformedImage
        }
        return result.partialValue
    }

    nonisolated private static func littleEndian32(in data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }

    private struct DirectoryRecord {
        let extent: UInt32
        let byteCount: UInt32
        let flags: UInt8
        let name: String?

        nonisolated var isDirectory: Bool {
            flags & 0x02 != 0
        }

        nonisolated var isMultiExtent: Bool {
            flags & 0x80 != 0
        }
    }
}
