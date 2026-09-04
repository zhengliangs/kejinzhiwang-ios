import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - UIKit 版文档选择器
//
// SwiftUI 的 fileImporter 在 sideloaded（全能签）App 上存在「选中文件 + 点打开
// 但回调不触发」的问题。UIKit 的 UIDocumentPickerViewController 是更底层、更
// 成熟的选择器，回调走 UIDocumentPickerDelegate，可靠性远高于 SwiftUI 封装层。
// 它能浏览整个「文件 App」的全部位置（iCloud / 我的iPhone / 下载 / 微信存的文件等），
// 不需要 bin 事先放进 App 沙盒。
//
// 这个选择器给用户「浏览整个文件App」的能力，是兜底方案。

struct UIKitDocumentPicker: UIViewControllerRepresentable {
    /// 是否多选
    var allowsMultiple: Bool
    /// 选中回调（可能为空，表示用户取消）
    var onPicked: ([URL]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // .item 允许所有类型；bin 是一种私有扩展名，用 .item + .data 才能显示
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.item, .data],
            asCopy: true          // asCopy=true 直接把选中文件拷到 Inbox，避免安全作用域问题
        )
        picker.allowsMultipleSelection = allowsMultiple
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: UIKitDocumentPicker

        init(_ parent: UIKitDocumentPicker) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            // asCopy=true 时，系统已把文件拷贝到 App 的 Inbox，urls 指向 Inbox 内拷贝，
            // 无需再 startAccessingSecurityScopedResource
            parent.onPicked(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onPicked([])
        }
    }
}
