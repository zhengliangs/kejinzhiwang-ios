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
                .onAppear { server.start() }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    // 从后台回来后本地服务可能已被系统回收
                    server.resume()
                }
        }
    }
}
