import Foundation
import WebKit
import UIKit

// 游戏容器。移植自安卓版 core/GameWebView.kt（对应 iOS 原版的
// GameWebView + Coordinator），不包含连点器。
//
// 与安卓版的差异只有三处，都是平台机制不同导致的，行为保持一致：
//  1. 早注入改用 WKUserScript(.atDocumentStart)，比在 didStart 里
//     evaluateJavaScript 更早也更可靠；注入顺序与内容一字未改。
//  2. AndroidBridge 由 bridgeShim 提供（转发到 WKScriptMessageHandler），
//     上面那批 JS 不用动。
//  3. 渲染进程终止对应 webViewWebContentProcessDidTerminate。

/// 主窗口触摸事件回调，用于同步器广播
typealias SyncTouchListener = (CGFloat, CGFloat) -> Void

final class GameWebViewHolder: NSObject {

    private(set) var webView: WKWebView!
    private let binHex: String
    private let binLabel: String
    private let scriptsProvider: () -> [(String, String, String)]

    /// 标签模式下同步源会随当前标签变化，需要运行时可改
    var isSyncMaster: Bool

    /// 同步器总开关。安卓版在构造时快照，切换开关后要重开窗口才生效；
    /// 这里改成可写，开关切换时由界面层同步更新，打开即生效、关闭即停。
    var syncEnabled: Bool

    var onSyncTouch: SyncTouchListener?
    var onScriptStatus: ((String) -> Void)?

    private var pageReady = false
    private var backgrounded = false
    /** 渲染进程已终止，此 WebView 不可再用 */
    private var webContentGone = false
    private let bridge = Bridge()

    private static let bgFps = 5
    private static let fgFps = 60

    init(binHex: String,
         binLabel: String,
         scriptsProvider: @escaping () -> [(String, String, String)],
         isSyncMaster: Bool,
         syncEnabled: Bool,
         onSyncTouch: SyncTouchListener?,
         onScriptStatus: ((String) -> Void)? = nil) {
        self.binHex = binHex
        self.binLabel = binLabel
        self.scriptsProvider = scriptsProvider
        self.isSyncMaster = isSyncMaster
        self.syncEnabled = syncEnabled
        self.onSyncTouch = onSyncTouch
        self.onScriptStatus = onScriptStatus
        super.init()
        webView = makeWebView()
    }

    deinit { destroy() }

    // MARK: - 构建

    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptEnabled = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.allowsInlineMediaPlayback = true
        // 对应 mediaPlaybackRequiresUserGesture = false
        config.mediaTypesRequiringUserActionForPlayback = []
        config.websiteDataStore = .default()
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        #if DEBUG
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        #endif

        let uc = WKUserContentController()
        // 页面开始加载时就要注入的脚本，越早越好。
        // 顺序与安卓版 injectEarly() 一致，只在最前面多了桥的定义。
        let early = [
            InjectScripts.bridgeShim,
            InjectScripts.compat,
            // 油猴 API 必须在任何用户脚本之前就位：脚本拿不到 GM_* 会静默退出
            InjectScripts.gmShim,
            InjectScripts.activateBin(binHex, binLabel),
            InjectScripts.xhrIntercept,
        ]
        for js in early {
            uc.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentStart,
                                          forMainFrameOnly: true))
        }
        bridge.owner = self
        uc.add(bridge, name: "naiwa")
        config.userContentController = uc

        let v = WKWebView(frame: .zero, configuration: config)
        v.navigationDelegate = self
        v.isOpaque = false
        v.backgroundColor = .black
        v.scrollView.backgroundColor = .black
        v.scrollView.isScrollEnabled = false
        v.scrollView.pinchGestureRecognizer?.isEnabled = false
        v.scrollView.bounces = false
        v.allowsBackForwardNavigationGestures = false
        v.allowsLinkPreview = false
        return v
    }

    // MARK: - 外部操作

    func load(_ url: String) {
        guard let u = URL(string: url) else { return }
        Log.game("HTTP加载: \(url)")
        webView.load(URLRequest(url: u, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 30))
    }

    func destroy() {
        runOnMain {
            self.webView?.stopLoading()
            self.webView?.configuration.userContentController.removeScriptMessageHandler(forName: "naiwa")
            self.webView?.removeFromSuperview()
        }
    }

    func reload() {
        Log.game("收到刷新通知")
        pageReady = false
        // 页面重载后 window 上下文重建，已注入记录随之失效，无需手动清理
        runOnMain { self.webView?.reload() }
    }

    func clearCache() {
        let types: Set<String> = [WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeDiskCache]
        WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: Date(timeIntervalSince1970: 0)) {
            Log.game("缓存已清除")
        }
    }

    func onLowMemory() {
        eval(InjectScripts.lowMemory)
    }

    /**
     * 标签模式下切到后台的窗口降到 5 帧，切回前台恢复。
     * 游戏逻辑与脚本靠 setInterval / 事件驱动，不受渲染帧率影响。
     */
    func setBackgrounded(_ background: Bool) {
        if webContentGone { return }
        if backgrounded == background { return }
        backgrounded = background
        // 只隐藏、不改布局尺寸：保留 frame 才不会触发重排导致画面错乱，
        // 但完全跳过绘制，后台窗口不再占用合成开销。
        runOnMain { self.webView?.isHidden = background }
        if !pageReady { return }
        eval(InjectScripts.setFrameRate(background ? Self.bgFps : Self.fgFps))
    }

    /** 副窗口收到主窗口的同步坐标 */
    func applySyncTouch(x: CGFloat, y: CGFloat) {
        guard pageReady else { return }
        eval("window.__applySyncTouch && window.__applySyncTouch(\(x), \(y));")
    }

    /** 同步器开关打开时补装两端，注入是幂等的 */
    func installSyncerIfNeeded() {
        guard pageReady, syncEnabled else { return }
        eval(InjectScripts.syncerSender)
        eval(InjectScripts.syncerReceiver)
    }

    // MARK: - 求值

    private func runOnMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }

    private func eval(_ js: String) {
        if webContentGone { return }
        runOnMain {
            self.webView?.evaluateJavaScript(js) { _, error in
                if let error { Log.game("JS 求值失败: \(error.localizedDescription)") }
            }
        }
    }

    // MARK: - 注入

    /// 页面加载完成后注入，与安卓版 injectLate() 一一对应
    private func injectLate() {
        // 兜一次：documentStart 注入的可能被页面导航清掉，
        // 而用户脚本是在这之后才装的，GM_* 必须存在
        eval(InjectScripts.gmShim)
        // 必须在用户脚本之前：VH_FIX 用 MutationObserver 盯新样式表，
        // 装晚了先注入的脚本样式就漏掉了
        eval(InjectScripts.vhFix)
        eval(InjectScripts.scriptUiFix)
        eval(InjectScripts.canvasGuard)
        if syncEnabled {
            // 两端都装：谁当同步源由 isSyncMaster 在运行时判断，
            // 标签模式下当前标签会变化，不能在注入时写死。
            eval(InjectScripts.syncerSender)
            eval(InjectScripts.syncerReceiver)
            Log.game("同步器已注入")
        }
        injectUserScripts()
        // 页面就绪前的降帧请求会被忽略，这里补上
        if backgrounded { eval(InjectScripts.setFrameRate(Self.bgFps)) }
    }

    /**
     * 注入用户脚本。内容通过 provider 实时读取而非构造时快照，
     * 因此脚本页改开关后无需重开窗口。
     *
     * 关键点：这些脚本依赖 window.__require，而它由游戏主包在运行时
     * 创建，didFinish 时通常还不存在。所以先轮询等待 __require 就绪
     * 再注入，而不是立刻执行。
     */
    func injectUserScripts() {
        if webContentGone {
            onScriptStatus?("渲染已终止，请刷新")
            return
        }
        if !pageReady {
            onScriptStatus?("页面未就绪")
            return
        }
        let list = scriptsProvider()
        if list.isEmpty {
            onScriptStatus?("无启用脚本")
            return
        }

        // 落盘后用 <script src> 加载，不把代码塞进 evaluateJavaScript。
        // 安卓上是必要的（Binder 约 1MB 上限，超了静默截断，表现就是
        // 脚本一直不显示）；iOS 上同样更省内存，且两边行为完全一致。
        let root = RendererCache.cachesDir()
        let published = ScriptCache.publish(root: root, scripts: list)
        if published.isEmpty {
            onScriptStatus?("脚本写入失败")
            return
        }

        // 逐个脚本独立注入并按 id 记录，已注入过的永不重复执行。
        // 之前整批拼成一个字符串共用一个标志，手动重注会把所有脚本
        // 重跑一遍——像自动蟠桃这类自身没做防重保护的脚本就会重复建 UI。
        let entries = published.map { "{id:\(Self.jsStr($0.id)),name:\(Self.jsStr($0.name)),url:\(Self.jsStr($0.url))}" }
            .joined(separator: ",")

        let js = """
(function(){
  var items = [\(entries)];
  window.__injectedScriptIds = window.__injectedScriptIds || {};
  var done = window.__injectedScriptIds;
  var live = {};
  items.forEach(function(it){ live[it.id] = 1; });
  // 已注入但现在被关掉的脚本：JS 执行过就无法撤销，只能刷新页面。
  // 明确告知而不是让用户反复点补注入却看不出变化。
  var stale = 0;
  for (var k in done) { if (done[k] && !live[k]) stale++; }
  var pending = items.filter(function(it){ return !done[it.id]; });
  if (pending.length === 0) {
    AndroidBridge.onScriptStatus(
      stale ? ('已关闭' + stale + '个，需刷新生效') : ('已全部注入 (' + items.length + ')')
    );
    return stale ? 'need_reload' : 'already';
  }
  // 按 src 逐个加载。串行执行是必须的：脚本之间可能有依赖，
  // 并行加载完成顺序不确定。
  function runAll(){
    var ok = 0, fail = 0, i = 0;
    function report(){
      AndroidBridge.onScriptStatus(
        '已注入 ' + ok + '/' + items.length +
        (fail ? (' 失败' + fail) : '') +
        (stale ? (' 关闭' + stale + '需刷新') : '')
      );
    }
    function next(){
      if (i >= pending.length) { report(); return; }
      var it = pending[i++];
      if (done[it.id]) { next(); return; }
      done[it.id] = true;    // 先置位，脚本内部报错也不重复执行
      var el = document.createElement('script');
      el.type = 'text/javascript';
      el.async = false;
      el.src = it.url;
      el.onload = function(){
        ok++;
        el.parentNode && el.parentNode.removeChild(el);
        next();
      };
      el.onerror = function(){
        fail++;
        // 加载失败要撤销标记，否则「补注入」会永远跳过这个脚本。
        // 与执行报错不同：文件没取到，脚本一行都没跑，重试是安全的。
        delete done[it.id];
        console.error('[奶蛙] 脚本加载失败: ' + it.name + ' <- ' + it.url);
        el.parentNode && el.parentNode.removeChild(el);
        next();
      };
      document.head.appendChild(el);
      // 每装一个就刷一次状态，大脚本加载慢时能看到进度
      if (i % 3 === 0) report();
    }
    next();
  }
  var tries = 0;
  function wait(){
    tries++;
    if (typeof window.__require === 'function') { runAll(); return; }
    if (tries > 240) {
      AndroidBridge.onScriptStatus('超时: 游戏模块未就绪，仍尝试注入');
      runAll();
      return;
    }
    if (tries % 20 === 0) {
      AndroidBridge.onScriptStatus('等待游戏加载... ' + Math.round(tries / 2) + 's');
    }
    setTimeout(wait, 500);
  }
  wait();
  return 'waiting:' + pending.length;
})();
"""
        runOnMain {
            self.webView?.evaluateJavaScript(js) { result, _ in
                Log.game("脚本注入流程: \(result.map { "\($0)" } ?? "nil")")
            }
        }
    }

    static func jsStr(_ s: String) -> String {
        "'" + s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "\\n") + "'"
    }

    // MARK: - 桥接消息

    fileprivate func handleBridge(_ body: [String: Any]) {
        guard let m = body["m"] as? String else { return }
        switch m {
        case "syncTouch":
            guard syncEnabled, isSyncMaster else { return }
            if let json = body["json"] as? String,
               let data = json.data(using: .utf8),
               let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let x = CGFloat(o.jsonDouble("x"))
                let y = CGFloat(o.jsonDouble("y"))
                onSyncTouch?(x, y)
            }

        case "scriptStatus":
            let msg = body["msg"] as? String ?? ""
            Log.game("脚本状态: \(msg)")
            runOnMain { self.onScriptStatus?(msg) }

        case "gmRequest":
            let reqId = body["id"] as? String ?? ""
            let options = body["options"] as? String ?? "{}"
            handleGmRequest(reqId, options)

        case "setClipboard":
            let text = body["text"] as? String ?? ""
            UIPasteboard.general.string = text

        case "saveImage":
            if let dataUrl = body["dataUrl"] as? String { saveImage(dataUrl) }

        default:
            break
        }
    }

    /**
     * GM_xmlhttpRequest 的原生转发。
     *
     * 油猴脚本靠它做跨域请求，而页面内的 XHR/fetch 受同源策略限制
     * 打不到外部域名。放到原生侧发就没有跨域概念，这也是油猴本身
     * 的实现方式。
     */
    private func handleGmRequest(_ reqId: String, _ optionsJson: String) {
        Task.detached(priority: .utility) { [weak self] in
            let payload = await self?.doGmRequest(optionsJson) ?? [:]
            let json = (try? JSONSerialization.data(withJSONObject: payload))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            let js = "window.__gmResolve && window.__gmResolve(" +
                "\(Self.jsStr(reqId)), \(Self.jsStr(json)))"
            await MainActor.run { self?.eval(js) }
        }
    }

    private func doGmRequest(_ optionsJson: String) async -> [String: Any] {
        guard let data = optionsJson.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let urlStr = o.jsonString("url"),
              let url = URL(string: urlStr)
        else { return ["error": "bad options", "status": 0] }

        let method = (o.jsonString("method") ?? "GET").uppercased()
        var body: String? = nil
        if let v = o["data"], !(v is NSNull) { body = "\(v)" }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = max(Double(o.jsonInt("timeout", 20000)) / 1000.0, 1.0)
        if let headers = o["headers"] as? [String: Any] {
            for (k, v) in headers { req.setValue("\(v)", forHTTPHeaderField: k) }
        }
        if let body {
            req.httpBody = Data(body.utf8)
            if req.value(forHTTPHeaderField: "Content-Type") == nil {
                req.setValue("application/json;charset=utf-8", forHTTPHeaderField: "Content-Type")
            }
        }

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let http = resp as? HTTPURLResponse
            // 4xx/5xx 的内容也在 data 里，脚本往往要读错误详情
            let text = String(data: data, encoding: .utf8)
                ?? String(decoding: data, as: UTF8.self)
            var headers = ""
            if let fields = http?.allHeaderFields {
                for (k, v) in fields { headers += "\(k): \(v)\r\n" }
            }
            return [
                "status": http?.statusCode ?? 0,
                "statusText": http.map { HTTPURLResponse.localizedString(forStatusCode: $0.statusCode) } ?? "",
                "responseText": text,
                "responseHeaders": headers,
                "finalUrl": http?.url?.absoluteString ?? urlStr,
            ]
        } catch {
            return ["error": error.localizedDescription, "status": 0]
        }
    }

    private func saveImage(_ dataUrl: String) {
        let b64 = dataUrl.components(separatedBy: "base64,").last ?? dataUrl
        guard let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters),
              let image = UIImage(data: data)
        else {
            Log.warn("saveImage: 无法创建图片")
            return
        }
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        Log.game("saveImage: 图片已保存到相册")
    }
}

// MARK: - WKNavigationDelegate

extension GameWebViewHolder: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        // 早注入由 WKUserScript(.atDocumentStart) 完成，见 makeWebView()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageReady = true
        injectLate()
    }

    /**
     * 渲染进程终止（内存不足或崩溃）。
     * 不处理的话 iOS 上就是一片白，界面层据此提示用户刷新。
     */
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webContentGone = true
        pageReady = false
        runOnMain { self.onScriptStatus?("内存不足被回收") }
        Log.warn("渲染进程已终止，窗口需要刷新")
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        Log.warn("页面加载失败: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Log.warn("页面加载失败: \(error.localizedDescription)")
    }
}

// MARK: - 桥

private final class Bridge: NSObject, WKScriptMessageHandler {
    weak var owner: GameWebViewHolder?

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        owner?.handleBridge(body)
    }
}
