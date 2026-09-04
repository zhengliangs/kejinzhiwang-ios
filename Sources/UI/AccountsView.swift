import SwiftUI

// 账号列表。移植自安卓版 ui/AccountsScreen.kt。
// 功能点一一对应：分组折叠、主要账号置顶、打开游戏、移动分组、重命名、
// 单账号导出、批量导出到文件夹、删除。

struct AccountsView: View {

    @EnvironmentObject private var store: AppStore
    @Environment(\.palette) private var palette

    var onOpenGame: () -> Void
    var onOpenImport: () -> Void

    @State private var actionTarget: AccountItem?
    @State private var showNewGroup = false
    @State private var renameGroupTarget: AccountGroup?
    @State private var moveTarget: AccountItem?
    @State private var renameTarget: AccountItem?
    @State private var collapsed: Set<String> = []

    // 待导出的账号，等用户在系统选择器里选好位置后写入
    @State private var exportPending: AccountItem?
    @State private var exportDoc: BinDocument?
    @State private var exportName = ""
    @State private var showExporter = false
    @State private var showFolderPicker = false

    @StateObject private var tip = TipState()

    private var canAct: Binding<Bool> {
        Binding(get: { actionTarget != nil }, set: { if !$0 { actionTarget = nil } })
    }

    private var canMove: Binding<Bool> {
        Binding(get: { moveTarget != nil }, set: { if !$0 { moveTarget = nil } })
    }

    var body: some View {
        VStack(spacing: 0) {
            // 屏幕适配自检：兼容模式下会变成醒目的一条，用来区分
            // 「系统把 App 缩进了 4.7 寸画布」和「App 内部布局没铺满」
            ScreenDiag()
            ZStack(alignment: .top) {
                content
                TipHost(tip: tip, topPadding: 8)
            }
        }
        .background(palette.background)
    }

    @ViewBuilder
    private var content: some View {
        if store.accounts.isEmpty {
            emptyState
        } else {
            accountList
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 44))
                .foregroundStyle(palette.onSurfaceVariant)
            Text("点右上角 + 导入账号")
                .font(.subheadline)
                .foregroundStyle(palette.onSurfaceVariant)
            Text("微信扫码、手机号，或选 bin 文件")
                .font(.caption)
                .foregroundStyle(palette.onSurfaceVariant)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.background)
        .toolbar { toolbarContent }
        .sheet(isPresented: $showNewGroup) {
            GroupEditSheet(title: "创建分组", initialName: "",
                           initialColor: AccountGroup.palette[0].0) { name, color in
                store.addGroup(name: name, color: color)
            }
        }
    }

    private var accountList: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: []) {
                ForEach(store.groups.sorted { $0.order < $1.order }) { group in
                    let list = store.accountsInGroup(group.id)
                    let isCollapsed = collapsed.contains(group.id)
                    GroupHeader(
                        group: group,
                        count: list.count,
                        collapsed: isCollapsed,
                        onToggle: {
                            if isCollapsed { collapsed.remove(group.id) }
                            else { collapsed.insert(group.id) }
                        },
                        onManage: { renameGroupTarget = group }
                    )
                    if !isCollapsed {
                        ForEach(list) { acc in
                            AccountCard(account: acc, groupColor: Color(argb: group.colorArgb))
                                .onTapGesture { actionTarget = acc }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                        }
                    }
                }
                Color.clear.frame(height: 24)
            }
            .padding(.top, 4)
        }
        .background(palette.background)
        .toolbar { toolbarContent }
        .sheet(isPresented: $showNewGroup) {
            GroupEditSheet(title: "创建分组", initialName: "",
                           initialColor: AccountGroup.palette[0].0) { name, color in
                store.addGroup(name: name, color: color)
            }
        }
        .sheet(item: $renameGroupTarget) { group in
            GroupEditSheet(
                title: "分组管理",
                initialName: group.name,
                initialColor: group.colorArgb,
                allowDelete: group.id != AccountGroup.defaultId,
                onDelete: { store.removeGroup(id: group.id) }
            ) { name, color in
                store.renameGroup(id: group.id, to: name)
                store.setGroupColor(id: group.id, color: color)
            }
        }
        .sheet(isPresented: canMove) {
            if let acc = moveTarget { GroupMoveSheet(account: acc) { moveTarget = nil } }
        }
        .confirmationDialog(actionTarget?.displayName ?? "", isPresented: canAct,
                            titleVisibility: .visible) {
            if let acc = actionTarget {
                Button("打开游戏") { openGame(acc) }
                Button(acc.isPrimary ? "取消主要账号" : "设为主要账号") {
                    if acc.isPrimary { store.clearPrimary(id: acc.id) }
                    else { store.setPrimary(id: acc.id) }
                    actionTarget = nil
                }
                Button("移动到分组…") { moveTarget = acc; actionTarget = nil }
                Button("重命名") { renameTarget = acc; actionTarget = nil }
                Button("导出为 .bin 文件") { beginExport(acc) }
                Button("删除", role: .destructive) {
                    store.removeAccount(id: acc.id)
                    actionTarget = nil
                    tip.show("已删除 \(acc.displayName)")
                }
                Button("取消", role: .cancel) { actionTarget = nil }
            }
        }
        .textInputDialog(title: "重命名",
                         initial: renameTarget?.displayName ?? "",
                         isPresented: Binding(
                            get: { renameTarget != nil },
                            set: { if !$0 { renameTarget = nil } })
        ) { newName in
            if let acc = renameTarget { store.renameAccount(id: acc.id, to: newName) }
            renameTarget = nil
        }
        .fileExporter(isPresented: $showExporter,
                      document: exportDoc ?? BinDocument(data: Data()),
                      contentType: .data,
                      defaultFilename: exportName) { result in
            let name = exportName
            switch result {
            case .success:
                tip.show("已导出 \(name)")
            case .failure(let error):
                tip.show("导出失败: \(error.localizedDescription)")
            }
            exportPending = nil
            exportDoc = nil
        }
        .sheet(isPresented: $showFolderPicker) {
            FolderPicker { url in
                let text = AccountExporter.exportAll(store.accounts, to: url)
                tip.show(text)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            HStack(spacing: 14) {
                if !store.accounts.isEmpty {
                    Button { showFolderPicker = true } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                }
                Button { showNewGroup = true } label: {
                    Image(systemName: "folder.badge.plus")
                }
                // 统一入口：扫码 / 手机号 / bin（直接添加或反查区服）都在导入页里
                Button { onOpenImport() } label: {
                    Image(systemName: "plus")
                }
            }
            .tint(palette.primary)
        }
    }

    // MARK: - 动作

    private func openGame(_ acc: AccountItem) {
        let w = store.openWindow(acc)
        actionTarget = nil
        if w == nil {
            tip.show("最多同时开启 \(store.maxWindows) 个游戏窗口")
        } else {
            onOpenGame()
        }
    }

    private func beginExport(_ acc: AccountItem) {
        exportName = "\(acc.displayName).bin"
        exportDoc = BinDocument(data: acc.binData)
        exportPending = acc
        actionTarget = nil
        showExporter = true
    }
}

// MARK: - 分组头

private struct GroupHeader: View {
    let group: AccountGroup
    let count: Int
    let collapsed: Bool
    var onToggle: () -> Void
    var onManage: () -> Void

    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color(argb: group.colorArgb))
                .frame(width: 12, height: 12)
            Text(group.name)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(palette.onSurface)
            Text("(\(count))")
                .font(.caption)
                .foregroundStyle(palette.onSurfaceVariant)
            Spacer()
            Button("管理") { onManage() }
                .font(.caption)
                .tint(palette.primary)
            Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                .font(.caption)
                .foregroundStyle(palette.onSurfaceVariant)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(palette.surfaceVariant)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
    }
}

// MARK: - 账号卡片

private struct AccountCard: View {
    let account: AccountItem
    let groupColor: Color

    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(groupColor)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(account.displayName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(palette.onSurface)
                        .lineLimit(1)
                    if account.isPrimary {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(Color(hex: 0xFFC107))
                    }
                }
                Text("\(account.sizeBytes) 字节")
                    .font(.caption)
                    .foregroundStyle(palette.onSurfaceVariant)
            }
            Spacer()
        }
        .padding(14)
        .background(palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - 移动分组

private struct GroupMoveSheet: View {
    let account: AccountItem
    var onDismiss: () -> Void

    @EnvironmentObject private var store: AppStore
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.groups.sorted { $0.order < $1.order }) { g in
                    Button {
                        store.moveToGroup(accountId: account.id, groupId: g.id)
                        dismiss()
                        onDismiss()
                    } label: {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(Color(argb: g.colorArgb))
                                .frame(width: 14, height: 14)
                            Text(g.name)
                                .foregroundStyle(palette.onSurface)
                            Spacer()
                            if g.id == account.groupId {
                                Text("当前")
                                    .font(.caption)
                                    .foregroundStyle(palette.onSurfaceVariant)
                            }
                        }
                    }
                }
            }
            .navigationTitle("选择目标分组")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss(); onDismiss() }
                }
            }
        }
    }
}
