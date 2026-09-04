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
    @State private var update: ReleaseInfo?
    // GamesView 平移用：通过 GeometryReader 取屏幕宽
    @State private var screenWidth: CGFloat = UIScreen.main.bounds.width

    var body: some View {
        // 关键：不要再用 GeometryReader 包整个 body —— 那会让 fullScreenCover
        // 的容器被 GeometryReader 的 size proposal 限制为 TabView 的可见区，
        // 导致 ImportView 看起来"悬浮在中间、底部 TabBar 还能看到"。
        // 这里把 GeometryReader 拆出去，只裹真正需要 geo 的 GamesView 平移层。
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

            // 游戏层常驻 —— 用容器相对 frame 放到 TabBar 之上
            GamesView()
                .background(palette.background)
                .padding(.bottom, tabBarHeight)
                .offset(x: tab == .games ? 0 : screenWidth * 2)
                .allowsHitTesting(tab == .games)
                // GeometryReader 只裹这一处：拿到 width 用来平移
                .background(GeometryReader { geo in
                    Color.clear
                        .onAppear { screenWidth = geo.size.width }
                        .onChange(of: geo.size.width) { screenWidth = $0 }
                })
        }
        .tint(palette.primary)
        // fullScreenCover 直接挂在 ZStack 上：保证是真正的全屏覆盖
        .fullScreenCover(isPresented: $showImport) {
            ImportView { showImport = false }
                .environmentObject(store)
                .environment(\.palette, store.darkTheme ? .dark : .light)
        }
        .sheet(item: $update) { info in
            UpdateSheet(info: info)
        }
        // 启动后查一次更新
        .task {
            if case .available(let info) = await UpdateChecker.check() {
                update = info
            }
        }
    }

    /// TabBar 的高度（标准 49pt + 底部安全区）
    private var tabBarHeight: CGFloat {
        let bottom = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.windows.first?.safeAreaInsets.bottom }
            .first ?? 0
        return 49 + bottom
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
