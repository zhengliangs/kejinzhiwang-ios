import Foundation
import UIKit

// 扫码 / 短信登录导入的状态与流程编排。
// 移植自安卓版 importer/ImportViewModel.kt。
//
// 安卓用 viewModelScope 保证离开界面后自动取消，这里用 Task + 显式
// cancel，同样避免离开界面后继续打微信接口。

enum ImportStage {
    case idle, qrWaiting, loggingIn, querying, picking
}

@MainActor
final class ImportViewModel: ObservableObject {

    @Published var stage: ImportStage = .idle
    @Published var message = ""
    @Published var busy = false

    @Published var qrImage: UIImage?
    @Published var qrHint = ""

    @Published var mobile = ""
    @Published var smsCode = ""
    @Published var countdown = 0

    /// 查到的角色
    @Published var roles: [RoleInfo] = []
    /// 勾选状态
    @Published var selected: Set<Int> = []

    private var credential: BinBuilder.Credential?
    private var pollTask: Task<Void, Never>?
    private var countdownTask: Task<Void, Never>?

    func reset() {
        pollTask?.cancel()
        pollTask = nil
        stage = .idle
        message = ""
        qrImage = nil
        qrHint = ""
        roles = []
        selected = []
        credential = nil
        busy = false
    }

    // MARK: - 扫码

    func startQrLogin() {
        pollTask?.cancel()
        busy = true
        message = ""
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let ticket = try WxLogin.createQrCode()
                guard UIImage(data: ticket.imageData) != nil else {
                    throw ImportError("二维码图片无法解码")
                }
                let image = UIImage(data: ticket.imageData)
                await MainActor.run {
                    guard let self else { return }
                    self.qrImage = image
                    self.stage = .qrWaiting
                    self.qrHint = "请用微信扫码"
                    self.busy = false
                }
                await self?.pollLoop(uuid: ticket.uuid)
            } catch {
                await MainActor.run {
                    self?.busy = false
                    self?.message = error.localizedDescription
                }
            }
        }
    }

    private func pollLoop(uuid: String) async {
        pollTask?.cancel()
        pollTask = Task.detached(priority: .utility) { [weak self] in
            let deadline = Date().addingTimeInterval(5 * 60)
            while Date() < deadline, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { break }
                do {
                    let result = try WxLogin.pollQrCode(uuid)
                    await MainActor.run { self?.handlePoll(result) }
                    if result.state != .waiting && result.state != .scanned { break }
                } catch {
                    await MainActor.run {
                        self?.qrHint = "轮询出错: \(error.localizedDescription)"
                    }
                }
            }
            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                guard let self, self.stage == .qrWaiting else { return }
                self.qrHint = "二维码已超时，请重新获取"
                self.stage = .idle
                self.qrImage = nil
            }
        }
    }

    private func handlePoll(_ result: QrPollResult) {
        switch result.state {
        case .confirmed:
            qrHint = "授权成功，正在登录"
            qrImage = nil
            if let code = result.code { runLogin { try WxLogin.loginByWxCode(code) } }
        case .expired, .rejected:
            qrHint = result.state.label + "，请重新获取"
            stage = .idle
            qrImage = nil
        default:
            qrHint = result.state.label
        }
    }

    // MARK: - 短信

    func sendSms() {
        let m = mobile.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Regex.fullMatch("^1[3-9]\\d{9}$", m) else {
            message = "请输入有效的手机号"
            return
        }
        busy = true
        message = ""
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try WxLogin.sendSmsCode(m)
                await MainActor.run {
                    self?.message = "验证码已发送，请注意接收"
                    self?.busy = false
                    self?.startCountdown()
                }
            } catch {
                await MainActor.run {
                    self?.message = error.localizedDescription
                    self?.busy = false
                }
            }
        }
    }

    private func startCountdown() {
        countdownTask?.cancel()
        countdownTask = Task { [weak self] in
            guard let self else { return }
            self.countdown = 120
            while self.countdown > 0, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break }
                self.countdown -= 1
            }
        }
    }

    func loginBySms() {
        let m = mobile.trimmingCharacters(in: .whitespacesAndNewlines)
        let c = smsCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard c.count >= 4 else {
            message = "请输入有效的验证码"
            return
        }
        runLogin { try WxLogin.loginBySms(mobile: m, smsCode: c) }
    }

    // MARK: - 登录 → 查区服

    /** 登录 → 查区服，两步合一 */
    private func runLogin(_ block: @escaping () throws -> LoginResult) {
        busy = true
        stage = .loggingIn
        message = ""
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let login = try block()
                await MainActor.run {
                    self?.stage = .querying
                    self?.message = "登录成功，正在查询区服"
                }
                // timestamp / sign 必须用服务端签发的原值
                let cred = BinBuilder.credentialFromCombUser(
                    combUser: login.combUser, timestamp: login.timestamp, sign: login.sign)
                let list = try BinBuilder.queryRoles(cred)
                await MainActor.run {
                    guard let self else { return }
                    self.credential = cred
                    self.roles = list
                    self.selected = Set(list.indices)
                    self.stage = .picking
                    self.message = "共找到 \(list.count) 个角色，请选择要导入的"
                    self.busy = false
                }
            } catch {
                await MainActor.run {
                    self?.stage = .idle
                    self?.message = error.localizedDescription
                    self?.busy = false
                }
            }
        }
    }

    /** 用已有 bin 文件查区服，不需要重新登录 */
    func queryFromBin(_ data: Data) {
        busy = true
        message = ""
        stage = .querying
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let cred = try BinBuilder.parseCredential(data.hexBytes)
                let list = try BinBuilder.queryRoles(cred)
                await MainActor.run {
                    guard let self else { return }
                    self.credential = cred
                    self.roles = list
                    self.selected = Set(list.indices)
                    self.stage = .picking
                    self.message = "共找到 \(list.count) 个角色"
                    self.busy = false
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.stage = .idle
                    // 两种常见失败原因表现相似，分开提示省得用户以为是软件坏了
                    let raw = error.localizedDescription
                    if raw.contains("解码") || raw.contains("缺少 info") {
                        self.message = raw + "\n该文件可能不是有效的 bin，或已损坏"
                    } else if raw.contains("凭据") || raw.contains("角色列表") {
                        self.message = raw + "\n登录态可能已过期，请改用扫码或手机号导入"
                    } else {
                        self.message = raw
                    }
                    self.busy = false
                }
            }
        }
    }

    // MARK: - 选择

    func toggle(_ index: Int) {
        if selected.contains(index) { selected.remove(index) } else { selected.insert(index) }
    }

    func selectAll(_ on: Bool) {
        selected = on ? Set(roles.indices) : []
    }

    /** 生成选中角色的 bin */
    func buildSelected() -> [GeneratedBin] {
        guard let credential else { return [] }
        let picked = selected.sorted().compactMap { roles.indices.contains($0) ? roles[$0] : nil }
        return BinBuilder.buildBins(credential, picked)
    }
}
