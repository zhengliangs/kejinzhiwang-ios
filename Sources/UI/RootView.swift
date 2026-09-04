import SwiftUI

// 根界面。移植自安卓版 ui/RootScreen.kt。
//
// 关键约束照搬安卓：游戏页必须始终留在视图树里。若跟随分支进出，
// WKWebView 会被销毁、游戏被迫重新加载，所以这里跟安卓一样用
// offset 把整层平移出屏幕，而不是按条件创建/销毁。

enum AppTab: Hashable {
    case accounts, scripts, games
}

struct RootView: View {

    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var server: ServerManager
    @Environment(\.palette) private var palette

    @State private var tab: AppTab = .accounts
    @State private var showImport = false
    // 每次启动都提示，避免被二次分发者拿去收费
    @State private var showNotice = true
    @State private var update: ReleaseInfo?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                TabView(selection: $tab) {
                    NavigationStack {
                        AccountsView(onOpenGame: { tab = .games },
                                     onOpenImport: { showImport = true })
                            .navigationTitle("账号管理")
                            .navigationBarTitleDisplayMode(.inline)
                    }
                    .tabItem { Label("账号", systemImage: "person.2") }
                    .tag(AppTab.accounts)

                    NavigationStack {
                        ScriptsView()
                            .navigationTitle("脚本管理")
                            .navigationBarTitleDisplayMode(.inline)
                    }
                    .tabItem { Label("脚本", systemImage: "curlybraces") }
                    .tag(AppTab.scripts)

                    NavigationStack {
                        Color.clear
                    }
                    .tabItem { Label("游戏", systemImage: "gamecontroller") }
                    .badge(store.windows.isEmpty ? 0 : store.windows.count)
                    .tag(AppTab.games)
                }

                // 游戏层常驻
                GamesView()
                    .background(palette.background)
                    .padding(.bottom, bottomInset(geo))
                    .offset(x: tab == .games ? 0 : geo.size.width * 2)
                    .allowsHitTesting(tab == .games)
            }
        }
        .tint(palette.primary)
        .fullScreenCover(isPresented: $showImport) {
            ImportView { showImport = false }
                .environmentObject(store)
                .environment(\.palette, store.darkTheme ? .dark : .light)
        }
        .sheet(isPresented: $showNotice) {
            FreeNoticeSheet { showNotice = false }
                .interactiveDismissDisabled(true)
        }
        .sheet(item: $update) { info in
            UpdateSheet(info: info)
        }
        // 免费声明确认后再查更新，两个弹窗不会叠在一起
        .onChange(of: showNotice) { showing in
            if showing { return }
            Task {
                if case .available(let info) = await UpdateChecker.check() {
                    await MainActor.run { update = info }
                }
            }
        }
    }

    /// 给底栏让出的高度（标准 49pt + 安全区）
    private func bottomInset(_ geo: GeometryProxy) -> CGFloat {
        49 + geo.safeAreaInsets.bottom
    }
}

// MARK: - 免费声明

/**
 * 只能点「我知道了」关闭：点外部或返回键都不消失，
 * 确保用户真的看到这段话。
 */
private struct FreeNoticeSheet: View {
    var onConfirm: () -> Void

    @Environment(\.palette) private var palette

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("本软件完全免费提供，不存在任何收费项目。")
                    .font(.body)
                    .foregroundStyle(palette.onSurface)

                Text("如果你是通过付费方式获得本软件的，说明你被骗了，请向对方索要退款。")
                    .font(.subheadline)
                    .foregroundStyle(palette.primary)

                Text("软件不会收取费用、不售卖卡密、不限制使用次数。")
                    .font(.caption)
                    .foregroundStyle(palette.onSurfaceVariant)

                Spacer()
            }
            .padding(20)
            .background(palette.background)
            .navigationTitle("免费声明")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("我知道了") { onConfirm() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - 更新

/**
 * 新版本提示。
 *
 * 安卓版点「下载」交给浏览器装 apk，iOS 上 App 内无法安装 ipa，
 * 所以这里提供两个出口：有 ipa 附件就走加速通道下载（再自行用
 * 全能签之类的工具签名安装），否则打开发布页。
 */
struct UpdateSheet: View {
    let info: ReleaseInfo

    @Environment(\.palette) private var palette
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("当前 \(UpdateChecker.currentVersionName())，新版 \(info.versionName)（\(info.sizeText)）")
                        .font(.caption)
                        .foregroundStyle(palette.onSurfaceVariant)

                    if !info.notes.isEmpty {
                        Text(info.notes)
                            .font(.subheadline)
                            .foregroundStyle(palette.onSurface)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(installHint)
                            .font(.caption)
                            .foregroundStyle(palette.onSurfaceVariant)
                    }
                    .padding(.top, 4)

                    Spacer(minLength: 0)
                }
                .padding(20)
            }
            .background(palette.background)
            .navigationTitle("发现新版本 \(info.versionName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("以后再说") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if info.hasIpa {
                        Button("下载 IPA") {
                            if let url = URL(string: UpdateChecker.preferredUrl(info.rawUrl)) {
                                openURL(url)
                            }
                            dismiss()
                        }
                    } else {
                        Button("前往发布页") {
                            if let url = URL(string: info.htmlUrl) { openURL(url) }
                            dismiss()
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var installHint: String {
        if info.hasIpa {
            return "下载走加速通道。ipa 是未签名的，装之前需要用全能签之类的工具签名；覆盖安装不会丢账号和脚本设置。"
        }
        return "这个版本没有提供 ipa 附件，请到发布页下载源文件自行打包。"
    }
}
