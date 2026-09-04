import Foundation

// BON 编解码。移植自安卓版 bon/BonCodec.kt + bon/Bon.kt。
//
// 解码值域（对应安卓的注释）：
//   NSNull / Int32 / Int64 / Float / Double / String / Bool /
//   [UInt8] / [String: Any] / [Any] / BonDate
//
// Swift 的 Dictionary 无法存 nil，所以 BON 的 null 一律用 NSNull 表示，
// 读取时走 bonValue()。

/// 需要严格保序的对象。Credential 的字段顺序照抄官方明文，不能乱。
struct BonObject {
    var pairs: [(String, Any?)] = []
    init(_ pairs: [(String, Any?)] = []) { self.pairs = pairs }
}

final class BonDecoder {

    private var reader: DataReader!
    private var strPool: [String] = []

    func decode(_ data: [UInt8]) throws -> Any? {
        reader = DataReader(data)
        strPool = []
        return try read()
    }

    private func read() throws -> Any? {
        let raw = try reader.readUInt8()
        guard let tag = BonTag(rawValue: raw) else {
            throw BonError("BonDecoder unknown type \(raw)")
        }
        switch tag {
        case .null:
            return NSNull()
        case .int32:
            return try reader.readInt32()
        case .int64:
            return try reader.readInt64()
        case .float32:
            return try reader.readFloat32()
        case .float64:
            return try reader.readFloat64()
        case .string:
            let s = try reader.readUtf()
            strPool.append(s)
            return s
        case .boolean:
            return try reader.readUInt8() == 1
        case .binary:
            return try reader.readBytes(try reader.read7BitInt())
        case .object:
            let n = try reader.read7BitInt()
            var map: [String: Any] = [:]
            map.reserveCapacity(min(n, 1024))
            for _ in 0..<n {
                let k = try read()
                map[(k as? String) ?? (k is NSNull ? "null" : "\(k!)")] = try read()
            }
            return map
        case .array:
            let n = try reader.read7BitInt()
            var list: [Any] = []
            list.reserveCapacity(min(n, 4096))
            for _ in 0..<n { list.append(try read() as Any) }
            return list
        case .datetime:
            return BonDate(millis: try reader.readInt64())
        case .stringRef:
            let i = try reader.read7BitInt()
            return strPool.indices.contains(i) ? strPool[i] : ""
        }
    }
}

/// 取对象字段，把 NSNull 归一化成 nil
func bonValue(_ map: [String: Any], _ key: String) -> Any? {
    guard let v = map[key], !(v is NSNull) else { return nil }
    return v
}

final class BonEncoder {

    private var writer: DataWriter!
    private var strIndex: [String: Int] = [:]

    /// 编码任意值。字符串首次出现写完整值并入池，重复出现写池索引
    /// —— 这个规则必须和服务端一致，否则解码侧索引对不上。
    func encode(_ value: Any?) -> [UInt8] {
        writer = DataWriter()
        strIndex = [:]
        write(value)
        return writer.toByteArray()
    }

    private func write(_ value: Any?) {
        guard let v = value else {
            writer.writeUInt8(BonTag.null.rawValue)
            return
        }
        if v is NSNull {
            writer.writeUInt8(BonTag.null.rawValue)
            return
        }
        if let b = v as? Bool {
            writer.writeUInt8(BonTag.boolean.rawValue)
            writer.writeUInt8(b ? 1 : 0)
            return
        }
        if let s = v as? String {
            if let idx = strIndex[s] {
                writer.writeUInt8(BonTag.stringRef.rawValue)
                writer.write7BitInt(idx)
            } else {
                writer.writeUInt8(BonTag.string.rawValue)
                writer.writeUtf(s)
                strIndex[s] = strIndex.count
            }
            return
        }
        // JS 侧对整数一律走 Int32，超范围才退到 Float64。
        // 这里保持一致，否则字节流对不上。
        if let n = v as? Int32 {
            writer.writeUInt8(BonTag.int32.rawValue)
            writer.writeInt32(n)
            return
        }
        if let n = v as? Int64 {
            if n >= Int64(Int32.min) && n <= Int64(Int32.max) {
                writer.writeUInt8(BonTag.int32.rawValue)
                writer.writeInt32(Int32(n))
            } else {
                writer.writeUInt8(BonTag.float64.rawValue)
                writer.writeFloat64(Double(n))
            }
            return
        }
        if let n = v as? Int {
            if n >= Int(Int32.min) && n <= Int(Int32.max) {
                writer.writeUInt8(BonTag.int32.rawValue)
                writer.writeInt32(Int32(n))
            } else {
                writer.writeUInt8(BonTag.float64.rawValue)
                writer.writeFloat64(Double(n))
            }
            return
        }
        if let n = v as? Double {
            if n == Darwin.floor(n) && !n.isInfinite &&
                n >= Double(Int32.min) && n <= Double(Int32.max) {
                writer.writeUInt8(BonTag.int32.rawValue)
                writer.writeInt32(Int32(n))
            } else {
                writer.writeUInt8(BonTag.float64.rawValue)
                writer.writeFloat64(n)
            }
            return
        }
        if let n = v as? Float { write(Double(n)); return }
        if let d = v as? BonDate {
            writer.writeUInt8(BonTag.datetime.rawValue)
            writer.writeInt64(d.millis)
            return
        }
        if let b = v as? [UInt8] {
            writer.writeUInt8(BonTag.binary.rawValue)
            writer.write7BitInt(b.count)
            writer.writeBytes(b)
            return
        }
        if let b = v as? Data {
            write([UInt8](b))
            return
        }
        if let obj = v as? BonObject {
            writer.writeUInt8(BonTag.object.rawValue)
            writer.write7BitInt(obj.pairs.count)
            for (k, val) in obj.pairs {
                write(k)
                write(val)
            }
            return
        }
        if let list = v as? [Any] {
            writer.writeUInt8(BonTag.array.rawValue)
            writer.write7BitInt(list.count)
            for item in list { write(item) }
            return
        }
        if let map = v as? [String: Any] {
            writer.writeUInt8(BonTag.object.rawValue)
            writer.write7BitInt(map.count)
            for (k, val) in map {
                write(k)
                write(val)
            }
            return
        }
        writer.writeUInt8(BonTag.null.rawValue)
    }
}
