import Foundation

/// Byte-level TSV scanner.
///
/// The seed dictionary is ~145 MB / 3.1M lines; going through `String` line by
/// line spends most of the build in grapheme breaking. This walks the raw bytes
/// and only materialises the fields.
enum TSV {
    /// Call `body` with the fields of each line. The first line (the header) is
    /// skipped. Fields are handed over as raw byte slices — copy what you keep.
    static func forEachLine(
        path: String,
        skipHeader: Bool = true,
        _ body: (_ fields: [ArraySlice<UInt8>], _ lineNumber: Int) throws -> Void
    ) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        let bytes = [UInt8](data)

        var start = 0
        var lineNumber = 0
        var fields: [ArraySlice<UInt8>] = []
        fields.reserveCapacity(8)

        while start < bytes.count {
            var end = start
            while end < bytes.count, bytes[end] != 0x0A { end += 1 }
            var lineEnd = end
            if lineEnd > start, bytes[lineEnd - 1] == 0x0D { lineEnd -= 1 }  // CRLF

            lineNumber += 1
            if !(skipHeader && lineNumber == 1), lineEnd > start {
                fields.removeAll(keepingCapacity: true)
                var fieldStart = start
                var i = start
                while i < lineEnd {
                    if bytes[i] == 0x09 {
                        fields.append(bytes[fieldStart..<i])
                        fieldStart = i + 1
                    }
                    i += 1
                }
                fields.append(bytes[fieldStart..<lineEnd])
                try body(fields, lineNumber)
            }
            start = end + 1
        }
    }

    static func string(_ slice: ArraySlice<UInt8>) -> String {
        String(decoding: slice, as: UTF8.self)
    }

    static func float(_ slice: ArraySlice<UInt8>) -> Float? {
        Float(string(slice))
    }

    static func int(_ slice: ArraySlice<UInt8>) -> Int? {
        Int(string(slice))
    }
}
