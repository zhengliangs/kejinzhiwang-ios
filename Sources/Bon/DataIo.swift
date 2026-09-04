import Foundation

// 字节流读写原语，全部小端。移植自安卓版 bon/DataIo.kt。
// iOS 上 Int 是 64 位，凡涉及协议里的 32 位字段一律显式用 Int32，
// 否则符号扩展会与安卓版（Kotlin Int 为 32 位）的字节流不一致。

/// 字节流读取原语
final class DataReader {

    private let data: [UInt8]
    private(set) var position: Int = 0

    init(_ data: [UInt8]) { self.data = data }

    var bytes: [UInt8] { data }

    private func need(_ n: Int) throws {
        if position + n > data.count {
            throw BonError("read eof at \(position) need \(n)")
        }
    }

    func readUInt8() throws -> UInt8 {
        try need(1)
        let v = data[position]
        position += 1
        return v
    }

    func readInt32() throws -> Int32 {
        try need(4)
        let u = UInt32(data[position]) |
            (UInt32(data[position + 1]) << 8) |
            (UInt32(data[position + 2]) << 16) |
            (UInt32(data[position + 3]) << 24)
        position += 4
        return Int32(bitPattern: u)
    }

    func readInt64() throws -> Int64 {
        try need(8)
        var u: UInt64 = 0
        for i in stride(from: 7, through: 0, by: -1) {
            u = (u << 8) | UInt64(data[position + i])
        }
        position += 8
        return Int64(bitPattern: u)
    }

    func readFloat32() throws -> Float {
        Float(bitPattern: UInt32(bitPattern: try readInt32()))
    }

    func readFloat64() throws -> Double {
        Double(bitPattern: UInt64(bitPattern: try readInt64()))
    }

    /// 7-bit varint，与 .NET Read7BitEncodedInt 一致
    func read7BitInt() throws -> Int {
        var value = 0
        var shift = 0
        var count = 0
        while true {
            if count == 5 { throw BonError("Format_Bad7BitInt32") }
            count += 1
            let b = Int(try readUInt8())
            value |= (b & 0x7F) << shift
            if b & 0x80 == 0 { break }
            shift += 7
        }
        return value
    }

    func readUtf() throws -> String {
        let len = try read7BitInt()
        try need(len)
        guard let s = String(bytes: data[position..<(position + len)], encoding: .utf8) else {
            throw BonError("utf8 decode failed at \(position)")
        }
        position += len
        return s
    }

    func readBytes(_ len: Int) throws -> [UInt8] {
        try need(len)
        let out = Array(data[position..<(position + len)])
        position += len
        return out
    }
}

/// 字节流写入原语
final class DataWriter {

    private var buf: [UInt8]
    private var size: Int = 0

    init(capacity: Int = 256) { buf = [UInt8](repeating: 0, count: max(capacity, 256)) }

    private func ensure(_ n: Int) {
        if size + n <= buf.count { return }
        var cap = buf.count
        while cap < size + n { cap <<= 1 }
        buf.append(contentsOf: [UInt8](repeating: 0, count: cap - buf.count))
    }

    func writeUInt8(_ v: UInt8) {
        ensure(1)
        buf[size] = v
        size += 1
    }

    func writeUInt8(_ v: Int) { writeUInt8(UInt8(truncatingIfNeeded: v)) }

    func writeInt32(_ v: Int32) {
        let u = UInt32(bitPattern: v)
        writeUInt8(UInt8(truncatingIfNeeded: u))
        writeUInt8(UInt8(truncatingIfNeeded: u >> 8))
        writeUInt8(UInt8(truncatingIfNeeded: u >> 16))
        writeUInt8(UInt8(truncatingIfNeeded: u >> 24))
    }

    func writeInt64(_ v: Int64) {
        let u = UInt64(bitPattern: v)
        for i in 0..<8 { writeUInt8(UInt8(truncatingIfNeeded: u >> (i * 8))) }
    }

    func writeFloat64(_ v: Double) { writeInt64(Int64(bitPattern: v.bitPattern)) }

    func write7BitInt(_ value: Int) {
        var v = value
        while true {
            let b = v & 0x7F
            v >>= 7
            if v != 0 { writeUInt8(b | 0x80) } else { writeUInt8(b); break }
        }
    }

    func writeUtf(_ s: String) {
        let bytes = Array(s.utf8)
        write7BitInt(bytes.count)
        writeBytes(bytes)
    }

    func writeBytes(_ b: [UInt8]) {
        ensure(b.count)
        buf.replaceSubrange(size..<(size + b.count), with: b)
        size += b.count
    }

    func toByteArray() -> [UInt8] { Array(buf[0..<size]) }
}
