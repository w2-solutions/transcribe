import Foundation

/// A minimal ZIP writer for the Claude Desktop `.mcpb` (§2.3): entries stored uncompressed, no extra fields, no
/// comment, no ZIP64. Enough for a manifest and a README.
enum ZipWriter {
    static func stored(_ entries: [(name: String, data: Data)], date: Date) -> Data {
        let (time, day) = dosDateTime(date)
        var out = Data(), central = Data()
        for entry in entries {
            let name = Data(entry.name.utf8)
            let crc = crc32(entry.data)
            let size = UInt32(entry.data.count)
            let offset = UInt32(out.count)

            // Local file header.
            out.le32(0x0403_4B50)
            out.le16(10)            // version needed: 1.0 (stored)
            out.le16(0)             // flags
            out.le16(0)             // method: stored
            out.le16(time); out.le16(day)
            out.le32(crc); out.le32(size); out.le32(size)
            out.le16(UInt16(name.count)); out.le16(0)
            out.append(name)
            out.append(entry.data)

            // Central directory header.
            central.le32(0x0201_4B50)
            central.le16(0x031E)    // made by: Unix, 3.0 (so the external attributes carry Unix modes)
            central.le16(10)
            central.le16(0); central.le16(0)
            central.le16(time); central.le16(day)
            central.le32(crc); central.le32(size); central.le32(size)
            central.le16(UInt16(name.count))
            central.le16(0); central.le16(0)   // extra, comment
            central.le16(0); central.le16(0)   // disk, internal attributes
            central.le32(UInt32(0o100644) << 16)
            central.le32(offset)
            central.append(name)
        }
        let centralOffset = UInt32(out.count)
        out.append(central)
        // End of central directory.
        out.le32(0x0605_4B50)
        out.le16(0); out.le16(0)
        out.le16(UInt16(entries.count)); out.le16(UInt16(entries.count))
        out.le32(UInt32(central.count)); out.le32(centralOffset)
        out.le16(0)
        return out
    }

    /// CRC-32 (IEEE 802.3, reflected, as ZIP uses it).
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }

    private static let table: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    /// MS-DOS time and date in the Mac's time zone (ZIP has no zone), clamped to 1980 at the earliest.
    private static func dosDateTime(_ date: Date) -> (time: UInt16, date: UInt16) {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max((c.year ?? 1980) - 1980, 0)
        let time = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2)
        let day = UInt16(min(year, 127) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
        return (time, day)
    }
}

private extension Data {
    mutating func le16(_ v: UInt16) { append(UInt8(v & 0xFF)); append(UInt8(v >> 8)) }
    mutating func le32(_ v: UInt32) { for shift in stride(from: 0, to: 32, by: 8) { append(UInt8((v >> UInt32(shift)) & 0xFF)) } }
}
