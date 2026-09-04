import Foundation

// 咸鱼之王报文加解密。移植自安卓版 bon/XyCrypto.kt。
//
// 两种封装，靠前两字节区分：
// - "px" (0x70 0x78) → X：整体单字节 XOR，前 4 字节是头
// - "pl" (0x70 0x6C) → LX：只 XOR 前 100 字节，头 4 字节还原成
//   LZ4 帧魔数后解压
//
// 密钥是一个 8 位值，拆成 8 个 bit 藏在第 3、4 字节的偶数位上
// （掩码 0xAA 的补集），extractKey 负责取回。

enum XyCrypto {

    enum Kind { case x, lx, none }

    static func detect(_ data: [UInt8]) -> Kind {
        guard data.count >= 2 else { return .none }
        if data[0] == 0x70 && data[1] == 0x78 { return .x }
        if data[0] == 0x70 && data[1] == 0x6C { return .lx }
        return .none
    }

    private static func extractKey(_ d: [UInt8]) -> Int {
        let b2 = Int(d[2])
        let b3 = Int(d[3])
        return (((b2 >> 6) & 1) << 7) |
            (((b2 >> 4) & 1) << 6) |
            (((b2 >> 2) & 1) << 5) |
            (((b2 >> 0) & 1) << 4) |
            (((b3 >> 6) & 1) << 3) |
            (((b3 >> 4) & 1) << 2) |
            (((b3 >> 2) & 1) << 1) |
            (((b3 >> 0) & 1) << 0)
    }

    static func decryptX(_ data: [UInt8]) -> [UInt8] {
        guard data.count >= 4 else { return data }
        var buf = data
        let key = extractKey(buf)
        let k = UInt8(truncatingIfNeeded: key)
        var i = buf.count - 1
        while i >= 4 {
            buf[i] ^= k
            i -= 1
        }
        return Array(buf[4..<buf.count])
    }

    static func encryptX(_ data: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: data.count + 4)
        let rid = UInt32(bitPattern: Int32.random(in: Int32.min...Int32.max))
        out[0] = UInt8(truncatingIfNeeded: rid)
        out[1] = UInt8(truncatingIfNeeded: rid >> 8)
        out[2] = UInt8(truncatingIfNeeded: rid >> 16)
        out[3] = UInt8(truncatingIfNeeded: rid >> 24)
        out.replaceSubrange(4..<(4 + data.count), with: data)

        let key = Int.random(in: 2...249)
        let k = UInt8(truncatingIfNeeded: key)
        for i in out.indices.reversed() { out[i] ^= k }

        out[0] = 0x70
        out[1] = 0x78
        out[2] = UInt8((0xAA & Int(out[2])) |
            (((key >> 7) & 1) << 6) |
            (((key >> 6) & 1) << 4) |
            (((key >> 5) & 1) << 2) |
            (((key >> 4) & 1) << 0))
        out[3] = UInt8((0xAA & Int(out[3])) |
            (((key >> 3) & 1) << 6) |
            (((key >> 2) & 1) << 4) |
            (((key >> 1) & 1) << 2) |
            (((key >> 0) & 1) << 0))
        return out
    }

    static func decryptLX(_ data: [UInt8]) throws -> [UInt8] {
        guard data.count >= 4 else { return data }
        var buf = data
        let key = extractKey(buf)
        let k = UInt8(truncatingIfNeeded: key)
        let n = min(buf.count, 100)
        for i in 2..<n { buf[i] ^= k }
        // 帧魔数被加密覆盖了，这里还原
        buf[0] = 0x04; buf[1] = 0x22; buf[2] = 0x4D; buf[3] = 0x18
        return try Lz4.decompressFrame(buf)
    }

    /// 封装成 LX("pl") 格式。生成 bin 必须用这个而不是 encryptX：
    ///
    /// 游戏发 authuser 时请求头带 O4e-Encoding: lx，声明请求体是 lx 编码。
    /// 若实际给的是 px，服务端直接回「指令解析错误」，游戏卡在「正在登录」。
    /// 玩家常用的 bin 解析工具同样只认 LZ4 帧，px 会报 headerVersion_wrong。
    static func encryptLX(_ data: [UInt8]) -> [UInt8] {
        var frame = Lz4.frameUncompressed(data)
        let key = Int.random(in: 2...249)
        let k = UInt8(truncatingIfNeeded: key)
        // 与解密对称：只 XOR [2,100)
        let n = min(frame.count, 100)
        for i in 2..<n { frame[i] ^= k }
        frame[0] = 0x70
        frame[1] = 0x6C
        frame[2] = UInt8((0xAA & Int(frame[2])) |
            (((key >> 7) & 1) << 6) |
            (((key >> 6) & 1) << 4) |
            (((key >> 5) & 1) << 2) |
            (((key >> 4) & 1) << 0))
        frame[3] = UInt8((0xAA & Int(frame[3])) |
            (((key >> 3) & 1) << 6) |
            (((key >> 2) & 1) << 4) |
            (((key >> 1) & 1) << 2) |
            (((key >> 0) & 1) << 0))
        return frame
    }

    static func decrypt(_ data: [UInt8]) throws -> [UInt8] {
        switch detect(data) {
        case .x: return decryptX(data)
        case .lx: return try decryptLX(data)
        case .none: return data
        }
    }
}
