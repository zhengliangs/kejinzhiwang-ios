import Foundation
import UIKit

// 本地 HTTP 服务的生命周期管理。
//
// 安卓版在 MainActivity.onCreate 里同步起服务，iOS 上 NWListener 要等
// listener 进入 ready 才拿得到端口，所以这里做成可观察状态：
// 界面层在 baseUrl 就绪前显示「HTTP服务器未就绪」，与安卓表现一致。

final class ServerManager: ObservableObject {

    @Published private(set) var baseUrl: String?

    private let server: LocalHttpServer
    private let rendererDir: URL

    init() {
        rendererDir = RendererCache.ensure()
        server = LocalHttpServer(rootDir: rendererDir)
    }

    var rendererRoot: URL { rendererDir }

    func start() {
        guard baseUrl == nil else { return }
        server.start { [weak self] url in
            DispatchQueue.main.async { self?.baseUrl = url }
        }
    }

    /// App 从后台回来后 socket 可能已被系统回收，这里兜一次重启
    func resume() {
        server.ensureRunning { [weak self] url in
            if let url {
                DispatchQueue.main.async { self?.baseUrl = url }
            }
        }
    }

    func stop() {
        server.stop()
        DispatchQueue.main.async { self.baseUrl = nil }
    }
}

// MARK: - 内存告警广播

enum AppNotifications {
    static let lowMemory = Notification.Name("com.sharkking.assistant.lowMemory")
}

final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions:
                     [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // 多开挂机时不息屏，与安卓版保持一致的挂机体验
        UIApplication.shared.isIdleTimerDisabled = true
        return true
    }

    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        // 交由各窗口自行降频，见 GameWebViewHolder.onLowMemory
        NotificationCenter.default.post(name: AppNotifications.lowMemory, object: nil)
    }

    func applicationWillTerminate(_ application: UIApplication) {
        UIApplication.shared.isIdleTimerDisabled = false
    }
}
