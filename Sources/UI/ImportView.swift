import SwiftUI
import UniformTypeIdentifiers

// 导入页。移植自安卓版 ui/ImportScreen.kt。
//
// 三条路径是对等的：都只是「取得账号级登录态」的不同手段，
// 拿到之后查区服、展开成每区服一份 bin 的流程完全共用。

struct ImportView: View {

    @EnvironmentObject private var store: AppStore
    @Environment(\.palette) private var palette

    var onClose: () -> Void

    @StateObject private var vm = ImportViewModel()

    private enum Method: String, CaseIterable, Identifiable {
        case scan = "微信扫码"
        case sms = "手机号"
        case bin = "bin 文件"
        var id: String { rawValue }
    }

    @State private var method: Method = .scan
    @State private var imported = 0

    var body: some View {
        // 用 UIScreen.main.bounds 强制固定全屏尺寸，绕开 fullScreenCover 在
        // 某些 iOS 版本下把容器限制为父视图可见区导致「悬浮中间 + 底部留黑」的渲染问题
        NavigationStack {
            content
                .navigationTitle("导入账号")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    // 关闭按钮放在 navigationBarTrailing（右上），避免与下方 Picker 重叠
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("关闭", action: onClose)
                            .font(.subheadline.weight(.medium))
                    }
                }
        }
        .tint(palette.primary)
        .frame(width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.height)
        .background(palette.background.ignoresSafeArea())
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var content: some View {
        if vm.stage == .picking {
            RolePicker(vm: vm, onImport: {
                let bins = vm.buildSelected()
                for b in bins { store.addAccount(name: b.fileName.deletingSuffix(".bin"), data: b.data) }
                imported = bins.count
                vm.reset()
            }, onCancel: { vm.reset() })
        } else if imported > 0 {
            donePane
        } else {
            formPane
        }
    }

    private var donePane: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("已导入 \(imported) 个账号")
                .font(.headline)
                .foregroundStyle(palette.onSurface)
            Text("去账号页查看。点账号卡片即可启动游戏。")
                .font(.caption)
                .foregroundStyle(palette.onSurfaceVariant)
            HStack(spacing: 12) {
                Button("继续导入") { imported = 0 }
                Button("完成") { onClose() }
            }
            Spacer()
        }
        .padding(16)
        .background(palette.background)
    }

    private var formPane: some View {
        VStack(spacing: 0) {
            // 版本号常驻，方便确认测试的是不是最新包
            Text("v" + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"))
                .font(.caption2)
                .foregroundStyle(palette.onSurfaceVariant.opacity(0.7))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 16)
                .padding(.top, 4)

            Picker("方式", selection: $method) {
                ForEach(Method.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 12)
            .onChange(of: method) { _ in vm.reset() }

            if !vm.message.isEmpty {
                Text(vm.message)
                    .font(.caption)
                    .foregroundStyle(palette.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            switch method {
            case .scan: ScanPane(vm: vm)
            case .sms: SmsPane(vm: vm)
            case .bin: BinPane(vm: vm, onImported: { imported = $0 })
            }
        }
        .background(palette.background)
    }
}

// MARK: - 扫码

private struct ScanPane: View {
    @ObservedObject var vm: ImportViewModel
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 14) {
            if let image = vm.qrImage {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(width: 240, height: 240)
                    .padding(8)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(vm.qrHint)
                    .font(.subheadline)
                    .foregroundStyle(palette.onSurface)
                Button("刷新二维码") { vm.startQrLogin() }
            } else {
                Spacer().frame(height: 40)
                if vm.busy {
                    ProgressView()
                    Text("获取中...")
                        .font(.subheadline)
                        .foregroundStyle(palette.onSurfaceVariant)
                } else {
                    Button("获取二维码") { vm.startQrLogin() }
                        .buttonStyle(.borderedProminent)
                }
            }

            Spacer().frame(height: 24)
            Text("扫码后会读取该微信绑定的全部游戏角色，为每个区服生成一份账号数据。授权页显示的是游戏本身。")
                .font(.caption)
                .foregroundStyle(palette.onSurfaceVariant)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if vm.qrImage == nil && !vm.busy && vm.stage == .idle { vm.startQrLogin() }
        }
    }
}

// MARK: - 短信

private struct SmsPane: View {
    @ObservedObject var vm: ImportViewModel
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 12) {
            TextField("手机号", text: $vm.mobile)
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
                .onChange(of: vm.mobile) { vm.mobile = String($0.filter(\.isNumber).prefix(11)) }

            HStack(spacing: 8) {
                TextField("验证码", text: $vm.smsCode)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: vm.smsCode) { vm.smsCode = String($0.filter(\.isNumber).prefix(6)) }

                Button {
                    vm.sendSms()
                } label: {
                    Text(vm.countdown > 0 ? "\(vm.countdown)s" : "发送验证码")
                        .font(.subheadline)
                        .frame(width: 96)
                }
                .buttonStyle(.bordered)
                .disabled(vm.countdown > 0 || vm.busy)
            }

            Button {
                vm.loginBySms()
            } label: {
                HStack(spacing: 8) {
                    if vm.busy { ProgressView() }
                    Text("登录并查询区服")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(vm.busy)
            .padding(.top, 4)

            Text("使用游戏绑定的手机号登录，会读取该账号下全部区服的角色。")
                .font(.caption)
                .foregroundStyle(palette.onSurfaceVariant)
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - bin 文件

private struct BinPane: View {
    @ObservedObject var vm: ImportViewModel
    /// 父组件传进来的「成功导入 N 个」回调
    var onImported: (Int) -> Void

    @Environment(\.palette) private var palette
    @EnvironmentObject private var store: AppStore

    // UIKit 版整机文件选择器（能浏览整个「文件 App」，bin 放哪都能选到）
    @State private var showUIKitQuery = false   // 单选：反查
    @State private var showUIKitDirect = false  // 多选：直接导入
    // 内置沙盒扫描器（bin 已在氪金之王目录时可用）
    @State private var showLocalQueryPicker = false
    @State private var showLocalDirectPicker = false

    var body: some View {
        VStack(spacing: 10) {

            // ====== 第一入口：浏览整个「文件 App」（推荐，最省事）=====
            Button {
                vm.diag("[0] 打开整机文件选择器（单选·反查）")
                showUIKitQuery = true
            } label: {
                HStack(spacing: 6) {
                    if vm.busy { ProgressView() }
                    Image(systemName: "doc.badge.plus")
                    Text("从整个「文件 App」选一个 bin")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(vm.busy)
            Text("会弹出文件选择器，bin 在 iCloud / 下载 / 微信存的文件里都能直接选，不用提前放到 App 目录。选中后自动反查区服。")
                .font(.caption)
                .foregroundStyle(palette.onSurfaceVariant)

            Spacer().frame(height: 16)
            Divider()
            Spacer().frame(height: 16)

            Button("从「文件 App」批量添加 bin（直接导入）") { showUIKitDirect = true }
                .buttonStyle(.bordered)
                .disabled(vm.busy)
            Text("不反查，原样导入多份 bin。")
                .font(.caption)
                .foregroundStyle(palette.onSurfaceVariant)

            Spacer().frame(height: 18)
            Divider()
            Spacer().frame(height: 14)

            // ====== 第二入口：从氪金之王自己的目录选（bin 已放进沙盒时）======
            HStack {
                Button {
                    vm.diag("[0] 打开本地 bin 选择器（单选）")
                    showLocalQueryPicker = true
                } label: {
                    Image(systemName: "folder")
                    Text("氪金之王目录·单选")
                }
                .font(.subheadline)
                .buttonStyle(.bordered)

                Button {
                    vm.diag("[0] 打开本地 bin 选择器（多选）")
                    showLocalDirectPicker = true
                } label: {
                    Image(systemName: "folder")
                    Text("氪金之王目录·多选")
                }
                .font(.subheadline)
                .buttonStyle(.bordered)
            }
            Text("仅当 bin 已拷进「文件App → 我的iPhone → 氪金之王」目录时，这里的列表才有内容。")
                .font(.caption2)
                .foregroundStyle(palette.onSurfaceVariant)

            // —— 诊断日志：界面上直接显示每一步，方便截图反馈问题 ——
            if !vm.diagLog.isEmpty {
                Divider()
                HStack {
                    Text("操作日志（也写入 import.log）")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(palette.onSurfaceVariant)
                    Spacer()
                    Button("清空") { vm.clearDiag() }
                        .font(.caption2)
                        .foregroundStyle(palette.primary)
                }
                ScrollView {
                    Text(vm.diagLog)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(palette.onSurface)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, maxHeight: 130)
                .background(palette.surface.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        // ===== UIKit 整机文件选择器 =====
        // 单选：用 asCopy=true，系统把文件拷到 App Inbox 后回调 URL
        .sheet(isPresented: $showUIKitQuery) {
            UIKitDocumentPicker(allowsMultiple: false) { urls in
                vm.diag("[0] 整机选择器回调，urls=" + String(urls.count))
                guard let url = urls.first else {
                    vm.diag("[0] 用户取消，未选文件")
                    return
                }
                vm.diag("[0] 选中(拷贝后): " + url.lastPathComponent)
                loadAndQuery(url)
            }
        }
        // 多选：直接导入
        .sheet(isPresented: $showUIKitDirect) {
            UIKitDocumentPicker(allowsMultiple: true) { urls in
                vm.diag("[0] 整机选择器回调（多选），urls=" + String(urls.count))
                var n = 0
                for url in urls {
                    vm.diag("[0] 处理: " + url.lastPathComponent)
                    guard url.lastPathComponent.lowercased().hasSuffix(".bin") else {
                        vm.diag("[1] 跳过非 .bin: " + url.lastPathComponent)
                        continue
                    }
                    guard let data = try? Data(contentsOf: url) else {
                        vm.diag("[1] 读取失败: " + url.lastPathComponent)
                        continue
                    }
                    vm.diag("[1] 读取字节=" + String(data.count))
                    store.addAccount(name: url.lastPathComponent, data: data)
                    n += 1
                }
                vm.diag("[0] 成功导入=" + String(n))
                if n > 0 { onImported(n) } else { vm.message = "没有可导入的 bin 文件" }
            }
        }
        // 内置沙盒扫描器：单选（反查）
        .sheet(isPresented: $showLocalQueryPicker) {
            LocalBinPicker(title: "选一个 bin", multiSelect: false) { picked in
                guard let file = picked.first else { return }
                vm.diag("[0] 本地选择: " + file.url.lastPathComponent)
                loadAndQuery(file.url)
            }
        }
        // 内置沙盒扫描器：多选（直接导入）
        .sheet(isPresented: $showLocalDirectPicker) {
            LocalBinPicker(title: "选 bin 文件（可多选）", multiSelect: true) { picked in
                vm.diag("[0] 本地批量选择: " + String(picked.count) + " 个")
                var n = 0
                for file in picked {
                    guard let data = try? Data(contentsOf: file.url) else {
                        vm.diag("[1] 读取失败: " + file.url.lastPathComponent)
                        continue
                    }
                    vm.diag("[1] 读取字节=" + String(data.count) + " " + file.url.lastPathComponent)
                    store.addAccount(name: file.url.lastPathComponent, data: data)
                    n += 1
                }
                vm.diag("[0] 成功导入=" + String(n))
                if n > 0 { onImported(n) } else { vm.message = "文件读取失败" }
            }
        }
    }

    private func loadAndQuery(_ url: URL) {
        vm.diag("[0] 单选回调: " + url.lastPathComponent)
        do {
            let data = try Data(contentsOf: url)
            vm.diag("[1] 读取字节数=" + String(data.count))
            guard !data.isEmpty else {
                vm.message = "文件为空"
                return
            }
            vm.queryFromBin(data)
        } catch {
            vm.diag("[1] 读取失败: " + error.localizedDescription)
            vm.message = "文件读取失败：" + error.localizedDescription
        }
    }
}

// MARK: - 角色选择

private struct RolePicker: View {
    @ObservedObject var vm: ImportViewModel
    var onImport: () -> Void
    var onCancel: () -> Void

    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("已选 \(vm.selected.count)/\(vm.roles.count)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(palette.onSurface)
                Spacer()
                Button(vm.selected.count < vm.roles.count ? "全选" : "全不选") {
                    vm.selectAll(vm.selected.count < vm.roles.count)
                }
                .font(.subheadline)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Divider()

            List {
                ForEach(Array(vm.roles.enumerated()), id: \.offset) { i, role in
                    Button {
                        vm.toggle(i)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: vm.selected.contains(i) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(vm.selected.contains(i) ? palette.primary : palette.onSurfaceVariant)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(role.name)
                                    .font(.subheadline)
                                    .foregroundStyle(palette.onSurface)
                                    .lineLimit(1)
                                Text("\(role.serverId)服 · 战力\(role.powerText()) · ID\(role.roleId)")
                                    .font(.caption)
                                    .foregroundStyle(palette.onSurfaceVariant)
                            }
                        }
                    }
                    .listRowBackground(vm.selected.contains(i)
                        ? palette.primary.opacity(0.08)
                        : palette.surface)
                }
            }
            .listStyle(.plain)

            HStack(spacing: 12) {
                Button("取消") { onCancel() }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                Button("导入 \(vm.selected.count) 个") { onImport() }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    .disabled(vm.selected.isEmpty)
            }
            .padding(12)
        }
    }
}

