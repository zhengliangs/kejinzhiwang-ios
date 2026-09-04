import Foundation
import CryptoKit

// 打包在 Resources/scripts 下的预置脚本。移植自安卓版 data/PresetScripts.kt。
//
// 升级时做一次同步：新增的补进来、内容变了的更新、包里已删除的清掉。
// 用户自己导入的脚本（preset=false）完全不受影响。

enum PresetScripts {

    private static let dirName = "scripts"

    /// 这几个默认启用，其余默认关闭
    private static let defaultEnabled: Set<String> = [
        "洗炼加速.js",
        "洗炼跳过红色.js",
    ]

    /// 常驻脚本：关掉会导致游戏卡死，不允许禁用或删除
    private static let locked: Set<String> = [
        "00-省电模式修复.js",
    ]

    private static var scriptsDir: URL? {
        Bundle.main.resourceURL?.appendingPathComponent(dirName)
    }

    /**
     * 包内脚本清单的指纹（名称 + 各自大小）。
     *
     * 用它替代「同步过一次」的布尔标志：脚本增删或内容变化时指纹就变，
     * 老用户升级后能自动拿到新脚本。含大小是为了内容更新也能触发同步。
     */
    static func assetStamp() -> String {
        guard let names = scriptNames() else { return "none" }
        let raw = names.map { name -> String in
            let size = (try? fileURL(name).resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return "\(name):\(size)"
        }.joined(separator: ";")
        // 清单文本可能很长，压成短哈希再存
        let digest = Insecure.SHA1.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    /**
     * 与包内脚本对齐。返回 (新增数, 移除数)。
     *
     * 更新已有脚本时保留用户的开关状态，只换代码 —— 用户手动开过的
     * 脚本不该因为一次升级被重置。
     */
    @discardableResult
    static func syncInto(_ store: AppStore) -> (added: Int, removed: Int) {
        guard let names = scriptNames() else { return (0, 0) }
        var added = 0
        for name in names {
            guard let code = readScript(name) else {
                Log.preset("预置脚本读取失败 \(name)")
                continue
            }
            if let existing = store.scripts.first(where: { $0.name == name }) {
                store.updatePresetScript(id: existing.id, code: code, locked: locked.contains(name))
            } else {
                store.addPresetScript(name: name, code: code,
                                      enabled: defaultEnabled.contains(name),
                                      locked: locked.contains(name))
                added += 1
            }
        }
        // 包里已经不带的旧预置脚本要清掉，但绝不动用户自己导入的
        let removed = store.removeStalePresets(Set(names))
        if added > 0 || removed > 0 {
            Log.preset("预置脚本同步: 新增 \(added), 移除 \(removed), 包内共 \(names.count)")
        }
        return (added, removed)
    }

    // MARK: - 内部

    private static func fileURL(_ name: String) -> URL {
        scriptsDir!.appendingPathComponent(name)
    }

    private static func scriptNames() -> [String]? {
        guard let dir = scriptsDir,
              let items = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        else { return nil }
        return items.filter { $0.lowercased().hasSuffix(".js") }.sorted()
    }

    private static func readScript(_ name: String) -> String? {
        guard let data = try? Data(contentsOf: fileURL(name)) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
