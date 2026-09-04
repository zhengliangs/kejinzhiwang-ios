import Foundation

// 账号级凭据 → 查询区服 → 生成每区服一份 bin。
// 移植自安卓版 importer/BinBuilder.kt。
//
// 这条链路已用真实 bin 实测通过：请求体就是 bin 的明文结构重新
// 加密，响应用同一套 LX/X 解密 + BON 解码，body 需要二次解码。

/// 一个区服里的角色
struct RoleInfo: Identifiable {
    let serverId: Int
    let roleId: Int64
    let name: String
    let power: Int64
    let level: Int
    let loginAt: String

    var id: Int64 { roleId }

    /// 战力显示：亿 / 万
    func powerText() -> String {
        if power >= 100_000_000 { return String(format: "%.2f亿", Double(power) / 1e8) }
        if power >= 10_000 { return String(format: "%.2f万", Double(power) / 1e4) }
        return "\(power)"
    }
}

/// 生成好的一份绑定区服 bin
struct GeneratedBin {
    let fileName: String
    let bytes: [UInt8]
    let role: RoleInfo

    var data: Data { Data(bytes) }
}

enum BinBuilder {

    /// 账号级凭据：从 bin 解出，或由登录接口的 combUser 构造
    struct Credential {
        let platform: String
        let platformExt: String
        let info: [String: Any]
        let scene: Any?
        let referrerInfo: Any?

        /// 还原成可发送 / 可存盘的对象；serverId 为 nil 即账号级。
        /// 字段顺序照抄官方明文，用 BonObject 保序。
        func toBon(serverId: Int?) -> BonObject {
            var pairs: [(String, Any?)] = []
            pairs.append(("platform", platform))
            pairs.append(("platformExt", platformExt))
            pairs.append(("info", info))
            if let serverId { pairs.append(("serverId", serverId)) }
            else { pairs.append(("serverId", nil)) }
            pairs.append(("scene", scene ?? 0))
            pairs.append(("referrerInfo", referrerInfo ?? ""))
            return BonObject(pairs)
        }
    }

    /// info 字段有两种写法，都要认。
    /// 我们自己生成的是嵌套对象；而外面流传的 bin（占多数）把它写成
    /// JSON 字符串。内层键顺序也不固定，只能按名字取。
    private static func parseInfo(_ raw: Any?) throws -> [String: Any] {
        if let map = raw as? [String: Any] { return map }
        if let s = raw as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let obj = jsonParseObject(s) else {
                throw ImportError("info 是字符串但不是合法 JSON，文件可能已损坏")
            }
            return obj
        }
        throw ImportError("bin 缺少 info 字段")
    }

    /// 从已有 bin 文件解析出账号级凭据
    static func parseCredential(_ binBytes: [UInt8]) throws -> Credential {
        let plain = try XyCrypto.decrypt(binBytes)
        guard let obj = try BonDecoder().decode(plain) as? [String: Any] else {
            throw ImportError("bin 解码结果不是对象")
        }
        let info = try parseInfo(bonValue(obj, "info"))
        if bonValue(info, "encryptCombUser") == nil {
            throw ImportError("bin 里没有登录凭据（encryptCombUser），无法反查区服")
        }
        return Credential(
            platform: bonValue(obj, "platform") as? String ?? "hortor",
            platformExt: bonValue(obj, "platformExt") as? String ?? "mix",
            info: info,
            scene: bonValue(obj, "scene") ?? 0,
            referrerInfo: bonValue(obj, "referrerInfo") ?? ""
        )
    }

    /// 用登录得到的 combUser 构造凭据
    static func credentialFromCombUser(combUser: String, timestamp: Int, sign: String) -> Credential {
        var info: [String: Any] = [:]
        info["encryptCombUser"] = combUser
        // BON 里整数走 Int32，与安卓版 Kotlin Int 对齐
        info["timestamp"] = Int32(truncatingIfNeeded: timestamp)
        info["sign"] = sign
        return Credential(platform: "hortor", platformExt: "mix",
                          info: info, scene: 0, referrerInfo: "")
    }

    /// 查询该凭据在哪些区服有角色
    static func queryRoles(_ cred: Credential) throws -> [RoleInfo] {
        let payload = XyCrypto.encryptX(BonEncoder().encode(cred.toBon(nil)))
        let res = try Http.post(
            XyEndpoints.serverList(),
            headers: [
                "Referer": XyEndpoints.refererMinigame,
                "Content-Type": "application/octet-stream",
                // 不能加 O4e-Encoding: lx —— 那是声明「请求体」的编码，
                // 我们发的是 px(X 加密)，声明不符服务端直接回「指令解析错误」。
                // 实测：带此头响应 105 字节报错，不带则正常返回角色列表。
                "User-Agent": XyEndpoints.uaMinigame,
            ],
            body: payload
        )
        if res.status != 200 { throw ImportError("查询区服失败 (HTTP \(res.status))") }
        if res.body.isEmpty { throw ImportError("查询区服返回空响应") }
        // 正常响应有几 MB（含全区服列表），几百字节基本就是报错回包
        Log.importer("serverlist 响应 \(res.body.count) 字节")

        guard let outer = try BonDecoder().decode(try XyCrypto.decrypt(res.body)) as? [String: Any] else {
            throw ImportError("响应解码失败")
        }
        let cmd = bonValue(outer, "cmd") as? String
        Log.importer("serverlist 响应 cmd=\(cmd ?? "nil") 字段=\(outer.keys.joined(separator: ","))")
        if let cmd, cmd.localizedCaseInsensitiveContains("Error") {
            throw ImportError("服务端返回错误: \(cmd) \(describe(outer))")
        }

        // body 是嵌套的 BON 字节序列，要二次解码
        guard let bodyBytes = bonValue(outer, "body") as? [UInt8] else {
            throw ImportError("响应缺少 body。cmd=\(cmd ?? "nil") 字段=\(outer.keys.joined(separator: ",")) \(describe(outer))")
        }
        guard let body = try BonDecoder().decode(bodyBytes) as? [String: Any] else {
            throw ImportError("body 解码失败")
        }
        guard let roles = bonValue(body, "roles") as? [String: Any] else {
            throw ImportError("未找到角色列表，凭据可能已失效")
        }

        var out: [RoleInfo] = []
        out.reserveCapacity(roles.count)
        for (key, v) in roles {
            guard let r = v as? [String: Any] else { continue }
            guard let sid = bonNumber(bonValue(r, "serverId")).map({ Int($0) }) ?? Int(key) else { continue }
            out.append(RoleInfo(
                serverId: sid,
                roleId: Int64(bonNumber(bonValue(r, "roleId")) ?? 0),
                name: bonValue(r, "name") as? String ?? "未命名",
                power: Int64(bonNumber(bonValue(r, "power")) ?? 0),
                level: Int(bonNumber(bonValue(r, "level")) ?? 0),
                loginAt: bonValue(r, "loginAt").map { "\($0)" } ?? ""
            ))
        }
        Log.importer("共解析出 \(out.count) 个角色")
        // 最近登录的排前面，方便用户找主号
        return out.sorted { $0.loginAt > $1.loginAt }
    }

    /// 把响应对象压成一行摘要，便于在弹窗里看清服务端到底回了什么
    private static func describe(_ map: [String: Any]) -> String {
        let items = map.prefix(8).map { (k, v) -> String in
            let s: String
            switch v {
            case is NSNull: s = "null"
            case let b as [UInt8]: s = "<\(b.count)字节>"
            case let m as [String: Any]: s = "{\(m.keys.prefix(6).joined(separator: ","))}"
            case let l as [Any]: s = "<列表\(l.count)>"
            default: s = "\(v)".prefix(80).description
            }
            return "\(k)=\(s)"
        }
        return "{" + items.joined(separator: ", ") + "}"
    }

    /// 为选中的角色各生成一份绑定区服 bin。
    /// 生成规则已验证：结构照抄账号级凭据，只替换 serverId。
    static func buildBins(_ cred: Credential, _ roles: [RoleInfo]) -> [GeneratedBin] {
        roles.enumerated().map { (i, role) in
            // 必须用 LX("pl")：游戏发 authuser 时声明 O4e-Encoding: lx，
            // 给 px 会被判「指令解析错误」，卡在「正在登录」
            let bytes = XyCrypto.encryptLX(BonEncoder().encode(cred.toBon(role.serverId)))
            let safe = bonSafeFileName(role.name)
            let name = String(format: "%02d-%@-%d服-%lld-%@.bin",
                              i + 1, role.powerText(), role.serverId, role.roleId, safe)
            return GeneratedBin(fileName: name, bytes: bytes, role: role)
        }
    }
}
