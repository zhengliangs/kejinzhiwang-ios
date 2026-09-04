import Foundation
import Network

// 对应安卓版的 LocalHTTPServer。
//
// 游戏必须通过 http:// 而非 file:// 加载：Cocos 引擎会做跨域检查，
// 且 WebGL 上下文在 file:// 下受限（更重要的是 file:// 的 origin 是
// null，游戏向 hortorgames 发的登录 XHR 会被 CORS 直接拒掉）。
// 这里起一个只监听回环地址的极简 HTTP 服务，把解包后的 renderer/
// 目录当静态根目录提供。
//
// iOS 没有 ServerSocket，用 Network.framework 的 NWListener 实现。

final class LocalHttpServer {

    private static let authHint = try? NSRegularExpression(
        pattern: "device-auth|card-keys|device-config|licen[cs]e|/auth/",
        options: .caseInsensitive
    )

    private static let mime: [String: String] = [
        "html": "text/html; charset=utf-8",
        "js": "application/javascript; charset=utf-8",
        "css": "text/css; charset=utf-8",
        "json": "application/json",
        "wasm": "application/wasm",
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "webp": "image/webp",
        "ico": "image/x-icon",
        "mp3": "audio/mpeg",
        "ogg": "audio/ogg",
        "wav": "audio/wav",
        "ttf": "font/ttf",
        "woff": "font/woff",
        "woff2": "font/woff2",
    ]

    private let rootDir: URL
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.sharkking.assistant.httpserver")

    private(set) var port: UInt16 = 0

    init(rootDir: URL) { self.rootDir = rootDir }

    var baseUrl: String { "http://127.0.0.1:\(port)" }

    var isRunning: Bool { listener != nil }

    /// 启动。端口传 0 让系统自动分配，避免固定端口被占用。
    /// 端口要等 listener 进入 ready 才拿得到，所以是异步回调。
    func start(onReady: ((String?) -> Void)? = nil) {
        stop()
        guard FileManager.default.fileExists(atPath: rootDir.path) else {
            Log.http("目录不存在: \(rootDir.path)")
            onReady?(nil)
            return
        }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            // 只监听回环，不对外暴露
            params.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: .ipv4(IPv4Address("127.0.0.1")!), port: 0
            )
            let listener = try NWListener(using: params, on: 0)
            self.listener = listener

            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if let p = listener.port {
                        self.port = p.rawValue
                        Log.http("服务器已就绪: \(self.baseUrl)")
                        onReady?(self.baseUrl)
                    }
                case .failed(let error):
                    Log.http("监听失败: \(error.localizedDescription)")
                    onReady?(nil)
                case .cancelled:
                    self.port = 0
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in
                self?.handle(conn)
            }
            listener.start(queue: queue)
        } catch {
            Log.http("无法创建监听器: \(error.localizedDescription)")
            onReady?(nil)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = 0
    }

    /// App 从后台回来后 socket 可能已被系统回收，这里兜一次重启
    func ensureRunning(onReady: ((String?) -> Void)? = nil) {
        guard let listener else { start(onReady: onReady); return }
        if case .failed = listener.state {
            start(onReady: onReady)
        } else if case .cancelled = listener.state {
            start(onReady: onReady)
        }
    }

    // MARK: - 连接处理

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(connection, Data())
    }

    private func receiveRequest(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }

            // 只处理请求行与请求头，body 用不上（纯静态服务）
            if let range = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = buf[buf.startIndex..<range.lowerBound]
                self.respond(connection, head)
                return
            }
            if isComplete || error != nil {
                if buf.isEmpty == false { self.respond(connection, buf) }
                else { connection.cancel() }
                return
            }
            self.receiveRequest(connection, buf)
        }
    }

    private func respond(_ connection: NWConnection, _ head: Data) {
        guard let text = String(data: head, encoding: .utf8),
              let requestLine = text.components(separatedBy: "\r\n").first
        else { connection.cancel(); return }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { connection.cancel(); return }
        let rawPath = String(parts[1]).components(separatedBy: "?")[0]
            .components(separatedBy: "#")[0]
        let path = rawPath.removingPercentEncoding ?? rawPath
        serveFile(path, connection)
    }

    private func serveFile(_ path: String, _ connection: NWConnection) {
        let rel = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let target = rootDir.appendingPathComponent(rel.isEmpty ? "index.html" : rel)

        // 防目录穿越：解析后的真实路径必须仍在根目录内
        let canonicalRoot = rootDir.standardizedFileURL.path
        let canonicalTarget = target.standardizedFileURL.path
        if canonicalTarget != canonicalRoot && !canonicalTarget.hasPrefix(canonicalRoot + "/") {
            Log.http("路径越界拒绝: \(path)")
            writeStatus(connection, 403, "Forbidden")
            return
        }

        guard FileManager.default.fileExists(atPath: target.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: target.path),
              attrs[.type] as? FileAttributeType == .typeRegular
        else {
            // 脚本用 location.origin 拼接自己的后端地址时，请求会打到这里。
            // 这类路径不是缺文件，而是脚本在找它自己的服务器，单独记一条
            // 日志便于排查。
            let body = try? Data(contentsOf: target)
            if body == nil {
                if let re = Self.authHint,
                   re.firstMatch(in: rel, range: NSRange(rel.startIndex..., in: rel)) != nil {
                    Log.http("脚本把后端请求发到了本地服务: /\(rel)")
                } else {
                    Log.http("文件未找到: \(path)")
                }
            }
            writeStatus(connection, 404, "Not Found")
            return
        }

        let ext = (target.lastPathComponent as NSString).pathExtension.lowercased()
        let mime = Self.mime[ext] ?? "application/octet-stream"
        let length = (attrs[.size] as? NSNumber)?.int64Value ?? 0

        var header = "HTTP/1.1 200 OK\r\n"
        header += "Content-Type: \(mime)\r\n"
        header += "Content-Length: \(length)\r\n"
        header += "Access-Control-Allow-Origin: *\r\n"
        header += "Cache-Control: no-cache\r\n"
        header += "Connection: close\r\n\r\n"

        connection.send(content: Data(header.utf8), contentContext: .defaultMessage,
                        isComplete: false, completion: .contentProcessed { error in
            if let error {
                Log.http("响应头发送失败: \(error.localizedDescription)")
                connection.cancel()
                return
            }
            // 流式拷贝而不是一次性读入内存：游戏资源和大脚本动辄几 MB，
            // 整份读进内存在多开时会叠加，容易触发内存警告把进程杀掉。
            self.streamFile(target, to: connection)
        })
    }

    private func streamFile(_ url: URL, to connection: NWConnection, at offset: UInt64 = 0) {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            connection.cancel()
            return
        }
        defer { try? handle.close() }
        if offset > 0 { handle.seek(toFileOffset: offset) }

        func pump() {
            let chunk = handle.readData(ofLength: 64 * 1024)
            if chunk.isEmpty {
                connection.send(content: nil, contentContext: .defaultMessage,
                                isComplete: true, completion: .contentProcessed { _ in
                    // 保持原样：连接随即关闭
                })
                return
            }
            connection.send(content: chunk, contentContext: .defaultMessage,
                            isComplete: false, completion: .contentProcessed { error in
                if let error {
                    Log.http("数据发送失败: \(error.localizedDescription)")
                    connection.cancel()
                    return
                }
                pump()
            })
        }
        pump()
    }

    private func writeStatus(_ connection: NWConnection, _ code: Int, _ text: String) {
        let body = Data(text.utf8)
        let header = "HTTP/1.1 \(code) \(text)\r\n" +
            "Content-Type: text/plain; charset=utf-8\r\n" +
            "Content-Length: \(body.count)\r\n" +
            "Connection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + body,
                        contentContext: .defaultMessage,
                        isComplete: true,
                        completion: .contentProcessed { _ in })
    }
}
