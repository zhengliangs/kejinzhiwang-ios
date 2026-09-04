import Foundation

// 把 bundle 里的 renderer 展开到缓存目录，供 LocalHttpServer 作为静态根。
// 移植自安卓版 core/RendererCache.kt（对应 iOS 原版「已复制渲染文件到缓存目录」）。
//
// 目录在 App 内叫 renderer，与安卓一致，ScriptCache 也往这里写。

enum RendererCache {

    private static let assetRoot = "renderer"
    /// 改动 Resources/renderer 下任何文件都要升这个版本号，否则旧缓存不会被替换
    private static let stampFile = ".copied_v95"

    static func cachesDir() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("renderer")
    }

    @discardableResult
    static func ensure() -> URL {
        let dir = cachesDir()
        let stamp = dir.appendingPathComponent(stampFile)
        if FileManager.default.fileExists(atPath: stamp.path) {
            Log.game("渲染缓存目录有效")
            return dir
        }
        if FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.removeItem(at: dir)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        copyDir(from: bundleRendererURL, to: dir)
        try? "\(Int64(Date().timeIntervalSince1970 * 1000))"
            .write(to: stamp, atomically: true, encoding: .utf8)
        Log.game("已复制渲染文件到缓存目录")
        return dir
    }

    private static var bundleRendererURL: URL {
        Bundle.main.resourceURL?.appendingPathComponent(assetRoot)
            ?? Bundle.main.bundleURL.appendingPathComponent(assetRoot)
    }

    private static func copyDir(from src: URL, to dst: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: src.path) else {
            Log.warn("渲染资源目录不存在: \(src.path)")
            return
        }
        if items.isEmpty { return }
        try? fm.createDirectory(at: dst, withIntermediateDirectories: true)
        for name in items where !name.hasPrefix(".") {
            let from = src.appendingPathComponent(name)
            let to = dst.appendingPathComponent(name)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: from.path, isDirectory: &isDir), isDir.boolValue {
                copyDir(from: from, to: to)
            } else {
                copyFile(from: from, to: to)
            }
        }
    }

    private static func copyFile(from src: URL, to dst: URL) {
        do {
            try? FileManager.default.createDirectory(
                at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try Data(contentsOf: src)
            try data.write(to: dst)
        } catch {
            Log.warn("复制失败 \(src.lastPathComponent): \(error.localizedDescription)")
        }
    }
}
