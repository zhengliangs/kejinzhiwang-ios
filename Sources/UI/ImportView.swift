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
    @State private var showQueryPicker = false
    @State private var showDirectPicker = false

    var body: some View {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.background.ignoresSafeArea())
        .ignoresSafeArea(.keyboard)
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
            case .bin: BinPane(vm: vm, showQueryPicker: $showQueryPicker,
                               showDirectPicker: $showDirectPicker)
            }
        }
        .background(palette.background)
        .fileImporter(isPresented: $showQueryPicker,
                      // [.data] 让系统显示全部文件，.item 作兜底
                      allowedContentTypes: [.data, .item],
                      allowsMultipleSelection: false) { result in
            // SwiftUI fileImporter 回调永远是 [URL]（无论是否多选），取首个
            switch result {
            case .success(let urls):
                vm.diag("[0] 文件选择回调触发，urls=" + String(urls.count))
                guard let url = urls.first else {
                    vm.diag("[0] 回调触发了但 urls 为空")
                    vm.message = "未选择文件"
                    return
                }
                vm.diag("[0] 选中: " + url.lastPathComponent)
                let accessed = url.startAccessingSecurityScopedResource()
                vm.diag("[0] 安全访问授权=" + String(accessed))
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
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
            case .failure(let err):
                vm.diag("[0] 用户取消或系统拒绝: " + err.localizedDescription)
                vm.message = "未选择文件：" + err.localizedDescription
            }
        }
        .fileImporter(isPresented: $showDirectPicker,
                      allowedContentTypes: [.data, .item],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls) where !urls.isEmpty:
                vm.diag("[0] 文件选择回调触发（直接导入），urls=" + String(urls.count))
                var n = 0
                for url in urls {
                    vm.diag("[0] 处理: " + url.lastPathComponent)
                    let accessed = url.startAccessingSecurityScopedResource()
                    vm.diag("[0] 安全访问授权=" + String(accessed))
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    guard url.lastPathComponent.lowercased().hasSuffix(".bin") else {
                        vm.diag("[1] 跳过非 .bin: " + url.lastPathComponent)
                        continue
                    }
                    do {
                        let data = try Data(contentsOf: url)
                        vm.diag("[1] 读取字节=" + String(data.count))
                        store.addAccount(name: url.lastPathComponent, data: data)
                        n += 1
                    } catch {
                        vm.diag("[1] 读取失败: " + error.localizedDescription)
                    }
                }
                vm.diag("[0] 成功导入=" + String(n))
                if n > 0 { imported = n } else { vm.message = "文件读取失败" }
            case .success(let urls):
                vm.diag("[0] 成功但未选到文件")
                vm.message = "没有选择文件"
            case .failure(let err):
                vm.diag("[0] 用户取消或系统拒绝: " + err.localizedDescription)
                vm.message = "没有选择文件"
            }
        }
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
    @Binding var showQueryPicker: Bool
    @Binding var showDirectPicker: Bool

    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 10) {
            Button {
                showQueryPicker = true
            } label: {
                HStack(spacing: 8) {
                    if vm.busy { ProgressView() }
                    Text("选一个 bin，反查全部区服")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(vm.busy)

            Text("读出文件里绑定的账号，把该账号下所有区服的角色列出来供你挑选。已绑定某个区服的 bin 也能反查。")
                .font(.caption)
                .foregroundStyle(palette.onSurfaceVariant)

            Spacer().frame(height: 22)
            Divider()
            Spacer().frame(height: 22)

            Button("直接添加 bin 文件（可多选）") { showDirectPicker = true }
                .buttonStyle(.bordered)
                .disabled(vm.busy)

            Text("不查区服，原样导入。适合手上已经有一批区服 bin 的情况。")
                .font(.caption)
                .foregroundStyle(palette.onSurfaceVariant)

            // —— 诊断日志：界面上直接显示每一步，方便截图反馈问题 ——
            if !vm.diagLog.isEmpty {
                Divider()
                HStack {
                    Text("操作日志")
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
                .frame(maxWidth: .infinity, maxHeight: 110)
                .background(palette.surface.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

