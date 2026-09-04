import Foundation

// 把诊断日志追加写入 Documents/import.log。
//
// 真机没连 Mac 的时候 os_log 对用户等于不存在，界面上的日志框又要截图，
// 落盘一份是为了让「文件 App → 我的 iPhone → 氪金之王」里能直接取到。

enum LogFile {

    static var url: URL? {
        try? FileManager.default.url(for: .documentDirectory,
                                     in: .userDomainMask,
                                     appropriateFor: nil, create: true)
            .appendingPathComponent("import.log")
    }

    @discardableResult
    static func append(_ line: String) -> Bool {
        guard let url else { return false }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let entry = "[\(timestamp)] \(line)\n"
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let h = try FileHandle(forWritingTo: url)
                try h.seekToEnd()
                try h.write(contentsOf: Data(entry.utf8))
                try h.close()
            } else {
                try entry.write(to: url, atomically: true, encoding: .utf8)
            }
            return true
        } catch {
            return false
        }
    }
}
