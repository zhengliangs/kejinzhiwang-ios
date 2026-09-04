import SwiftUI
import WebKit

// 游戏窗口。移植自安卓版 ui/GamesScreen.kt。
//
// 两个关键约束照搬安卓：
//  1. WebView 实例必须跨重组存活 —— 安卓用 graphicsLayer 平移出屏幕，
//     iOS 上同样用 offset 平移，绝不跟随分支进出组合树，否则游戏会被
//     迫重新加载。
//  2. 隐藏后台窗口只改 isHidden，不动布局尺寸 —— 尺寸变化会触发重排，
//     画面会错乱。

// MARK: - 实例池

final class WindowPool: ObservableObject {

    private(set) var holders: [String: GameWebViewHolder] = [:]

    /// 各窗口的脚本状态，标签栏与标题条共用
    @Published var statuses: [String: String] = [:]

    private weak var store: AppStore?

    func attach(_ store: AppStore) { self.store = store }

    /// 按当前窗口列表对齐实例：新增的创建、消失的回收
    func sync(baseUrl: String?) {
        guard let store, let baseUrl else { return }
        let windows = store.windows
        let alive = Set(windows.map { $0.id })

        // 窗口关掉后回收对应实例
        for id in holders.keys where !alive.contains(id) {
            holders.removeValue(forKey: id)?.destroy()
            statuses.removeValue(forKey: id)
        }

        let tabMode = store.tabMode
        let currentId = store.currentWindow()?.id

        for w in windows where holders[w.id] == nil {
            guard let acc = store.accountOf(w) else { continue }
            // 初始值；标签模式下由 refreshForeground 随当前标签更新 isSyncMaster
            let master = tabMode ? (w.id == currentId) : w.isSyncMaster
            let holder = GameWebViewHolder(
                binHex: acc.binHex,
                binLabel: acc.displayName,
                scriptsProvider: { store.enabledScripts() },
                isSyncMaster: master,
                syncEnabled: store.syncEnabled,
                onSyncTouch: { [weak self, weak store] x, y in
                    // 主窗口触摸 -> 广播给其余窗口
                    guard let self, let store else { return }
                    for other in store.windows where other.id != w.id {
                        self.holders[other.id]?.applySyncTouch(x: x, y: y)
                    }
                },
                onScriptStatus: { [weak self] msg in
                    DispatchQueue.main.async {
                        self?.statuses[w.id] = msg
                    }
                }
            )
            holders[w.id] = holder
            holder.load("\(baseUrl)/index.html")
        }
    }

    /// 标签模式：只有当前标签保持前台帧率，其余降到 5 帧省电；
    /// 同步源也跟着当前标签走。
    func refreshForeground() {
        guard let store else { return }
        let tabMode = store.tabMode
        let currentId = store.currentWindow()?.id
        for w in store.windows {
            guard let h = holders[w.id] else { continue }
            let active = w.id == currentId
            h.setBackgrounded(tabMode && !active)
            h.isSyncMaster = tabMode ? active : w.isSyncMaster
        }
    }

    func setSyncEnabled(_ on: Bool) {
        for h in holders.values {
            h.syncEnabled = on
            if on { h.installSyncerIfNeeded() }
        }
    }

    func injectUserScripts() {
        for h in holders.values { h.injectUserScripts() }
    }

    func onLowMemory() {
        for h in holders.values { h.onLowMemory() }
    }

    func destroyAll() {
        for h in holders.values { h.destroy() }
        holders.removeAll()
        statuses.removeAll()
    }
}

// MARK: - WebView 容器

private struct WebViewBox: UIViewRepresentable {
    let holder: GameWebViewHolder

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        guard let wv = holder.webView else { return container }
        wv.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(wv)
        NSLayoutConstraint.activate([
            wv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            wv.topAnchor.constraint(equalTo: container.topAnchor),
            wv.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

// MARK: - 游戏页

struct GamesView: View {

    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var server: ServerManager
    @Environment(\.palette) private var palette

    @StateObject private var pool = WindowPool()
    @StateObject private var tip = TipState()

    private var current: GameWindow? { store.currentWindow() }

    var body: some View {
        ZStack(alignment: .top) {
            palette.background.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Divider().overlay(palette.surfaceVariant)

                content

                Spacer(minLength: 0)
            }

            TipHost(tip: tip, topPadding: 44)
        }
        .onAppear {
            pool.attach(store)
            pool.sync(baseUrl: server.baseUrl)
            pool.refreshForeground()
        }
        .onDisappear { /* 实例保留在池里，跟随 RootView 生命周期 */ }
        .onChange(of: server.baseUrl) { pool.sync(baseUrl: $0) }
        .onChange(of: store.windows.count) { _ in
            pool.sync(baseUrl: server.baseUrl)
            pool.refreshForeground()
        }
        .onChange(of: store.tabMode) { _ in pool.refreshForeground() }
        .onChange(of: store.activeWindowId) { _ in pool.refreshForeground() }
        // 脚本开关变动时立即注入到所有已开窗口，不必重开
        .onChange(of: store.scriptsRevision) { rev in
            if rev > 0 { pool.injectUserScripts() }
        }
        .onChange(of: store.syncEnabled) { pool.setSyncEnabled($0) }
        .onReceive(NotificationCenter.default.publisher(for: AppNotifications.lowMemory)) { _ in
            pool.onLowMemory()
        }
    }

    // MARK: - 顶栏

    private var topBar: some View {
        HStack(spacing: 10) {
            Text("窗口 \(store.windows.count)/\(store.maxWindows)")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(palette.onSurface)

            Spacer()

            // 显示模式：标签 / 一屏多窗口
            Button {
                let to = !store.tabMode
                // setTabMode 切到标签模式时会顺带关掉同步器，
                // 得在调用前记下原值，否则用户会以为同步自己关了
                let syncWasOn = store.syncEnabled
                store.setTabMode(to)
                let name = to ? "标签模式" : "分屏模式"
                tip.show(to && syncWasOn ? "已切换到\(name)，同步器已关闭" : "已切换到\(name)")
                pool.refreshForeground()
            } label: {
                Image(systemName: store.tabMode ? "rectangle.stack" : "square.grid.2x2")
                    .foregroundStyle(palette.primary)
            }

            // 同步器总开关
            Button {
                let on = !store.syncEnabled
                store.syncEnabled = on
                tip.show(on ? "已开启同步器" : "已关闭同步器")
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(store.syncEnabled ? palette.primary : palette.onSurfaceVariant)
            }

            // 窗口上限
            Menu {
                ForEach(1...AppStore.windowLimit, id: \.self) { n in
                    Button("\(n) 个窗口") {
                        store.maxWindows = n
                    }
                }
            } label: {
                Text("上限 \(store.maxWindows)")
                    .font(.subheadline)
                    .foregroundStyle(palette.primary)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(palette.background)
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if server.baseUrl == nil {
            EmptyHint("HTTP服务器未就绪")
        } else if store.windows.isEmpty {
            EmptyHint("暂无游戏窗口，去账号页点击账号卡片打开游戏")
        } else if store.tabMode {
            VStack(spacing: 0) {
                TabStrip(statuses: pool.statuses)
                ZStack {
                    ForEach(store.windows) { w in
                        if let holder = pool.holders[w.id] {
                            WindowPane(window: w, holder: holder,
                                       status: pool.statuses[w.id] ?? "",
                                       compact: false,
                                       showBar: w.id == current?.id)
                        }
                    }
                }
            }
        } else {
            grid
        }
    }

    /// 网格：游戏是竖屏内容，纯竖向等分会把每格压成宽扁条，
    /// 分成多列后单格长宽比才接近屏幕本身。
    private var grid: some View {
        let cols = columnsFor(store.windows.count)
        let rows = store.windows.chunked(cols)
        return VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 0) {
                    ForEach(row) { w in
                        if let holder = pool.holders[w.id] {
                            WindowPane(window: w, holder: holder,
                                       status: pool.statuses[w.id] ?? "",
                                       compact: store.windows.count > 1)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    // 末行不足一列时补空位，避免最后一个窗口被拉宽
                    ForEach(0..<(cols - row.count), id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 竖屏手机下的分列策略。屏幕约 9:16，游戏内容同为竖屏，
    /// 2×2 时单格比例与整屏一致，是多开的最佳情形。
    private func columnsFor(_ count: Int) -> Int {
        if count <= 2 { return 1 }   // 1~2 个走单列上下排，画面比横向切两半更宽
        if count <= 6 { return 2 }   // 3~4 个时 2×2 单格仍是 9:16
        return 3
    }
}

// MARK: - 标签栏

private struct TabStrip: View {
    let statuses: [String: String]

    @EnvironmentObject private var store: AppStore
    @Environment(\.palette) private var palette

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(store.windows) { w in
                    TabChip(title: w.title,
                            status: shortStatus(statuses[w.id]),
                            selected: w.id == store.currentWindow()?.id) {
                        store.activeWindowId = w.id
                    }
                }
            }
            .padding(.horizontal, 6)
        }
        .frame(height: 36)
        .background(palette.surface)
    }
}

private struct TabChip: View {
    let title: String
    let status: String
    let selected: Bool
    var onClick: () -> Void

    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: onClick) {
            Text(title + (status.isEmpty ? "" : "  \(status)"))
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(selected ? palette.onPrimary : palette.onSurfaceVariant)
                .frame(height: 27)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(selected ? palette.primary : palette.surfaceVariant)
                )
        }
        .buttonStyle(.plain)
    }
}

/// 标签宽度有限，把注入状态压成几个字
private func shortStatus(_ raw: String?) -> String {
    guard let raw else { return "" }
    if raw.hasPrefix("等待游戏加载") { return "加载中" }
    if raw.hasPrefix("已全部注入") { return "就绪" }
    if raw.hasPrefix("已注入") { return "就绪" }
    if raw.hasPrefix("无启用脚本") { return "" }
    if raw.hasPrefix("页面未就绪") { return "加载中" }
    if raw.hasPrefix("超时") { return "超时" }
    if raw.hasPrefix("执行出错") { return "出错" }
    return ""
}

// MARK: - 单个窗口

private struct WindowPane: View {
    let window: GameWindow
    let holder: GameWebViewHolder
    let status: String
    var compact: Bool
    var showBar: Bool = true

    @EnvironmentObject private var store: AppStore
    @Environment(\.palette) private var palette

    @State private var scriptStatus = ""

    private var barHeight: CGFloat { compact ? 22 : 30 }

    var body: some View {
        VStack(spacing: 0) {
            // 标签模式下各窗口互相重叠，非当前项的标题条要让位，
            // 但必须留出等高占位，否则 WebView 高度变化会引发重排。
            if showBar {
                titleBar
            } else {
                Color.clear.frame(height: barHeight)
            }

            WebViewBox(holder: holder)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var titleBar: some View {
        HStack(spacing: 4) {
            Text(caption)
                .font(compact ? .caption2 : .footnote)
                .foregroundStyle(palette.onSurface)
                .lineLimit(1)
            Spacer(minLength: 4)
            // 补注入尚未生效的脚本；已注入过的不会重复执行
            Button { holder.injectUserScripts() } label: {
                Image(systemName: "play.fill").font(.system(size: compact ? 9 : 11))
            }
            Button { holder.reload() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: compact ? 9 : 11))
            }
            Button { store.closeWindow(id: window.id) } label: {
                Image(systemName: "xmark").font(.system(size: compact ? 9 : 11))
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.onSurfaceVariant)
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(height: barHeight)
        .background(palette.surfaceVariant)
    }

    private var caption: String {
        var s = window.title
        if window.isSyncMaster && store.syncEnabled { s += " · 主" }
        if !status.isEmpty { s += " · \(status)" }
        return s
    }
}

// MARK: - 空态

struct EmptyHint: View {
    let text: String
    @Environment(\.palette) private var palette

    var body: some View {
        VStack {
            Spacer()
            Text(text)
                .font(.subheadline)
                .foregroundStyle(palette.onSurfaceVariant)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
