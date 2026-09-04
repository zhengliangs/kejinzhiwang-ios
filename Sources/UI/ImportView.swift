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
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { onClose() }
                    }
                }
        }
        .tint(palette.primary)
        .background(palette.background)
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
            Picker("方式", selection: $method) {
                ForEach(Method.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(16)
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
                      allowedContentTypes: [.item]) { result in
            switch result {
            case .success(let url):
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url), !data.isEmpty else {
                    vm.message = "文件读取失败"
                    return
                }
                vm.queryFromBin(data)
            case .failure:
                vm.message = "文件读取失败"
            }
        }
        .fileImporter(isPresented: $showDirectPicker,
                      allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls) where !urls.isEmpty:
                var n = 0
                for url in urls {
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    guard url.lastPathComponent.lowercased().hasSuffix(".bin") else { continue }
                    guard let data = try? Data(contentsOf: url) else { continue }
                    store.addAccount(name: url.lastPathComponent, data: data)
                    n += 1
                }
                if n > 0 { imported = n } else { vm.message = "文件读取失败" }
            default:
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
