import Foundation

// 数据模型。移植自安卓版 data/Models.kt。
//
// 安卓版全部字段是 val（不可变），因为 Compose 的 mutableStateListOf
// 只在「元素被替换」时通知重组。SwiftUI 的 @Published 没有这个限制，
// 但这里仍然保持 struct 值语义 + 整体替换，行为一致。

/// 账号分组
struct AccountGroup: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var colorArgb: Int
    var order: Int = 0

    static let defaultId = "default"

    /// 调色板：(ARGB, 名称)
    static let palette: [(Int, String)] = [
        (0xFFEF5350, "红色"),
        (0xFFFF9800, "橙色"),
        (0xFFFFC107, "黄色"),
        (0xFF66BB6A, "绿色"),
        (0xFF42A5F5, "蓝色"),
        (0xFFAB47BC, "紫色"),
        (0xFF78909C, "灰色"),
    ]
}

/**
 * 一个账号。binHex 是登录请求体的十六进制串，
 * 注入到 window.__activeBinHex 后由 XHR 劫持脚本使用。
 */
struct AccountItem: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var binHex: String
    var groupId: String = AccountGroup.defaultId
    var isPrimary: Bool = false
    var order: Int = 0
    var builtin: Bool = false

    /// 列表与窗口标题隐藏 .bin 后缀
    var displayName: String { name.deletingSuffix(".bin") }

    var sizeBytes: Int { binHex.count / 2 }

    var binData: Data { Data(hex: binHex) }
}

/**
 * 游戏脚本，可开关。
 *
 * locked 为真时是修复类脚本（如省电模式），关掉游戏就会卡死，所以不允许
 * 禁用或删除。preset 标记随包内置，升级时可整体替换；用户自己导入的
 * 脚本 preset 为假，升级流程绝不触碰。
 */
struct UserScript: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var code: String
    var enabled: Bool = false
    var order: Int = 0
    var locked: Bool = false
    var preset: Bool = false

    var displayName: String { name.deletingSuffix(".js") }
}

/// 一个游戏窗口的运行态
struct GameWindow: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var accountId: String
    var title: String
    var isSyncMaster: Bool = false
}

// MARK: - 辅助

extension String {
    func deletingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }

    /// 十六进制字符串 → 字节
    var hexBytes: [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(count / 2)
        var idx = startIndex
        while idx < endIndex {
            let next = index(idx, offsetBy: 2, limitedBy: endIndex) ?? endIndex
            if let b = UInt8(self[idx..<next], radix: 16) { out.append(b) }
            idx = next
        }
        return out
    }
}

extension Data {
    /// 字节 → 十六进制字符串
    func toHex() -> String { map { String(format: "%02x", $0) }.joined() }

    init(hex: String) { self = Data(hex.hexBytes) }

    var hexBytes: [UInt8] { [UInt8](self) }
}
