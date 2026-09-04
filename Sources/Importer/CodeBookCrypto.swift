import Foundation

// 334 SDK 的登录请求体加密。移植自安卓版 importer/CodeBookCrypto.kt。
//
// 算法从雪碧助手 renderer/hsdk-mock.js 的 CryptoModule 还原，
// 并用真实抓包做过往返验证（重新加密与原文逐字节一致）。
//
// 五步：明文 JSON → base64 → 混淆码本 → 抽密钥 → XOR → base64

enum CodeBookCrypto {

    /// 服务端下发的加密规则
    struct Rule {
        let codeBook: String
        let swapTimes: Int
        let keySkip: Int
        let keyOffset: Int
    }

    /// 递归交换左右两半，做 swapTimes 轮。
    /// 长度为奇数时原实现返回 null，这里等价地直接返回原串。
    static func transCode(_ str: String, _ swapTimes: Int) -> String {
        if swapTimes <= 0 { return str }
        let chars = Array(str)
        if chars.count % 2 != 0 { return str }
        let half = chars.count / 2
        let right = String(chars[half..<chars.count])
        let left = String(chars[0..<half])
        return transCode(right, swapTimes - 1) + transCode(left, swapTimes - 1)
    }

    /// 每隔 keySkip 个字符取一个，拼成密钥
    static func getKey(_ codeBook: String, _ keySkip: Int) -> String {
        if codeBook.isEmpty || keySkip <= 0 { return codeBook }
        let chars = Array(codeBook)
        let count = chars.count / keySkip
        var sb = ""
        sb.reserveCapacity(count)
        for i in 0..<count { sb.append(chars[i * keySkip]) }
        return sb
    }

    /// 逐字节 XOR，offset 在密钥长度内回绕。XOR 自反，加解密同一函数
    private static func xor(_ data: [UInt8], _ key: [UInt8], _ startOffset: Int) -> [UInt8] {
        if data.isEmpty || key.isEmpty { return data }
        var offset = startOffset
        var out = [UInt8](repeating: 0, count: data.count)
        for i in 0..<data.count {
            if offset >= key.count { offset = 0 }
            out[i] = data[i] ^ key[offset]
            offset += 1
        }
        return out
    }

    /// 明文 JSON → 服务端要的 base64 请求体。
    /// 中间那层 base64 的字符全在 ASCII 内，所以按 Latin1 取字节即可。
    static func encrypt(_ json: String, _ rule: Rule) -> String {
        let inner = B64.encode(Array(json.utf8))
        let key = keyStream(rule)
        let enc = xor(Array(inner.utf8), Array(key.utf8), key.count >> rule.keyOffset)
        return B64.encode(enc)
    }

    /// 反向解密，用于自测校验
    static func decrypt(_ body: String, _ rule: Rule) -> String? {
        let key = keyStream(rule)
        let inner = String(decoding: xor(B64.decode(body), Array(key.utf8), key.count >> rule.keyOffset),
                           as: UTF8.self)
        return String(decoding: B64.decode(inner), as: UTF8.self)
    }

    private static func keyStream(_ rule: Rule) -> String {
        getKey(transCode(rule.codeBook, rule.swapTimes), rule.keySkip)
    }
}

// 标准 Base64。安卓版自带实现是为了让加密逻辑能在纯 JVM 单测里跑，
// iOS 上 Foundation 的实现与之一致（标准字母表 + padding，无换行）。
enum B64 {
    static func encode(_ data: [UInt8]) -> String {
        Data(data).base64EncodedString(options: [])
    }
    static func decode(_ text: String) -> [UInt8] {
        guard let d = Data(base64Encoded: text, options: .ignoreUnknownCharacters) else { return [] }
        return [UInt8](d)
    }
}
