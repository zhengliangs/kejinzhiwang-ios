import SwiftUI

// 屏幕适配自检条。
//
// 为什么要有这个东西：
// iOS 判定 App 是否适配某块屏幕，唯一依据是启动图（launch storyboard 或
// 对应尺寸的 launch image），跟 SwiftUI 怎么写一点关系都没有。判定没过，
// 系统就把整块 UI 渲染进一块 4.7 寸的画布里，再整体缩放居中显示 —— 表现
// 就是上下各一条黑边，内容挤在中间。这种黑边改任何布局代码都消不掉，
// 之前几轮全改在 SwiftUI 上，所以一点效果都没有。
//
// 判据（两个一起看，互相印证）：
//  1. scale 与 nativeScale：
//     scale 是 App 实际被渲染的倍率，nativeScale 是物理屏倍率。
//     正常两者相等（都是 2 或 3）；被缩放了才会不等。
//  2. bounds 与 nativeBounds 的宽高比：
//     正常应完全一致；兼容模式下画布是 3:2 或 16:9，物理屏是 19.5:9 之类。
//
// 条子正常时几乎透明，只是当个背景水印；一旦检测到兼容模式就变醒目，
// 截图一眼就能看出来。

struct ScreenDiag: View {

    @Environment(\.palette) private var palette

    var body: some View {
        Text(ScreenReport.line(compact: true))
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(ScreenReport.compat ? Color.orange : palette.onSurfaceVariant)
            .opacity(ScreenReport.compat ? 1 : 0.35)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, ScreenReport.compat ? 4 : 2)
            .background(ScreenReport.compat ? Color.orange.opacity(0.14) : Color.clear)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}

// 屏幕适配自检。
//
// 单独抽出来是因为这个结论有两处要用：
//  1. 账号页顶部那条自检条（截图一眼可见）；
//  2. 启动时写进 import.log（用户不进导入页也能取到数据）。
enum ScreenReport {

    static var logical: CGSize { UIScreen.main.bounds.size }
    static var physical: CGSize { UIScreen.main.nativeBounds.size }

    /// 渲染倍率与物理倍率对不上 = 系统正在对整块 UI 做缩放
    static var scaleMismatch: Bool {
        abs(UIScreen.main.scale - UIScreen.main.nativeScale) > 0.01
    }

    /// 画布宽高比与物理屏宽高比对不上 = 画布被换成了旧机型的尺寸
    static var ratioMismatch: Bool {
        guard physical.height > 0, logical.height > 0 else { return false }
        let a = logical.width / logical.height
        let b = physical.width / physical.height
        return abs(a - b) > 0.02
    }

    /// 兼容模式：系统没认这个 App 适配当前屏幕
    static var compat: Bool { scaleMismatch || ratioMismatch }

    static func line(compact: Bool = false) -> String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let l = "\(Int(logical.width))×\(Int(logical.height))@\(Int(UIScreen.main.scale))x"
        let p = "\(Int(physical.width))×\(Int(physical.height))@\(Int(UIScreen.main.nativeScale))x"
        if compat {
            return compact
                ? "⚠️ v\(v) 画布\(l) 物理\(p) —— 兼容模式(上下黑边)"
                : "兼容模式：画布\(l) 物理\(p)"
        }
        return compact ? "v\(v) · \(l) · 全屏" : "全屏正常：\(l) 物理\(p)"
    }
}
