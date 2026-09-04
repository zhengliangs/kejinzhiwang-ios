import SwiftUI

// 轻提示。对应安卓版 ui/Toast.kt。
//
// 安卓版不走系统 Toast，原因是 MIUI 关掉通知权限后会连带屏蔽，提示可能
// 完全不显示。iOS 上系统 Toast 不存在，本来就得自己画，行为按安卓来：
// 顶部浮出一条胶囊，2 秒后自动消失。

final class TipState: ObservableObject {
    @Published private(set) var message: String?
    @Published private(set) var token = 0

    private var hideWork: DispatchWorkItem?

    func show(_ text: String) {
        hideWork?.cancel()
        message = text
        token += 1
        let work = DispatchWorkItem { [weak self] in
            self?.message = nil
            self?.token += 1
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }
}

struct TipHost: View {
    @ObservedObject var tip: TipState
    var topPadding: CGFloat = 8

    @Environment(\.palette) private var palette

    var body: some View {
        VStack {
            if let message = tip.message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(palette.tipForeground)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(
                        Capsule().fill(palette.tipBackground)
                    )
                    .padding(.top, topPadding)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .animation(.easeOut(duration: 0.18), value: tip.token)
            }
            Spacer()
        }
        .allowsHitTesting(false)
    }
}

/// 页面里持有提示状态。用法与安卓的 rememberTipState() 一致。
@propertyWrapper
struct TipStateObject: DynamicProperty {
    @StateObject private var state = TipState()
    var wrappedValue: TipState { state }
}
