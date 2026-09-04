import Foundation
import CryptoKit

// 把启用的脚本落盘到本地 HTTP 服务的根目录下，页面用 <script src> 加载。
// 移植自安卓版 core/ScriptCache.kt。
//
// 安卓版这么做的直接原因是 evaluateJavascript 走 Binder、约 1MB 上限，
// 超过会静默失败。iOS 没有这个限制，但保留同一套机制：大脚本走文件
// 加载同样更省内存，而且注入逻辑两边完全一致，行为不会有偏差。

enum ScriptCache {

    private static let subdir = "userscripts"

    struct Entry {
        let id: String
        let name: String
        let url: String
    }

    /// 文件名按内容哈希，内容不变就不重写，也天然避开中文名转义问题
    private static func keyOf(_ id: String, _ code: String) -> String {
        var hasher = Insecure.SHA1()
        hasher.update(data: Data(id.utf8))
        hasher.update(data: Data(code.utf8))
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    /// 写入脚本并返回可访问的相对路径。
    /// @param root LocalHttpServer 的静态根目录
    static func publish(root: URL, scripts: [(String, String, String)]) -> [Entry] {
        let dir = root.appendingPathComponent(subdir)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        var alive = Set<String>()
        var out: [Entry] = []

        for (id, name, code) in scripts {
            let file = dir.appendingPathComponent(keyOf(id, code) + ".js")
            alive.insert(file.lastPathComponent)
            let exists = FileManager.default.fileExists(atPath: file.path)
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            if !exists || size == 0 {
                do {
                    try Data(code.utf8).write(to: file)
                } catch {
                    Log.script("写入失败 \(name): \(error.localizedDescription)")
                    continue
                }
            }
            out.append(Entry(id: id, name: name, url: "\(subdir)/\(file.lastPathComponent)"))
        }

        // 脚本被改动或删除后，旧的哈希文件不会再被引用，清掉省空间
        if let items = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            for name in items where !alive.contains(name) {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
            }
        }

        Log.script("已发布 \(out.count) 个脚本到 \(dir.path)")
        return out
    }
}
