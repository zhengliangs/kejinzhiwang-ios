import SwiftUI
import UniformTypeIdentifiers

// 脚本管理。移植自安卓版 ui/ScriptsScreen.kt。
// 功能点：开关脚本、导入 .js、删除、主题切换、版本号与手动检查更新。

struct ScriptsView: View {

    @EnvironmentObject private var store: AppStore
    @Environment(\.palette) private var palette

    @State private var target: UserScript?
    @State private var showImporter = false
    @StateObject private var tip = TipState()

    private var canAct: Binding<Bool> {
        Binding(get: { target != nil }, set: { if !$0 { target = nil } })
    }

    private var sorted: [UserScript] { store.scripts.sorted { $0.order < $1.order } }

    var body: some View {
        ZStack(alignment: .top) {
            content
            TipHost(tip: tip, topPadding: 8)
        }
        .background(palette.background)
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { result in
            handleImport(result)
        }
        .confirmationDialog(target?.displayName ?? "", isPresented: canAct,
                            titleVisibility: .visible) {
            if let s = target {
                Button(s.enabled ? "禁用" : "启用") {
                    store.toggleScript(id: s.id, enabled: !s.enabled)
                    target = nil
                }
                if !s.locked {
                    Button("删除", role: .destructive) {
                        store.removeScript(id: s.id)
                        target = nil
                    }
                }
                Button("取消", role: .cancel) { target = nil }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.scripts.isEmpty {
            emptyState
        } else {
            scriptList
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.badge.plus")
                .font(.system(size: 44))
                .foregroundStyle(palette.onSurfaceVariant)
            Text("点击右上角 + 导入 .js 脚本文件")
                .font(.subheadline)
                .foregroundStyle(palette.onSurfaceVariant)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar { toolbarContent }
    }

    private var scriptList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                Text("开启脚本后可在游戏窗口标题栏点 ▶ 补注入，已生效的不会重复执行。" +
                     "关闭脚本必须刷新游戏才会移除 —— 已经跑起来的 JS 无法撤销，" +
                     "点 ▶ 对它没有作用。")
                    .font(.caption)
                    .foregroundStyle(palette.onSurfaceVariant)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)

                ForEach(sorted) { s in
                    ScriptRow(script: s) { target = s }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                }
                VersionFooter(tip: tip)
                Color.clear.frame(height: 16)
            }
        }
        .background(palette.background)
        .toolbar { toolbarContent }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            HStack(spacing: 14) {
                // 主题切换。只改软件外壳配色，游戏画面由 WebView 自绘，不受影响
                Button {
                    let next = !store.darkTheme
                    store.setDarkTheme(next)
                    tip.show(next ? "已切换到深夜模式" : "已切换到白天模式")
                } label: {
                    Image(systemName: store.darkTheme ? "moon.fill" : "sun.max.fill")
                }
                Button { showImporter = true } label: {
                    Image(systemName: "plus")
                }
            }
            .tint(palette.primary)
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure:
            tip.show("没有选择文件")
        case .success(let urls):
            if urls.isEmpty { tip.show("没有选择文件"); return }
            var n = 0
            for url in urls {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                guard url.lastPathComponent.lowercased().hasSuffix(".js") else { continue }
                guard let code = try? String(contentsOf: url, encoding: .utf8) else { continue }
                store.addScript(name: url.lastPathComponent, code: code)
                n += 1
            }
            tip.show(n > 0 ? "共导入 \(n) 个文件" : "文件读取失败")
        }
    }
}

// MARK: - 单行

private struct ScriptRow: View {
    let script: UserScript
    var onTap: () -> Void

    @EnvironmentObject private var store: AppStore
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(script.displayName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(palette.onSurface)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(script.locked ? palette.primary : palette.onSurfaceVariant)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { if !script.locked { onTap() } }

            Toggle("", isOn: Binding(
                get: { script.enabled },
                set: { store.toggleScript(id: script.id, enabled: $0) }
            ))
            .disabled(script.locked)
            .labelsHidden()
            .tint(palette.primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var subtitle: String {
        if script.locked { return "\(script.code.count) 字符 · 必需，无法关闭" }
        return "\(script.code.count) 字符" + (script.enabled ? " · 已启用" : "")
    }
}

// MARK: - 版本与更新

/**
 * 版本号与手动检查更新。放在列表底部，平时不占视线，
 * 但用户报问题时能一眼看到自己是哪个版本。
 */
private struct VersionFooter: View {
    let tip: TipState

    @Environment(\.palette) private var palette

    @State private var busy = false
    @State private var found: ReleaseInfo?
    @State private var showUpdate = false

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text("当前版本 \(UpdateChecker.currentVersionName())")
                    .font(.subheadline)
                    .foregroundStyle(palette.onSurface)
                Text("本软件免费，如遇收费即为诈骗")
                    .font(.caption)
                    .foregroundStyle(palette.onSurfaceVariant)
            }
            Spacer()
            Button {
                busy = true
                Task {
                    let r = await UpdateChecker.check()
                    await MainActor.run {
                        switch r {
                        case .available(let info): found = info
                        case .upToDate: tip.show("已是最新版本")
                        case .failed(let reason): tip.show("检查失败：\(reason)")
                        }
                        busy = false
                    }
                }
            } label: {
                Text(busy ? "检查中" : "检查更新")
                    .font(.subheadline)
            }
            .disabled(busy)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .sheet(item: $found) { info in
            UpdateSheet(info: info)
        }
    }
}
