import Foundation

// BON (Binary Object Notation) 编解码。
//
// 咸鱼之王服务端用的自研二进制格式，等价于 .NET BinaryWriter 的布局：
// 全部小端，字符串用 7-bit varint 长度前缀 + UTF-8。
// 重复字符串会写成引用（类型码 99 + 池索引），编解码两侧必须
// 用同一套入池规则，否则索引会错位。
//
// 移植自安卓版 bon/Bon.kt，类型码与字节布局逐一对应。

/// BON 值的类型码
enum BonTag: UInt8 {
    case null = 0
    case int32 = 1
    case int64 = 2
    case float32 = 3
    case float64 = 4
    case string = 5
    case boolean = 6
    case binary = 7
    case object = 8
    case array = 9
    case datetime = 10
    case stringRef = 99
}

/// BON 里的日期值，与普通整数区分开
struct BonDate: Equatable {
    let millis: Int64
}

struct BonError: LocalizedError {
    let msg: String
    init(_ msg: String) { self.msg = msg }
    var errorDescription: String? { msg }
}

/// 解码产出的数值统一按 Double 取，对应安卓版 BinBuilder.num()。
/// 字符串会被尝试解析（服务端偶发把数字写成字符串）。
func bonNumber(_ value: Any?) -> Double? {
    switch value {
    case let n as Int32: return Double(n)
    case let n as Int64: return Double(n)
    case let n as Double: return n
    case let n as Float: return Double(n)
    case let n as Int: return Double(n)
    case let s as String: return Double(s)
    default: return nil
    }
}

/// 把字符串里的 Shell 保留字符替换为下划线，用于生成安全文件名
func bonSafeFileName(_ raw: String) -> String {
    let bad = CharacterSet(charactersIn: "\\/:*?\"<>|")
    return raw.unicodeScalars.map { bad.contains($0) ? "_" : String($0) }.joined()
}
