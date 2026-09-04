import Foundation

// 检查 GitHub 上的新版本。移植自安卓版 core/UpdateChecker.kt。
//
// iOS 差异：安卓盯的是 .apk 附件，这里盯 .ipa；如果发布里没挂 ipa
// （比如只挂了源码包），就退回「前往发布页」，让用户自己下载。
// 装包一律交给外部：iOS 上 App 内无法安装 ipa，需要用全能签之类的工具。

struct ReleaseInfo: Identifiable {
    var id: String { versionName }

    /// 展示用版本名，如 1.0.95
    let versionName: String
    /// 比对用的数值版本，由 tag 推导
    let versionCode: Int
    /// 发布说明，即 release 正文
    let notes: String
    /// ipa 附件直链，可能为空
    let rawUrl: String
    /// 发布页地址，始终有
    let htmlUrl: String
    /// 附件字节数，0 表示未知
    let sizeBytes: Int64

    var sizeText: String {
        sizeBytes <= 0 ? "未知大小" : String(format: "%.1f MB", Double(sizeBytes) / 1_048_576.0)
    }

    var hasIpa: Bool { !rawUrl.isEmpty }
}

enum UpdateResult {
    /// 有新版
    case available(ReleaseInfo)
    /// 已是最新
    case upToDate
    /// 查不动（断网、被墙、接口限流），静默处理
    case failed(String)
}

enum UpdateChecker {

    /// 更新检查指向的仓库，改仓库只需改这里
    static let updateRepo = "gterryd/naiwa-release"

    /**
     * 下载加速通道。国内直连 GitHub 常年几十 KB/s，镜像能快一到两个数量级。
     * 镜像随时可能失效，所以留多个按顺序兜底，最后一项是直连。
     */
    static let mirrors = [
        "https://gh-proxy.com/",
        "https://ghproxy.net/",
        "https://ghfast.top/",
        "", // 直连兜底
    ]

    /// 把 tag 或版本名解析成可比较的整数。1.0.95 -> 10095
    static func parseVersionCode(_ raw: String) -> Int {
        var nums: [Int] = []
        var cur = ""
        for ch in raw.trimmingCharacters(in: .whitespaces).drop(while: { $0 == "v" || $0 == "V" }) {
            if ch.isNumber { cur.append(ch) }
            else if !cur.isEmpty { nums.append(Int(cur) ?? 0); cur = "" }
        }
        if !cur.isEmpty { nums.append(Int(cur) ?? 0) }
        if nums.isEmpty { return 0 }
        let major = nums.indices.contains(0) ? nums[0] : 0
        let minor = nums.indices.contains(1) ? nums[1] : 0
        let patch = nums.indices.contains(2) ? nums[2] : 0
        return major * 1_000_000 + minor * 10_000 + patch
    }

    /// 本机版本，与 parseVersionCode 同一量纲
    static func currentVersionCode() -> Int {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        return parseVersionCode(short)
    }

    static func currentVersionName() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    /// 给下载直链套上加速前缀
    static func mirrorUrls(_ rawUrl: String) -> [String] {
        mirrors.map { $0.isEmpty ? rawUrl : $0 + rawUrl }
    }

    /// 首选下载地址
    static func preferredUrl(_ rawUrl: String) -> String { mirrorUrls(rawUrl).first ?? rawUrl }

    static func check() async -> UpdateResult {
        do {
            guard let info = try await fetchLatest() else {
                return .failed("没有找到可用的发布")
            }
            return info.versionCode > currentVersionCode() ? .available(info) : .upToDate
        } catch {
            Log.update("检查更新失败: \(error.localizedDescription)")
            return .failed(error.localizedDescription)
        }
    }

    private static func fetchLatest() async throws -> ReleaseInfo? {
        let api = "https://api.github.com/repos/\(updateRepo)/releases/latest"
        guard let url = URL(string: api) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("zaipan-updater", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            Log.update("接口返回 \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            return nil
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj.jsonString("tag_name"), !tag.isEmpty
        else { return nil }

        var url1 = ""
        var size: Int64 = 0
        if let assets = obj.jsonArray("assets") {
            for a in assets {
                if (a.jsonString("name") ?? "").lowercased().hasSuffix(".ipa") {
                    url1 = a.jsonString("browser_download_url") ?? ""
                    size = Int64(a.jsonDouble("size"))
                    break
                }
            }
        }
        let htmlUrl = obj.jsonString("html_url") ?? "https://github.com/\(updateRepo)/releases/latest"
        if url1.isEmpty { Log.update("发布里没有 ipa 附件，只提供发布页: \(htmlUrl)") }

        let name = obj.jsonString("name") ?? ""
        return ReleaseInfo(
            versionName: (name.isEmpty ? tag : name).deletingPrefix("v"),
            versionCode: parseVersionCode(tag),
            notes: (obj.jsonString("body") ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            rawUrl: url1,
            htmlUrl: htmlUrl,
            sizeBytes: size
        )
    }
}

extension String {
    func deletingPrefix(_ prefix: String) -> String {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
    }
}
