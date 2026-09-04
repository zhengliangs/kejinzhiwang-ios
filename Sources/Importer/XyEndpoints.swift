import Foundation

// 咸鱼之王与微信开放平台的端点和伪装头。移植自安卓版 importer/XyEndpoints.kt。
//
// 这些值必须与官方客户端一致，服务端会校验 Referer / UA / 签名指纹。
// 版本号随游戏更新会失效，所以集中放在这里便于调整。

enum XyEndpoints {

    // 咸鱼之王在微信开放平台的身份
    static let wxAppid = "wxfb0d5667e5cb1c44"
    static let bundleId = "com.hortor.games.xyzw"
    static let wxScope = "snsapi_base,snsapi_userinfo,snsapi_friend,snsapi_message"

    // 正式安装包的签名指纹，服务端据此校验包体
    static let signPrint = "E6:F7:FE:A9:EC:8E:24:D0:4F:2A:32:50:28:78:E1:C5:5E:70:81:13"

    static let hortorSDKVersion = "4.2.1-cn-release"
    static let appVersion = "1.84.5-wx"

    /// 抓包实测的 App 端版本号，与小游戏端的 APP_VERSION 不同
    static let androidVersion = "1.4.0"
    static let cryptVersion = "1.1.0"

    /// 走 iOS 客户端身份。抓包解密出的明文里 version 就是这个值，
    /// 与 crypt/mix 取规则时用的必须一致，否则服务端下发的码本对不上。
    static let iosVersion = "0.33.0"
    static let iosSDKVersion = "1.9.3"

    static func qrConnect() -> String {
        "https://open.weixin.qq.com/connect/app/qrconnect" +
            "?appid=\(wxAppid)&bundleid=\(bundleId)&scope=\(wxScope)&state=weixin"
    }

    static func qrImage(_ uuid: String) -> String {
        "https://open.weixin.qq.com/connect/qrcode/\(uuid)"
    }

    static func qrPoll(_ uuid: String) -> String {
        "https://long.open.weixin.qq.com/connect/l/qrconnect" +
            "?uuid=\(uuid)&f=url&_=\(Int64(Date().timeIntervalSince1970 * 1000))"
    }

    static func serverList() -> String {
        "https://xxz-xyzw.hortorgames.com/login/serverlist?_seq=3"
    }

    static func smsCode() -> String {
        "https://ucenter-app-server.hortorgames.com/ucenter-app-server/api/v1/login/verify/code"
    }

    /// 取加密规则（码本）。免鉴权 GET，参数照抓包原样
    static func cryptMix(_ deviceId: String) -> String {
        "https://comb-platform.hortorgames.com/comb-login-server/api/v1/login/crypt/mix" +
            "?combGameId=xyzw_mix&deviceUniqueId=\(deviceId)&gameTp=app" +
            "&packageName=\(bundleId)&system=ios&version=\(iosVersion)"
    }

    /// App 登录。query 照抓包原样：system=ios、version=0.33.0、
    /// deviceUniqueId 是无前缀的大写 UUID。请求体是加密后的 base64 文本。
    static func combLoginApp(_ deviceId: String, _ version: String = iosVersion) -> String {
        "https://comb-platform.hortorgames.com/comb-login-server/api/v1/login" +
            "?gameId=xyzwapp&gameTp=app&system=ios&cryptVersion=\(cryptVersion)" +
            "&version=\(version)&deviceUniqueId=\(deviceId)" +
            "&timestamp=\(Int64(Date().timeIntervalSince1970 * 1000))"
    }

    /// 伪装成 Mac 微信小游戏客户端，用于 hortor 游戏主服
    static let uaMinigame =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " +
        "(KHTML, like Gecko) Chrome/107.0.0.0 Safari/537.36 " +
        "MicroMessenger/6.8.0(0x16080000) NetType/WIFI MiniProgramEnv/Mac " +
        "MacWechat/WMPF MacWechat/3.8.7(0x13080710) XWEB/1191"

    /// 咸鱼之王小程序 appid 的数字形式 + 小游戏版本号
    static let refererMinigame =
        "https://appservice.qq.com/1112173744/1.66.5/page-frame.html"

    /// 伪装成安卓微信内置浏览器，用于微信开放平台
    static let uaWxAndroid =
        "Mozilla/5.0 (Linux; Android 7.0; Mi-4c Build/NRD90M; wv) AppleWebKit/537.36 " +
        "(KHTML, like Gecko) Version/4.0 Chrome/53.0.2785.49 Mobile MQQBrowser/6.2 " +
        "TBS/043632 Safari/537.36 MicroMessenger/6.6.1.1220(0x26060135) NetType/WIFI " +
        "Language/zh_CN miniProgram"

    /// 抓包里登录与 crypt/mix 用的 iPhone UA
    static let uaIOS =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) " +
        "AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"

    /// 伪装成安卓 App
    static let uaApp =
        "Mozilla/5.0 (Linux; Android 10; 23116PN5BC Build/HUAWEIJNY-AL10; wv) " +
        "AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/74.0.3729.186 " +
        "Mobile Safari/537.36"
}

/// 微信扫码状态码
enum WxScanState: Int {
    case confirmed = 405
    case scanned = 404
    case waiting = 408
    case expired = 402
    case rejected = 403
    case unknown = -1

    var label: String {
        switch self {
        case .confirmed: return "已确认授权"
        case .scanned: return "已扫码，等待确认"
        case .waiting: return "等待扫码"
        case .expired: return "二维码已过期"
        case .rejected: return "已取消授权"
        case .unknown: return "未知状态"
        }
    }

    static func of(_ code: Int) -> WxScanState { WxScanState(rawValue: code) ?? .unknown }
}
