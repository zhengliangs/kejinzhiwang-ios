import Foundation

// 有序 JSON 构建器。
//
// 安卓版用 org.json.JSONObject，内部是 LinkedHashMap，字段顺序即插入顺序。
// 登录接口的 payload 注释里明确写了「字段顺序照抓包明文」，
// Swift 的 Dictionary / JSONSerialization 不保序，所以这里自己拼。

struct JsonObject {

    private(set) var pairs: [(String, Any)] = []

    mutating func put(_ key: String, _ value: Any?) {
        pairs.append((key, value ?? NSNull()))
    }

    mutating func put(_ key: String, _ value: JsonObject) { put(key, value as Any) }

    var sortedKeys: [String] { pairs.map { $0.0 } }

    /// 序列化成紧凑 JSON（无空格），键顺序即插入顺序
    func toJsonString() throws -> String {
        var out = "{"
        for (i, pair) in pairs.enumerated() {
            if i > 0 { out += "," }
            out += JsonWriter.quote(pair.0) + ":" + (try JsonWriter.write(pair.1))
        }
        return out + "}"
    }

    func toData() throws -> Data { Data(try toJsonString().utf8) }
}

enum JsonWriter {

    static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    static func write(_ value: Any) throws -> String {
        if value is NSNull { return "null" }
        if let b = value as? Bool { return b ? "true" : "false" }
        if let s = value as? String { return quote(s) }
        if let n = value as? Int { return String(n) }
        if let n = value as? Int32 { return String(n) }
        if let n = value as? Int64 { return String(n) }
        if let n = value as? Double { return String(n) }
        if let n = value as? Float { return String(n) }
        if let o = value as? JsonObject { return try o.toJsonString() }
        if let arr = value as? [Any] {
            var out = "["
            for (i, item) in arr.enumerated() {
                if i > 0 { out += "," }
                out += try write(item)
            }
            return out + "]"
        }
        // NSNumber 兜底
        if let n = value as? NSNumber { return n.stringValue }
        return quote("\(value)")
    }
}

/// 解析 JSON 字符串为 [String: Any]，null 转成 NSNull
func jsonParseObject(_ text: String) -> [String: Any]? {
    guard let data = text.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data, options: [])
    else { return nil }
    return obj as? [String: Any]
}

func jsonParseArray(_ text: String) -> [[String: Any]]? {
    guard let data = text.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data, options: [])
    else { return nil }
    return obj as? [[String: Any]]
}

// MARK: - 便捷取值，避免 Any 满天飞

extension Dictionary where Key == String, Value == Any {
    func jsonString(_ key: String) -> String? {
        guard let v = self[key], !(v is NSNull) else { return nil }
        return v as? String ?? (v as? NSNumber)?.stringValue
    }
    func jsonInt(_ key: String, _ def: Int = 0) -> Int {
        guard let v = self[key], !(v is NSNull) else { return def }
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s) ?? def }
        return def
    }
    func jsonBool(_ key: String, _ def: Bool = false) -> Bool {
        guard let v = self[key], !(v is NSNull) else { return def }
        if let n = v as? NSNumber { return n.boolValue }
        if let s = v as? String { return (s as NSString).boolValue }
        return def
    }
    func jsonDouble(_ key: String, _ def: Double = 0) -> Double {
        guard let v = self[key], !(v is NSNull) else { return def }
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) ?? def }
        return def
    }
    func jsonObj(_ key: String) -> [String: Any]? {
        guard let v = self[key], !(v is NSNull) else { return nil }
        return v as? [String: Any]
    }
    func jsonArray(_ key: String) -> [[String: Any]]? {
        guard let v = self[key], !(v is NSNull) else { return nil }
        return v as? [[String: Any]]
    }
}
