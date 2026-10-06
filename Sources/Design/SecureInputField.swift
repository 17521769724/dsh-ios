import SwiftUI
import UIKit

/// API Key 输入框：明文 / 密文切换只改 UITextField 的 isSecureTextEntry，
/// 不重建视图，因此占位符「sk-…」与已输入文字不会上下跳动。
struct SecureInputField: UIViewRepresentable {
    @Binding var text: String
    var isSecure: Bool
    var placeholder: String
    var onSubmit: () -> Void
    var onFocusChange: (Bool) -> Void

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.borderStyle = .none
        field.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        field.placeholder = placeholder
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.returnKeyType = .go
        field.isSecureTextEntry = isSecure
        field.delegate = context.coordinator
        field.addTarget(
            context.coordinator,
            action: #selector(Coordinator.editingChanged(_:)),
            for: .editingChanged
        )
        field.accessibilityIdentifier = "onboarding.key"
        // 压低水平方向的抗压缩优先级，让输入框占满剩余宽度且宽度恒定
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self

        if field.text != text {
            field.text = text
        }
        if field.isSecureTextEntry != isSecure {
            // 切换安全输入时 system 可能清空内容，这里显式回填，保证切换后内容不变
            let current = field.text
            field.isSecureTextEntry = isSecure
            field.text = current
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: SecureInputField

        init(_ parent: SecureInputField) {
            self.parent = parent
        }

        @objc func editingChanged(_ field: UITextField) {
            parent.text = field.text ?? ""
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            parent.onFocusChange(true)
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            parent.onFocusChange(false)
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onSubmit()
            return false
        }
    }
}