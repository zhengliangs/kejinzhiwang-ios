import Foundation

// 微信扫码授权与手机号验证码登录。移植自安卓版 importer/WxLogin.kt。
//
// 全部走原生 HTTP：需要伪造 Referer / UA / X-Requested-With，
// 这些在 WKWebView 里属于禁止修改头。

struct ImportError: LocalizedError {
    let msg: String
    init(_ msg: String) { self.msg = msg }
    var errorDescription: String? { msg }
}

/// 二维码申请结果
struct QrTicket {
    let uuid: String
    let imageData: Data
}

/// 轮询结果：状态 + 授权成功时的 code
struct QrPollResult {
    let state: WxScanState
    let code: String?
}

enum WxLogin {

    /// 短信验证码类型。服务端只回「参数错误」不说明合法值，
    /// 需要抓一次官方 App 的真实请求才能确定。
    static let smsCodeType = "login"

    /// 申请二维码，返回 uuid 与 PNG 字节
    static func createQrCode() throws -> QrTicket {
        _ = DeviceInfo.newSession()
        let res = try Http.get(
            XyEndpoints.qrConnect(),
            headers: [
                "Connection": "keep-alive",
                "Upgrade-Insecure-Requests": "1",
                "User-Agent": XyEndpoints.uaWxAndroid,
                "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9," +
                    "image/webp,image/apng,*/*;q=0.8",
                "Accept-Language": "zh-CN,zh;q=0.9,en-US;q=0.8,en;q=0.7",
                // 微信内置浏览器会带宿主包名
                "X-Requested-With": "com.muhua.w0",
            ]
        )
        let html = res.text

        // uuid 只出现在二维码图片地址里：
        // <img class="auth_qrcode" src="https://open.weixin.qq.com/connect/qrcode/XXXX">
        guard let uuid = Regex.first(#"qrcode/([A-Za-z0-9_\-]+)"#, in: html)
            ?? Regex.first(#"uuid=([A-Za-z0-9_\-]+)"#, in: html)
            ?? Regex.first(#""uuid"\s*:\s*"([^"]+)""#, in: html)
        else {
            throw ImportError("未能解析二维码 uuid。响应片段: " +
                Regex.collapse(html.prefix(150)))
        }

        let img = try Http.get(
            XyEndpoints.qrImage(uuid),
            headers: [
                "User-Agent": XyEndpoints.uaWxAndroid,
            ]
        )
        if img.status != 200 || img.body.isEmpty {
            throw ImportError("二维码图片下载失败 (HTTP \(img.status))")
        }
        Log.importer("二维码已获取 uuid=\(uuid) 图片=\(img.body.count)字节")
        return QrTicket(uuid: uuid, imageData: img.data)
    }

    /// 轮询扫码状态。返回 CONFIRMED 时 code 非空
    static func pollQrCode(_ uuid: String) throws -> QrPollResult {
        let res = try Http.get(
            XyEndpoints.qrPoll(uuid),
            headers: ["User-Agent": XyEndpoints.uaWxAndroid]
        )
        let body = res.text

        let errCode = Regex.first(#"wx_errcode\s*=\s*(\d+)"#, in: body).flatMap { Int($0) } ?? -1
        let state = WxScanState.of(errCode)
        if state != .confirmed { return QrPollResult(state: state, code: nil) }

        // 响应形如 window.wx_redirecturl='https://...?code=xxx&state=weixin';
        // 值一定被引号包裹，所以要匹配引号内的整段，不能把引号放进排除集
        guard let redirect = Regex.first(#"wx_redirecturl\s*=\s*['"]([^'"]*)['"]"#, in: body),
              !redirect.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw ImportError("授权成功但跳转地址为空。响应: \(body.prefix(200))")
        }
        guard let code = Regex.first(#"[?&]code=([^&'"]+)"#, in: redirect) else {
            throw ImportError("跳转地址中没有 code: \(redirect)")
        }
        Log.importer("扫码授权成功")
        return QrPollResult(state: state, code: code)
    }

    /// 发送短信验证码。
    /// 关键点：accountNum 放的是手机号本身（不是数量），而且必须带上
    /// 整套设备与包体信息，缺字段服务端一律回「参数错误」。
    static func sendSmsCode(_ mobile: String) throws {
        guard Regex.fullMatch("^1[3-9]\\d{9}$", mobile) else {
            throw ImportError("手机号格式不正确")
        }
        // 开一次新会话：后续登录复用同一设备身份，避免被判成换设备
        let device = DeviceInfo.newSession()
        var payload = JsonObject()
        payload.put("gameId", "xyzwapp")
        payload.put("gameTp", "app")
        payload.put("accountNum", mobile)
        payload.put("sysInfo", device.sysInfo())
        payload.put("activeLoginMatchId", device.activeLoginMatchId())
        payload.put("channel", "android")
        payload.put("verifyCodeTp", "login")
        payload.put("distinctId", device.distinctId)
        payload.put("oaidThirdSdk", "")
        payload.put("ipv6", "")
        payload.put("limit", true)
        payload.put("packageName", XyEndpoints.bundleId)
        payload.put("signPrint", XyEndpoints.signPrint)
        payload.put("androidId", device.androidId)
        payload.put("oaId", "")
        payload.put("oaid", "")

        let res = try Http.post(
            XyEndpoints.smsCode(),
            headers: [
                "Content-Type": "application/json; charset=utf-8",
                "User-Agent": XyEndpoints.uaApp,
                "Accept-Encoding": "gzip",
            ],
            body: try payload.toData()
        )
        Log.importer("发送验证码 HTTP \(res.status): \(res.text.prefix(300))")
        if res.status != 200 { throw ImportError("发送失败 (HTTP \(res.status))") }

        // 错误信息包在 meta 里，不在顶层
        guard let o = jsonParseObject(res.text) else {
            throw ImportError("响应不是 JSON: \(res.text.prefix(120))")
        }
        let meta = o.jsonObj("meta")
        let err = meta?.jsonInt("errCode") ?? o.jsonInt("errCode")
        if err != 0 {
            let msg = meta?.jsonString("errMsg") ?? o.jsonString("errMsg") ?? ""
            throw ImportError("发送失败: \(msg) (errCode=\(err))")
        }
    }

    /// 拉取加密规则（码本）。免鉴权 GET。
    /// 参数里的 version 必须与登录时一致，否则服务端按另一套规则解密会失败。
    static func fetchCryptRule(_ device: DeviceInfo) throws -> CodeBookCrypto.Rule {
        let res = try Http.get(
            XyEndpoints.cryptMix(device.deviceUniqueId),
            headers: [
                "User-Agent": XyEndpoints.uaIOS,
                "Accept": "*/*",
                "Accept-Language": "zh-Hans-CN;q=1",
                "Accept-Encoding": "gzip",
            ]
        )
        if res.status != 200 { throw ImportError("取加密规则失败 (HTTP \(res.status))") }
        guard let root = jsonParseObject(res.text),
              let rule = root.jsonObj("data")?.jsonObj("cryptRule")
        else {
            throw ImportError("加密规则响应异常: \(res.text.prefix(150))")
        }
        let codeBook = rule.jsonString("codeBook") ?? ""
        if codeBook.isEmpty { throw ImportError("加密规则里没有 codeBook") }
        Log.importer("取得码本 \(codeBook.count) 字符 swap=\(rule.jsonInt("swapTimes"))")
        return CodeBookCrypto.Rule(
            codeBook: codeBook,
            swapTimes: rule.jsonInt("swapTimes"),
            keySkip: rule.jsonInt("keySkip"),
            keyOffset: rule.jsonInt("keyOffset")
        )
    }

    /// 用短信验证码换取登录态。字段与顺序照抓包解密出的真实明文，走 iOS 客户端身份。
    static func loginBySms(mobile: String, smsCode: String) throws -> LoginResult {
        let device = DeviceInfo.session()
        var payload = JsonObject()
        payload.put("smsCode", smsCode)
        payload.put("mac", "02:00:00:00:00:00")
        payload.put("tp", "app-mobile")
        payload.put("mobile", mobile)
        payload.put("gameId", "xyzwapp")
        payload.put("channel", "AppStore")
        payload.put("idfa", "00000000-0000-0000-0000-000000000000")
        payload.put("version", XyEndpoints.iosVersion)
        payload.put("distinctId", device.distinctId)
        payload.put("activeLoginMatchId", device.distinctId)
        payload.put("gameTp", "app")
        payload.put("packageName", XyEndpoints.bundleId)
        payload.put("sysInfo", device.iosSysInfo())
        payload.put("caidInfo", device.caidInfo())
        payload.put("idfv", device.idfv)
        payload.put("deviceUniqueId", device.deviceUniqueId)
        return try combLogin(device, payload)
    }

    /// 用微信授权 code 换取登录态，与短信共用同一登录端点
    static func loginByWxCode(_ code: String) throws -> LoginResult {
        let device = DeviceInfo.session()
        var payload = JsonObject()
        payload.put("code", code)
        payload.put("state", "weixin")
        payload.put("mac", "02:00:00:00:00:00")
        payload.put("tp", "app-we")
        payload.put("gameId", "xyzwapp")
        payload.put("channel", "AppStore")
        payload.put("idfa", "00000000-0000-0000-0000-000000000000")
        payload.put("version", XyEndpoints.iosVersion)
        payload.put("distinctId", device.distinctId)
        payload.put("activeLoginMatchId", device.distinctId)
        payload.put("gameTp", "app")
        payload.put("packageName", XyEndpoints.bundleId)
        payload.put("sysInfo", device.iosSysInfo())
        payload.put("caidInfo", device.caidInfo())
        payload.put("idfv", device.idfv)
        payload.put("deviceUniqueId", device.deviceUniqueId)
        return try combLogin(device, payload)
    }

    /// 提交登录请求。
    /// 必须把 timestamp 和 sign 一并带回：bin 里的 info 三件套是服务端
    /// 签发的整体，自己伪造 sign 会被拒。实测这套凭据不会短期失效。
    private static func combLogin(_ device: DeviceInfo, _ payload: JsonObject) throws -> LoginResult {
        // 请求体不是明文 JSON：先 base64、再用服务端下发的码本 XOR、再 base64。
        // 直接发明文会被判「解密错误 errCode=10024」。
        let plain = payload.toJsonString()
        let rule = try fetchCryptRule(device)
        let body = CodeBookCrypto.encrypt(plain, rule)
        Log.importer("登录请求体 明文\(plain.count)字符 → 密文\(body.count)字符")

        let res = try Http.post(
            XyEndpoints.combLoginApp(device.deviceUniqueId),
            headers: [
                "Content-Type": "application/json; charset=utf-8",
                "User-Agent": XyEndpoints.uaIOS,
                "Accept": "*/*",
                "Accept-Language": "zh-Hans-CN;q=1",
                "Accept-Encoding": "gzip",
            ],
            body: Array(body.utf8)
        )
        let text = res.text
        Log.importer("登录 HTTP \(res.status): \(text.prefix(300))")
        if res.status != 200 { throw ImportError("登录失败 (HTTP \(res.status))") }

        guard let o = jsonParseObject(text) else {
            throw ImportError("登录响应不是 JSON: \(text.prefix(120))")
        }

        // hortor 的接口把状态放在 meta 里
        let meta = o.jsonObj("meta")
        let err = meta?.jsonInt("errCode") ?? o.jsonInt("errCode")
        if err != 0 {
            let msg = meta?.jsonString("errMsg") ?? o.jsonString("errMsg") ?? ""
            throw ImportError("登录失败: \(msg) (errCode=\(err))")
        }

        // combUser 可能是字符串，也可能是含三件套的对象，且可能嵌在 data 里。
        // 三件套必须同源：sign 是对 encryptCombUser+timestamp 的签名，混搭会被拒。
        guard let holder = findCredentialHolder(o) else {
            throw ImportError("登录响应缺少 combUser，原文: \(text.prefix(300))")
        }
        let combUser = holder.jsonString("encryptCombUser") ?? ""
        let ts = holder.jsonInt("timestamp")
        let sign = holder.jsonString("sign") ?? ""
        if combUser.isEmpty || sign.isEmpty || ts == 0 {
            throw ImportError(
                "凭据不完整 combUser=\(combUser.count)字符 ts=\(ts) sign=\(sign.count)字符" +
                "，原文: \(text.prefix(300))")
        }
        Log.importer("取得凭据 combUser=\(combUser.count)字符 ts=\(ts)")
        return LoginResult(combUser: combUser, timestamp: ts, sign: sign, rawJson: text)
    }

    /// 深度查找带 encryptCombUser 的对象。
    /// 服务端把它放在 data.combUser 下，但层级随版本变过，直接递归找最稳。
    private static func findCredentialHolder(_ root: [String: Any], _ depth: Int = 0) -> [String: Any]? {
        if depth > 4 { return nil }
        if root["encryptCombUser"] != nil { return root }
        // combUser 也可能直接是那段 base64 字符串，此时三件套散在同层
        if let direct = root["combUser"] as? String, direct.count > 64, root["sign"] != nil {
            var out: [String: Any] = [:]
            out["encryptCombUser"] = direct
            out["timestamp"] = root.jsonInt("timestamp")
            out["sign"] = root.jsonString("sign") ?? ""
            return out
        }
        for (_, value) in root {
            if let child = value as? [String: Any],
               let found = findCredentialHolder(child, depth + 1) { return found }
        }
        return nil
    }
}

/// 登录得到的账号级凭据，三件套要整体保存
struct LoginResult {
    let combUser: String
    let timestamp: Int
    let sign: String
    let rawJson: String
}

// MARK: - 伪造的设备信息

/// 发验证码那步走安卓模板（已实测能收到短信），登录那步走 iOS 模板
/// —— 抓包解密出的真实登录明文就是 iOS 那套，字段必须逐个对上。
final class DeviceInfo {

    let distinctId: String
    let androidId: String
    let deviceUniqueId: String
    let oaid: String
    let idfv: String
    private let system: String
    private let model: String
    private let brand: String
    private let iosModel: String
    private let iosVer: String
    private let hwModel: String

    private init(distinctId: String, androidId: String, deviceUniqueId: String, oaid: String,
                 idfv: String, system: String, model: String, brand: String,
                 iosModel: String, iosVer: String, hwModel: String) {
        self.distinctId = distinctId
        self.androidId = androidId
        self.deviceUniqueId = deviceUniqueId
        self.oaid = oaid
        self.idfv = idfv
        self.system = system
        self.model = model
        self.brand = brand
        self.iosModel = iosModel
        self.iosVer = iosVer
        self.hwModel = hwModel
    }

    /// 安卓模板，发验证码用
    func sysInfo() -> String {
        var o = JsonObject()
        o.put("system", system)
        o.put("hortorSDKVersion", XyEndpoints.hortorSDKVersion)
        o.put("model", model)
        o.put("brand", brand)
        return try? o.toJsonString() ?? ""
    }

    /// iOS 模板，登录用。字段顺序照抓包明文
    func iosSysInfo() -> String {
        var o = JsonObject()
        o.put("system", "iOS \(iosVer)")
        o.put("model", iosModel)
        o.put("brand", "Apple")
        o.put("hortorSDKVersion", XyEndpoints.iosSDKVersion)
        return try? o.toJsonString() ?? ""
    }

    /// iOS 端的设备指纹集合，服务端用来做同设备判定
    func caidInfo() -> JsonObject {
        var o = JsonObject()
        o.put("carrierInfo", "unknown")
        o.put("machine", iosModel)
        o.put("mntId", "\(Self.hex(64).uppercased())@/dev/disk1s1")
        o.put("sysFileTime", String(format: "%.6f", Date().timeIntervalSince1970))
        o.put("countryCode", "CN")
        o.put("deviceInitTime", "1679115838.749221083")
        o.put("deviceName", Self.hex(32))
        o.put("systemVersion", iosVer)
        o.put("language", "zh-Hans-CN")
        o.put("memory", "5909987328")
        o.put("disk", "255866785792")
        o.put("bootTimeInSec", String(Int64(Date().timeIntervalSince1970) - 86400))
        o.put("timeZone", "28800")
        o.put("model", hwModel)
        return o
    }

    /// 形如 <13位毫秒时间戳>_<uuid>，uuid 与 distinctId 是同一个
    func activeLoginMatchId() -> String {
        "\(Int64(Date().timeIntervalSince1970 * 1000))_\(distinctId)"
    }

    private static let templates = [
        ("Android 12", "ALN-AL1", "HUAWEI"),
        ("Android 10", "23116PN5BC", "Xiaomi"),
    ]

    /// iOS 机型三元组：机器标识 / 系统版本 / 硬件代号
    private static let iosTemplates = [
        ("iPhone15,3", "26.4.2", "D74AP"),
        ("iPhone14,7", "18.6.1", "D27AP"),
    ]

    private static func hex(_ n: Int) -> String {
        let cs = Array("0123456789abcdef")
        return String((0..<n).map { _ in cs.randomElement()! })
    }

    private static let lock = NSLock()
    private static var cached: DeviceInfo?

    /// 同一次导入流程内复用，保证发码与登录是「同一台设备」
    static func session() -> DeviceInfo {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        let d = random()
        cached = d
        return d
    }

    static func newSession() -> DeviceInfo {
        lock.lock(); defer { lock.unlock() }
        let d = random()
        cached = d
        return d
    }

    static func random() -> DeviceInfo {
        let (system, model, brand) = templates.randomElement()!
        let (iosModel, iosVer, hwModel) = iosTemplates.randomElement()!
        // iOS 端 distinctId / deviceUniqueId / activeLoginMatchId 是同一个大写 UUID
        let uid = UUID().uuidString.uppercased()
        return DeviceInfo(
            distinctId: uid,
            androidId: hex(16),
            deviceUniqueId: uid,
            oaid: hex(32),
            idfv: UUID().uuidString.uppercased(),
            system: system, model: model, brand: brand,
            iosModel: iosModel, iosVer: iosVer, hwModel: hwModel
        )
    }
}

// MARK: - 正则小工具

enum Regex {
    /// 取第一个匹配的捕获组（默认第 1 组）
    static func first(_ pattern: String, in text: String, group: Int = 1) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: []),
              let m = re.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > group,
              let r = Range(m.range(at: group), in: text)
        else { return nil }
        return String(text[r])
    }

    static func fullMatch(_ pattern: String, _ text: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return false }
        let r = NSRange(text.startIndex..., in: text)
        return re.firstMatch(in: text, options: [], range: r)?.range == r
    }

    /// 把空白折叠成单空格，用于把服务端响应压成一行塞进错误提示
    static func collapse<S: StringProtocol>(_ s: S) -> String {
        (s as? String ?? String(s))
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
