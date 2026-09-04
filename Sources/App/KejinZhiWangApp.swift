import SwiftUI

@main
struct KejinZhiWangApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var store = AppStore()
    @StateObject private var server = ServerManager()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(server)
                .environment(\.palette, store.darkTheme ? .dark : .light)
                .preferredColorScheme(store.darkTheme ? .dark : .light)
                .onAppear {
                    server.start()
                    // 每次启动都把屏幕适配情况写进 import.log。
                    // 「上下黑边」到底是系统把 App 缩进了旧机型画布，还是 App
                    // 内部某个页面没铺满，全靠这一行数据区分。
                    LogFile.append("[启动] " + ScreenReport.line())
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    // 从后台回来后本地服务可能已被系统回收
                    server.resume()
                }
        }
    }
}
