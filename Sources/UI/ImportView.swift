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

    // 入口回到系统文件选择器（.fileImporter），跟改版前一模一样。
    @State private var showQueryPicker = false    // 单选：选完反查区服
    @State private var showDirectPicker = false   // 多选：直接导入
    // 备用入口：同样是系统的文件 App，只是走 UIKit 那条路。正常用不到，
    // 留在这是为了上面两个万一调不出来时不至于彻底卡死。
    @State private var showFallbackPicker = false

    var body: some View {
        VStack(spacing: 10) {

            Button {
                vm.diag("[0] 打开文件选择器（单选·反查）")
                showQueryPicker = true
            } label: {
                HStack(spacing: 6) {
                    if vm.busy { ProgressView() }
                    Image(systemName: "doc.badge.plus")
                    Text("选一个 bin（反查区服）")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(vm.busy)
            Text("选好后自动解析这份 bin，查出该账号下所有区服的角色，勾选确认再导入。")
                .font(.caption)
                .foregroundStyle(palette.onSurfaceVariant)

            Spacer().frame(height: 18)
            Divider()
            Spacer().frame(height: 14)

            Button {
                vm.diag("[0] 打开文件选择器（多选·直接导入）")
                showDirectPicker = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc.on.doc")
                    Text("选择多个 bin 直接导入")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(vm.busy)
            Text("不反查区服，按文件原样导入。")
                .font(.caption)
                .foregroundStyle(palette.onSurfaceVariant)

            Spacer().frame(height: 12)

            Button("备用：用系统文件 App 选择") {
                vm.diag("[0] 打开备用选择器")
                showFallbackPicker = true
            }
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
                .frame(maxWidth: .infinity, maxHeight: 130)
                .background(palette.surface.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        // 单选：拿 bin 去反查区服
        .fileImporter(isPresented: $showQueryPicker,
                      allowedContentTypes: [.data],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                vm.diag("[0] 单选回调 urls=" + String(urls.count))
                guard let url = urls.first else {
                    vm.diag("[0] 回调成功但没有 URL")
                    vm.message = "没拿到文件，换备用入口试试"
                    return
                }
                loadAndQuery(url)
            case .failure(let err):
                vm.diag("[0] 选择失败: " + err.localizedDescription)
                vm.message = "选择失败：" + err.localizedDescription
            }
        }
        // 多选：原样导入
        .fileImporter(isPresented: $showDirectPicker,
                      allowedContentTypes: [.data],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                vm.diag("[0] 多选回调 urls=" + String(urls.count))
                importMany(urls)
            case .failure(let err):
                vm.diag("[0] 选择失败: " + err.localizedDescription)
                vm.message = "选择失败：" + err.localizedDescription
            }
        }
        // 备用入口
        .sheet(isPresented: $showFallbackPicker) {
            UIKitDocumentPicker(allowsMultiple: false) { urls in
                vm.diag("[0] 备用选择器回调 urls=" + String(urls.count))
                guard let url = urls.first else {
                    vm.diag("[0] 用户取消")
                    return
                }
                loadAndQuery(url)
            }
        }
    }

    /**
     * 读取选中的文件。
     *
     * 这里补的是之前「选好了点打开却毫无反应」的真正原因：
     * SwiftUI 的 fileImporter 给的是**原文件**的安全作用域 URL，不是拷贝件。
     * 不先 startAccessingSecurityScopedResource() 就读，系统会直接拒绝，
     * Data(contentsOf:) 抛权限错误 —— 错误被吞掉，界面上就一点动静都没有。
     */
    private func readFile(_ url: URL) -> Data? {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        vm.diag("[1] 授权=" + (accessed ? "已取得" : "无需/失败") + " · " + url.lastPathComponent)

        if let data = try? Data(contentsOf: url), !data.isEmpty {
            vm.diag("[1] 直读成功 字节=" + String(data.count))
            return data
        }
        // 直读失败多半是 iCloud 上的文件还没下载下来。
        // 复制到本地临时目录会强制触发下载。
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            try FileManager.default.copyItem(at: url, to: tmp)
            let data = try Data(contentsOf: tmp)
            vm.diag("[1] 复制后读取成功 字节=" + String(data.count))
            return data
        } catch {
            vm.diag("[1] 读取失败: " + error.localizedDescription)
            return nil
        }
    }

    private func loadAndQuery(_ url: URL) {
        vm.diag("[0] 选中: " + url.lastPathComponent)
        guard let data = readFile(url) else {
            vm.message = "文件读不出来，看下面日志"
            return
        }
        vm.diag("[2] 开始反查 字节=" + String(data.count))
        vm.queryFromBin(data)
    }

    private func importMany(_ urls: [URL]) {
        var n = 0
        for url in urls {
            guard url.lastPathComponent.lowercased().hasSuffix(".bin") else {
                vm.diag("[1] 跳过非 bin: " + url.lastPathComponent)
                continue
            }
            guard let data = readFile(url) else { continue }
            store.addAccount(name: url.deletingPathExtension().lastPathComponent, data: data)
            n += 1
        }
        vm.diag("[0] 成功导入=" + String(n))
        if n > 0 {
            onImported(n)
        } else {
            vm.message = "没有可导入的 bin 文件"
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

