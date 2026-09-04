import Foundation

// LZ4 帧格式。移植自安卓版 bon/Lz4.kt。
//
// 只做解压 + 「未压缩块」封帧。不需要真正的压缩算法：实测真实
// bin 的块标志位就是未压缩，客户端本来也没压。
//
// 不引第三方库：LX 报文的帧头是被加密破坏后人工还原的，
// 用现成库反而容易在校验环节卡住。

enum Lz4 {

    private static let magic: UInt32 = 0x184D2204

    /// 与真实 bin 一致：ver=1，其余标志位全 0
    private static let flg: UInt8 = 0x40
    /// blockMaxSize 码 7 = 4MB
    private static let bd: UInt8 = 0x70

    /// 把明文包成 LZ4 帧，单个未压缩块。
    /// 布局：magic(4) + FLG(1) + BD(1) + HC(1) + blockSize(4) + data + endMark(4)
    static func frameUncompressed(_ data: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 11 + data.count + 4)
        writeLE32(&out, 0, magic)
        out[4] = flg
        out[5] = bd
        // 帧头校验：xxh32(FLG,BD) 的第二字节。FLG/BD 固定，所以结果恒为 0xDF
        out[6] = UInt8(truncatingIfNeeded: xxh32([flg, bd]) >> 8)
        writeLE32(&out, 7, UInt32(data.count) | 0x8000_0000)
        out.replaceSubrange(11..<(11 + data.count), with: data)
        writeLE32(&out, 11 + data.count, 0)
        return out
    }

    private static func writeLE32(_ buf: inout [UInt8], _ at: Int, _ v: UInt32) {
        buf[at] = UInt8(truncatingIfNeeded: v)
        buf[at + 1] = UInt8(truncatingIfNeeded: v >> 8)
        buf[at + 2] = UInt8(truncatingIfNeeded: v >> 16)
        buf[at + 3] = UInt8(truncatingIfNeeded: v >> 24)
    }

    @inline(__always)
    private static func rotl32(_ x: UInt32, _ r: Int) -> UInt32 {
        (x << r) | (x >> (32 - r))
    }

    // xxHash32，仅用于算帧头校验，输入只有 2 字节所以不需要主循环
    private static let p1: UInt32 = 2654435761   // -1640531535
    private static let p2: UInt32 = 2246822519   // -2048144777
    private static let p3: UInt32 = 3266489917   // -1028477379
    private static let p4: UInt32 = 668265263
    private static let p5: UInt32 = 374761393

    private static func xxh32(_ input: [UInt8], seed: UInt32 = 0) -> UInt32 {
        var h = seed &+ p5 &+ UInt32(input.count)
        var i = 0
        while i + 4 <= input.count {
            let k = UInt32(input[i]) |
                (UInt32(input[i + 1]) << 8) |
                (UInt32(input[i + 2]) << 16) |
                (UInt32(input[i + 3]) << 24)
            h = rotl32(h &+ k &* p3, 17) &* p4
            i += 4
        }
        while i < input.count {
            h = rotl32(h &+ UInt32(input[i]) &* p5, 11) &* p1
            i += 1
        }
        h ^= h >> 15
        h &*= p2
        h ^= h >> 13
        h &*= p3
        h ^= h >> 16
        return h
    }

    static func decompressFrame(_ input: [UInt8]) throws -> [UInt8] {
        if input.count < 7 { throw BonError("LZ4 帧过短") }
        let m = UInt32(input[0]) |
            (UInt32(input[1]) << 8) |
            (UInt32(input[2]) << 16) |
            (UInt32(input[3]) << 24)
        guard m == magic else { throw BonError("LZ4 magic 不匹配") }

        let f = input[4]
        let blockChecksum = ((f >> 4) & 1) == 1
        let contentSize = ((f >> 3) & 1) == 1
        let contentChecksum = ((f >> 2) & 1) == 1
        let dictId = (f & 1) == 1

        var p = 7
        if contentSize { p += 8 }
        if dictId { p += 4 }

        var out: [[UInt8]] = []
        var total = 0
        while p + 4 <= input.count {
            var blockSize = UInt32(input[p]) |
                (UInt32(input[p + 1]) << 8) |
                (UInt32(input[p + 2]) << 16) |
                (UInt32(input[p + 3]) << 24)
            p += 4
            if blockSize == 0 { break }

            let uncompressed = (blockSize & 0x8000_0000) != 0
            blockSize &= 0x7FFF_FFFF
            if Int(blockSize) < 0 || p + Int(blockSize) > input.count {
                throw BonError("LZ4 块越界: size=\(blockSize) pos=\(p) len=\(input.count)")
            }

            let block: [UInt8]
            if uncompressed {
                block = Array(input[p..<(p + Int(blockSize))])
            } else {
                block = try decompressBlock(input, p, Int(blockSize))
            }
            out.append(block)
            total += block.count
            p += Int(blockSize)
            if blockChecksum { p += 4 }
        }
        if contentChecksum { p += 4 }

        var result = [UInt8](repeating: 0, count: total)
        var o = 0
        for b in out {
            result.replaceSubrange(o..<(o + b.count), with: b)
            o += b.count
        }
        return result
    }

    /// LZ4 块解压：序列为 token + literal + match
    private static func decompressBlock(_ src: [UInt8], _ offset: Int, _ length: Int) throws -> [UInt8] {
        var ip = offset
        let end = offset + length
        // 输出大小未知，按块最大压缩比预留并按需增长
        var dst = [UInt8](repeating: 0, count: length * 4 + 64)
        var op = 0

        func grow(_ need: Int) {
            if op + need <= dst.count { return }
            var cap = dst.count
            while cap < op + need { cap <<= 1 }
            dst.append(contentsOf: [UInt8](repeating: 0, count: cap - dst.count))
        }

        while ip < end {
            let token = Int(src[ip])
            ip += 1

            var litLen = token >> 4
            if litLen == 15 {
                while ip < end {
                    let b = Int(src[ip])
                    ip += 1
                    litLen += b
                    if b != 255 { break }
                }
            }
            if litLen > 0 {
                if ip + litLen > end { throw BonError("LZ4 literal 越界") }
                grow(litLen)
                dst.replaceSubrange(op..<(op + litLen), with: src[ip..<(ip + litLen)])
                ip += litLen
                op += litLen
            }

            // 块尾可能只有 literal，没有 match
            if ip >= end { break }
            if ip + 2 > end { throw BonError("LZ4 offset 截断") }

            let matchOffset = Int(src[ip]) | (Int(src[ip + 1]) << 8)
            ip += 2
            if matchOffset == 0 { throw BonError("LZ4 offset 为 0") }

            var matchLen = token & 0x0F
            if matchLen == 15 {
                while ip < end {
                    let b = Int(src[ip])
                    ip += 1
                    matchLen += b
                    if b != 255 { break }
                }
            }
            matchLen += 4

            var mp = op - matchOffset
            if mp < 0 { throw BonError("LZ4 match 偏移越界") }
            grow(matchLen)
            // 必须逐字节拷贝：match 区可能与输出区重叠（offset < len）
            for _ in 0..<matchLen {
                dst[op] = dst[mp]
                op += 1
                mp += 1
            }
        }
        return Array(dst[0..<op])
    }
}
