import Compression
import Foundation

/// Reads the mirror's `.tar.gz` bundle in process, so nothing in it decides
/// where a file lands: only regular files and directories under relative
/// paths of plain names are written, into a directory made for it. A link,
/// a device or a path with `..` refuses the whole archive, and so does a pax or
/// GNU extension header: the builder writes plain ustar, so none is needed, and
/// none is parsed before the signature is checked. Sizes are capped before
/// anything is written.
public enum BlocklistArchive {
    public struct Limits: Equatable, Sendable {
        /// The download itself.
        public var archiveBytes = 16 << 20
        /// Everything in it, unpacked.
        public var unpackedBytes = 64 << 20
        public var files = 512

        public init() {}
    }

    public enum Failure: Error, Equatable, Sendable {
        case notGzip
        case corrupt
        case tooLarge
        /// A link, a device, or a path that leaves the directory.
        case unsafeEntry(String)
    }

    public struct Entry: Equatable, Sendable {
        public var path: String
        public var data: Data
    }

    /// Unpacks `archive` into `directory` (created; it must not exist).
    public static func extract(_ archive: Data, to directory: URL, limits: Limits = Limits(), fileManager: FileManager = .default) throws {
        let entries = try self.entries(of: archive, limits: limits)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        for entry in entries {
            let file = directory.appendingPathComponent(entry.path)
            try fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try entry.data.write(to: file, options: .withoutOverwriting)
        }
    }

    /// The archive's regular files, in order.
    public static func entries(of archive: Data, limits: Limits = Limits()) throws -> [Entry] {
        guard archive.count <= limits.archiveBytes else { throw Failure.tooLarge }
        return try tarEntries(gunzip(archive, limit: limits.unpackedBytes), limits: limits)
    }

    // MARK: gzip (RFC 1952)

    static func gunzip(_ data: Data, limit: Int) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else { throw Failure.notGzip }
        let flags = bytes[3]
        var offset = 10
        if flags & 0x04 != 0 { // FEXTRA
            guard offset + 2 <= bytes.count else { throw Failure.corrupt }
            offset += 2 + Int(bytes[offset]) + Int(bytes[offset + 1]) << 8
        }
        for flag in [UInt8(0x08), 0x10] where flags & flag != 0 { // FNAME, FCOMMENT: to the next zero
            guard let end = bytes[min(offset, bytes.count)...].firstIndex(of: 0) else { throw Failure.corrupt }
            offset = end + 1
        }
        if flags & 0x02 != 0 { offset += 2 } // FHCRC
        guard offset < bytes.count - 8 else { throw Failure.corrupt }
        return try inflate(Array(bytes[offset..<(bytes.count - 8)]), limit: limit)
    }

    /// Raw DEFLATE through the system's streaming decoder, stopped at `limit`.
    private static func inflate(_ input: [UInt8], limit: Int) throws -> Data {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { throw Failure.corrupt }
        defer { compression_stream_destroy(stream) }
        var output = Data()
        let chunk = 1 << 16
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buffer.deallocate() }
        return try input.withUnsafeBufferPointer { source -> Data in
            stream.pointee.src_ptr = source.baseAddress!
            stream.pointee.src_size = source.count
            while true {
                stream.pointee.dst_ptr = buffer
                stream.pointee.dst_size = chunk
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                guard status != COMPRESSION_STATUS_ERROR else { throw Failure.corrupt }
                output.append(buffer, count: chunk - stream.pointee.dst_size)
                guard output.count <= limit else { throw Failure.tooLarge }
                if status == COMPRESSION_STATUS_END { return output }
                // No progress and no end: the stream is cut short.
                if stream.pointee.src_size == 0, stream.pointee.dst_size == chunk { throw Failure.corrupt }
            }
        }
    }

    // MARK: tar (plain ustar)

    private static func tarEntries(_ tar: Data, limits: Limits) throws -> [Entry] {
        let bytes = [UInt8](tar)
        var entries: [Entry] = []
        var offset = 0
        var seen = Set<String>()
        while offset + 512 <= bytes.count {
            let header = Array(bytes[offset..<offset + 512])
            if header.allSatisfy({ $0 == 0 }) { break }
            guard let size = octal(header[124..<136]) else { throw Failure.corrupt }
            let body = offset + 512
            guard size <= bytes.count - body else { throw Failure.corrupt }
            let content = bytes[body..<body + size]
            offset = body + (size + 511) / 512 * 512

            var name = text(header[0..<100])
            if text(header[257..<262]) == "ustar" {
                let prefix = text(header[345..<500])
                if !prefix.isEmpty { name = prefix + "/" + name }
            }
            while name.hasPrefix("./") { name.removeFirst(2) }

            switch header[156] {
            case 0, UInt8(ascii: "0"), UInt8(ascii: "7"):
                guard BlocklistManifest.isPlainRelativePath(name), seen.insert(name).inserted else { throw Failure.unsafeEntry(name) }
                guard entries.count < limits.files else { throw Failure.tooLarge }
                entries.append(Entry(path: name, data: Data(content)))
            case UInt8(ascii: "5"):
                // A directory: made when a file needs it.
                let directory = name.hasSuffix("/") ? String(name.dropLast()) : name
                guard directory.isEmpty || directory == "." || BlocklistManifest.isPlainRelativePath(directory) else { throw Failure.unsafeEntry(name) }
            default:
                // Links, devices, pipes and pax or GNU extension headers have no place in a bundle.
                throw Failure.unsafeEntry(name)
            }
        }
        return entries
    }

    private static func text(_ field: ArraySlice<UInt8>) -> String {
        String(decoding: field.prefix { $0 != 0 }, as: UTF8.self)
    }

    /// A header's size: octal digits, padded with spaces and zeros.
    private static func octal(_ field: ArraySlice<UInt8>) -> Int? {
        var value = 0
        for byte in field {
            if byte == 0 || byte == 0x20 { continue }
            guard byte >= 0x30, byte <= 0x37 else { return nil }
            value = value * 8 + Int(byte - 0x30)
            guard value <= 1 << 40 else { return nil }
        }
        return value
    }
}
