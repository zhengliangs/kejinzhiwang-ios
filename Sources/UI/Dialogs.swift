import SwiftUI

// 两个输入类弹窗。移植自安卓版 ui/Dialogs.kt。
// 安卓用 AlertDialog 承载内容，iOS 的 .alert 里放 TextField 是标准做法；
// 分组编辑带调色板，放 .sheet 里更顺手。

/// 单行文本输入，用于重命名
struct TextInputDialogModifier: ViewModifier {

    let title: String
    let initial: String
    let placeholder: String
    let isPresented: Binding<Bool>
    let onConfirm: (String) -> Void

    @State private var text = ""

    func body(content: Content) -> some View {
        content
            .alert(title, isPresented: isPresented) {
                TextField(placeholder, text: $text)
                Button("取消", role: .cancel) {}
                Button("确定") {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { onConfirm(trimmed) }
                }
            }
            .onChange(of: isPresented.wrappedValue) { presented in
                if presented { text = initial }
            }
    }
}

extension View {
    func textInputDialog(title: String,
                         initial: String = "",
                         placeholder: String = "名称",
                         isPresented: Binding<Bool>,
                         onConfirm: @escaping (String) -> Void) -> some View {
        modifier(TextInputDialogModifier(title: title, initial: initial,
                                         placeholder: placeholder,
                                         isPresented: isPresented, onConfirm: onConfirm))
    }
}

/// 分组编辑：名称 + 颜色 + 删除。默认分组不允许删除。
struct GroupEditSheet: View {

    let title: String
    let initialName: String
    let initialColor: Int
    var allowDelete = false
    var onDelete: (() -> Void)?
    var onConfirm: (String, Int) -> Void

    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var color = 0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("分组名称", text: $name)
                        .submitLabel(.done)
                }

                Section("颜色") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 12) {
                        ForEach(Array(AccountGroup.palette.enumerated()), id: \.offset) { _, item in
                            Button {
                                color = item.0
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(Color(argb: item.0))
                                        .frame(width: 30, height: 30)
                                    if color == item.0 {
                                        Circle()
                                            .stroke(palette.onSurface, lineWidth: 2.5)
                                            .frame(width: 36, height: 36)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }

                if allowDelete {
                    Section {
                        Button(role: .destructive) {
                            onDelete?()
                            dismiss()
                        } label: {
                            Text("删除分组")
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确定") {
                        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            onConfirm(trimmed, color)
                            dismiss()
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                name = initialName
                color = initialColor
            }
        }
    }
}
