import Foundation
import os

// 统一日志出口，对应安卓版的 android.util.Log。
// 接 Xcode 控制台或 macOS 的 Console.app 都能看到，副标题用 subsystem 区分模块。

enum Log {
    private static let subsystem = "com.sharkking.assistant"
    private static let game = Logger(subsystem: subsystem, category: "游戏")
    private static let importer = Logger(subsystem: subsystem, category: "导入")
    private static let http = Logger(subsystem: subsystem, category: "HTTP")
    private static let script = Logger(subsystem: subsystem, category: "脚本缓存")
    private static let store = Logger(subsystem: subsystem, category: "Store")
    private static let update = Logger(subsystem: subsystem, category: "更新")
    private static let preset = Logger(subsystem: subsystem, category: "Preset")

    static func game(_ msg: String) { self.game.log("\(msg, privacy: .public)") }
    static func importer(_ msg: String) { self.importer.log("\(msg, privacy: .public)") }
    static func http(_ msg: String) { self.http.log("\(msg, privacy: .public)") }
    static func script(_ msg: String) { self.script.log("\(msg, privacy: .public)") }
    static func store(_ msg: String) { self.store.log("\(msg, privacy: .public)") }
    static func update(_ msg: String) { self.update.log("\(msg, privacy: .public)") }
    static func preset(_ msg: String) { self.preset.log("\(msg, privacy: .public)") }
    static func warn(_ msg: String) { self.game.warning("\(msg, privacy: .public)") }
}
