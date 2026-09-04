import Foundation
import SwiftUI

// 全局状态与持久化。移植自安卓版 data/AppStore.kt。
//
// 安卓版用 SharedPreferences 存 JSON 字符串，这里用 UserDefaults + Codable，
// 存的内容等价（三个数组 + 若干开关）。

final class AppStore: ObservableObject {

    static let windowLimit = 6

    private enum Key {
        static let pref = "xuebi_store"
        static let accounts = "accounts"
        static let groups = "groups"
        static let scripts = "scripts"
        static let maxWin = "max_windows"
        static let purgedBuiltin = "purged_builtin"
        // 存的是包内脚本清单的指纹，清单一变就重新同步
        static let presetDone = "preset_stamp"
        static let tabMode = "tab_mode"
        static let dark = "dark_theme"
    }

    /**
     * v3 之前存下的脚本没有 preset 标记。这些名字是历史版本内置过的，
     * 用于在升级时识别并清理，避免残留。
     */
    private static let legacyPresetNames: Set<String> = [
        "00-省电模式修复.js",
        "世界循环发消息.js",
        "十殿加速.js",
        "好友备注.js",
        "属性展示增强.js",
        "查看白玉彩玉使用记录.js",
        "洗炼加速.js",
        "洗炼跳过红色.js",
        "盐场无限视距.js",
        "盐场阵容显示.js",
        "自动蟠桃protected.js",
    ]

    private let prefs = UserDefaults.standard
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    @Published var accounts: [AccountItem] = []
    @Published var groups: [AccountGroup] = []
    @Published var scripts: [UserScript] = []
    @Published var windows: [GameWindow] = []

    @Published var maxWindows: Int = 2 {
        didSet { save() }
    }
    @Published var syncEnabled = false

    /// 脚本启用状态的变更计数，游戏窗口据此重新注入，无需重开
    @Published var scriptsRevision = 0

    /// true = 标签模式（一次显示一个，其余后台常驻）；false = 一屏多窗口
    @Published var tabMode = false

    /// 标签模式下当前激活的窗口 id
    @Published var activeWindowId: String?

    /**
     * true = 深夜模式，false = 白天模式。默认深夜，与原先写死的深色一致。
     *
     * 只影响软件外壳（列表页、顶栏、弹窗）。游戏本体是 WKWebView 里的
     * canvas 自绘，配色管不到它。
     */
    @Published var darkTheme = true

    init() {
        load()
        ensureDefaultGroup()
        purgeBuiltinAccount()
        // 用包内脚本清单的指纹判断要不要同步，而不是一次性布尔标志。
        // 之前用布尔值，升级后新增的脚本会因为标志已是 true 而被整段跳过。
        let stamp = PresetScripts.assetStamp()
        if prefs.string(forKey: Key.presetDone) != stamp {
            let (added, removed) = PresetScripts.syncInto(self)
            Log.preset("预置脚本同步: 新增 \(added), 移除 \(removed)")
            prefs.set(stamp, forKey: Key.presetDone)
        }
    }

    func setDarkTheme(_ on: Bool) {
        darkTheme = on
        prefs.set(on, forKey: Key.dark)
    }

    func setTabMode(_ on: Bool) {
        tabMode = on
        // 标签模式下同步器影响的是看不见的后台账号，切换时一律先关掉
        if on { syncEnabled = false }
        if on && activeWindowId == nil { activeWindowId = windows.first?.id }
        prefs.set(on, forKey: Key.tabMode)
    }

    /// 预置脚本导入，指定初始启用状态
    func addPresetScript(name: String, code: String, enabled: Bool, locked: Bool = false) {
        scripts.append(UserScript(
            name: name,
            code: code,
            // 常驻脚本必须启用，不给关
            enabled: enabled || locked,
            order: (scripts.map { $0.order }.max() ?? 0) + 1,
            locked: locked,
            preset: true
        ))
        save()
    }

    /// 升级时替换预置脚本的代码，保留用户的开关选择
    func updatePresetScript(id: String, code: String, locked: Bool) {
        guard let i = scripts.firstIndex(where: { $0.id == id }) else { return }
        let old = scripts[i]
        if old.code == code && old.locked == locked && old.preset { return }
        scripts[i] = UserScript(
            id: old.id, name: old.name, code: code,
            enabled: old.enabled || locked,
            order: old.order, locked: locked, preset: true
        )
        save()
        scriptsRevision += 1
    }

    /**
     * 清掉新包已不再内置的预置脚本。
     *
     * 只删 preset=true 的项。历史版本存的脚本没有这个标记，靠名字兜底
     * 识别，避免把用户自己导入的同名脚本连带删掉。
     */
    @discardableResult
    func removeStalePresets(_ keepNames: Set<String>) -> Int {
        let stale = scripts.filter { !keepNames.contains($0.name) && ($0.preset || Self.legacyPresetNames.contains($0.name)) }
        if stale.isEmpty { return 0 }
        scripts.removeAll { s in stale.contains { $0.id == s.id } }
        save()
        scriptsRevision += 1
        return stale.count
    }

    // MARK: - 读写

    private func load() {
        if let d = prefs.data(forKey: Key.groups), let v = try? decoder.decode([AccountGroup].self, from: d) { groups = v }
        if let d = prefs.data(forKey: Key.accounts), let v = try? decoder.decode([AccountItem].self, from: d) { accounts = v }
        if let d = prefs.data(forKey: Key.scripts), let v = try? decoder.decode([UserScript].self, from: d) { scripts = v }
        let mw = prefs.integer(forKey: Key.maxWin)
        if mw > 0 { maxWindows = mw }
        tabMode = prefs.bool(forKey: Key.tabMode)
        darkTheme = prefs.object(forKey: Key.dark) == nil ? true : prefs.bool(forKey: Key.dark)
    }

    func save() {
        prefs.set(try? encoder.encode(groups), forKey: Key.groups)
        prefs.set(try? encoder.encode(accounts), forKey: Key.accounts)
        prefs.set(try? encoder.encode(scripts), forKey: Key.scripts)
        prefs.set(maxWindows, forKey: Key.maxWin)
    }

    private func ensureDefaultGroup() {
        if groups.contains(where: { $0.id == AccountGroup.defaultId }) { return }
        groups.insert(
            AccountGroup(id: AccountGroup.defaultId, name: "未分组",
                         colorArgb: AccountGroup.palette[6].0, order: 0),
            at: 0
        )
        save()
    }

    /**
     * 早期版本会把 assets 里的 bin 作为内置账号写进本地存储。
     * 现已改为完全由用户导入，这里做一次性清理，避免升级后残留。
     */
    private func purgeBuiltinAccount() {
        if prefs.bool(forKey: Key.purgedBuiltin) { return }
        let builtins = accounts.filter { $0.builtin }
        if !builtins.isEmpty {
            let ids = Set(builtins.map { $0.id })
            accounts.removeAll { $0.builtin }
            windows.removeAll { ids.contains($0.accountId) }
            save()
            Log.store("已清理内置账号 \(builtins.count) 个")
        }
        prefs.set(true, forKey: Key.purgedBuiltin)
    }

    // MARK: - 账号

    @discardableResult
    func addAccount(name: String, bytes: [UInt8]) -> AccountItem {
        let item = AccountItem(
            name: name,
            binHex: Data(bytes).toHex(),
            order: (accounts.map { $0.order }.max() ?? 0) + 1
        )
        accounts.append(item)
        save()
        return item
    }

    @discardableResult
    func addAccount(name: String, data: Data) -> AccountItem {
        addAccount(name: name, bytes: data.hexBytes)
    }

    func removeAccount(id: String) {
        accounts.removeAll { $0.id == id }
        windows.removeAll { $0.accountId == id }
        save()
    }

    func renameAccount(id: String, to newName: String) {
        updateAccount(id) { $0.name = newName }
    }

    /// 主要账号固定在列表顶部，同一时间只有一个
    func setPrimary(id: String) {
        for i in accounts.indices {
            let want = accounts[i].id == id
            if accounts[i].isPrimary != want { accounts[i].isPrimary = want }
        }
        save()
    }

    func clearPrimary(id: String) {
        updateAccount(id) { $0.isPrimary = false }
    }

    func moveToGroup(accountId: String, groupId: String) {
        updateAccount(accountId) { $0.groupId = groupId }
    }

    func reorderAccount(from: Int, to: Int) {
        guard accounts.indices.contains(from), accounts.indices.contains(to) else { return }
        let item = accounts.remove(at: from)
        accounts.insert(item, at: to)
        for i in accounts.indices where accounts[i].order != i { accounts[i].order = i }
        save()
    }

    /// 排序：主要账号置顶，其余按 order
    func accountsInGroup(_ groupId: String) -> [AccountItem] {
        accounts.filter { $0.groupId == groupId }
            .sorted { a, b in
                if a.isPrimary != b.isPrimary { return a.isPrimary }
                return a.order < b.order
            }
    }

    private func updateAccount(_ id: String, _ block: (inout AccountItem) -> Void) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        block(&accounts[i])
        save()
    }

    // MARK: - 分组

    @discardableResult
    func addGroup(name: String, color: Int) -> AccountGroup {
        let g = AccountGroup(name: name, colorArgb: color,
                             order: (groups.map { $0.order }.max() ?? 0) + 1)
        groups.append(g)
        save()
        return g
    }

    func renameGroup(id: String, to newName: String) {
        updateGroup(id) { $0.name = newName }
    }

    func setGroupColor(id: String, color: Int) {
        updateGroup(id) { $0.colorArgb = color }
    }

    func removeGroup(id: String) {
        guard id != AccountGroup.defaultId else { return }
        for i in accounts.indices where accounts[i].groupId == id {
            accounts[i].groupId = AccountGroup.defaultId
        }
        groups.removeAll { $0.id == id }
        save()
    }

    private func updateGroup(_ id: String, _ block: (inout AccountGroup) -> Void) {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
        block(&groups[i])
        save()
    }

    // MARK: - 脚本

    @discardableResult
    func addScript(name: String, code: String) -> UserScript {
        let s = UserScript(name: name, code: code,
                           order: (scripts.map { $0.order }.max() ?? 0) + 1)
        scripts.append(s)
        save()
        scriptsRevision += 1
        return s
    }

    func toggleScript(id: String, enabled: Bool) {
        guard let i = scripts.firstIndex(where: { $0.id == id }) else { return }
        if scripts[i].locked { return }
        scripts[i].enabled = enabled
        save()
        scriptsRevision += 1
    }

    func removeScript(id: String) {
        if scripts.first(where: { $0.id == id })?.locked == true { return }
        scripts.removeAll { $0.id == id }
        save()
        scriptsRevision += 1
    }

    /// 已启用脚本列表，元素为 (id, 显示名, 代码)。
    /// 按脚本粒度返回，便于注入侧逐个记录状态、避免重复执行。
    func enabledScripts() -> [(String, String, String)] {
        scripts.filter { $0.enabled }
            .sorted { $0.order < $1.order }
            .map { ($0.id, $0.displayName, $0.code) }
    }

    // MARK: - 窗口

    @discardableResult
    func openWindow(_ account: AccountItem) -> GameWindow? {
        if windows.count >= maxWindows { return nil }
        let w = GameWindow(accountId: account.id,
                           title: account.displayName,
                           isSyncMaster: windows.isEmpty)
        windows.append(w)
        // 新开的窗口直接成为标签模式下的当前项
        activeWindowId = w.id
        return w
    }

    func closeWindow(id: String) {
        guard let idx = windows.firstIndex(where: { $0.id == id }) else { return }
        let wasMaster = windows[idx].isSyncMaster
        windows.removeAll { $0.id == id }
        if wasMaster && !windows.isEmpty { windows[0].isSyncMaster = true }
        // 关掉的正是当前标签时，落到相邻一项
        if activeWindowId == id {
            activeWindowId = windows.indices.contains(min(idx, windows.count - 1))
                ? windows[min(idx, windows.count - 1)].id : nil
        }
    }

    /// 标签模式下的当前窗口，越界或未设置时回退到第一个
    func currentWindow() -> GameWindow? {
        if let id = activeWindowId, let w = windows.first(where: { $0.id == id }) { return w }
        return windows.first
    }

    func accountOf(_ w: GameWindow) -> AccountItem? {
        accounts.first { $0.id == w.accountId }
    }
}
