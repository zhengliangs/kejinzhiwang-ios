import Foundation
import zlib

// 极简 HTTP 客户端。移植自安卓版 importer/Http.kt。
//
// 关键点是必须能自由设置 Referer / User-Agent —— 这些在 WKWebView 里
// 是禁止修改头，所以登录流程不能放到 JS 侧做。
//
// 关于 Host：安卓版为保险显式伪造了 Host，但所有端点的 Host 值与 URL
// 本身的 host 一致，而 Host 属于 URLSession 的保留头、设置会被忽略，
// 实际结果完全相同。这里保留字段顺序与其余请求头，语义不变。

struct HttpResponse {
    let status: Int
    let body: [UInt8]
    let headers: [String: String]

    var text: String { String(decoding: body, as: UTF8.self) }
    var data: Data { Data(body) }
}

enum HttpError: LocalizedError {
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .transport(let m): return m
        }
    }
}

private final class RedirectPolicy: NSObject, URLSessionTaskDelegate {
    let follow: Bool
    init(_ follow: Bool) { self.follow = follow }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(follow ? request : nil)
    }
}

enum Http {

    private static let timeout: TimeInterval = 20

    static func get(_ url: String,
                    headers: [String: String] = [:],
                    followRedirects: Bool = false) throws -> HttpResponse {
        try request("GET", url, headers, nil, followRedirects)
    }

    static func post(_ url: String,
                     headers: [String: String] = [:],
                     body: [UInt8]? = nil) throws -> HttpResponse {
        try request("POST", url, headers, body, false)
    }

    static func post(_ url: String,
                     headers: [String: String] = [:],
                     body: Data? = nil) throws -> HttpResponse {
        try request("POST", url, headers, body.map { [UInt8]($0) }, false)
    }

    private static func request(_ method: String,
                                _ url: String,
                                _ headers: [String: String],
                                _ body: [UInt8]?,
                                _ followRedirects: Bool) throws -> HttpResponse {
        guard let u = URL(string: url) else { throw HttpError.transport("非法 URL: \(url)") }
        var req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                             timeoutInterval: timeout)
        req.httpMethod = method
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let body { req.httpBody = Data(body) }

        let delegate = RedirectPolicy(followRedirects)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let sem = DispatchSemaphore(value: 0)
        var result: Result<HttpResponse, Error> = .failure(HttpError.transport("无响应"))

        let task = session.dataTask(with: req) { data, response, error in
            defer { sem.signal() }
            if let error {
                result = .failure(error)
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            var headerMap: [String: String] = [:]
            if let hr = response as? HTTPURLResponse {
                for (k, v) in hr.allHeaderFields {
                    if let ks = k as? String, let vs = v as? String { headerMap[ks] = vs }
                }
            }
            var raw = [UInt8](data ?? Data())
            let encoding = headerMap["Content-Encoding"]
                ?? headerMap["content-encoding"] ?? ""
            if encoding.contains("gzip"), let inflated = Gzip.decompress(raw) {
                raw = inflated
            }
            result = .success(HttpResponse(status: status, body: raw, headers: headerMap))
        }
        task.resume()
        _ = sem.wait(timeout: .now() + timeout + 10)

        switch result {
        case .success(let r): return r
        case .failure(let e): throw e
        }
    }
}

// MARK: - gzip

enum Gzip {

    /// 解压 gzip 数据。服务端在请求带 Accept-Encoding: gzip 时返回 gzip，
    /// 而该头是我们手动设的，URLSession 不会自动解压，所以这里自己处理。
    static func decompress(_ data: [UInt8]) -> [UInt8]? {
        guard data.count >= 18, data[0] == 0x1f, data[1] == 0x8b else { return nil }
        var p = 10
        let flg = data[3]
        if flg & 0x04 != 0 {           // FEXTRA
            guard p + 2 < data.count else { return nil }
            let xlen = Int(data[p]) | (Int(data[p + 1]) << 8)
            p += 2 + xlen
        }
        if flg & 0x08 != 0 {           // FNAME
            while p < data.count && data[p] != 0 { p += 1 }
            p += 1
        }
        if flg & 0x10 != 0 {           // FCOMMENT
            while p < data.count && data[p] != 0 { p += 1 }
            p += 1
        }
        if flg & 0x02 != 0 { p += 2 }  // FHCRC
        guard p < data.count else { return nil }
        return inflateRaw(Array(data[p...]))
    }

    private static func inflateRaw(_ src: [UInt8]) -> [UInt8]? {
        var stream = z_stream()
        stream.next_in = UnsafeMutablePointer<Bytef>(
            mutating: (src as [UInt8]).withUnsafeBufferPointer { $0.baseAddress }
        )
        stream.avail_in = uInt(src.count)

        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
        else { return nil }
        defer { inflateEnd(&stream) }

        var out = [UInt8](repeating: 0, count: max(src.count * 4, 1 << 16))
        var total = 0

        while true {
            if total == out.count {
                out.append(contentsOf: [UInt8](repeating: 0, count: out.count))
            }
            let written = out.withUnsafeMutableBufferPointer { buf -> Int in
                stream.next_out = buf.baseAddress!.advanced(by: total)
                stream.avail_out = uInt(out.count - total)
                let rc = inflate(&stream, Z_NO_FLUSH)
                if rc != Z_OK && rc != Z_STREAM_END && rc != Z_BUF_ERROR { return -1 }
                return Int(out.count - total) - Int(stream.avail_out)
            }
            if written < 0 { return nil }
            total += written
            if stream.avail_out > 0 { break }
        }
        return Array(out[0..<total])
    }
}
