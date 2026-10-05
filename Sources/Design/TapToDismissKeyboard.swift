import SwiftUI
import UIKit

/// 全局「点空白收起键盘」手势。
///
/// 直接把 UITapGestureRecognizer 挂在窗口上，避免点击被 ScrollView 吞掉；
/// 同时在 delegate 中过滤掉落在文本输入控件（及其子视图）上的触摸，
/// 因此「点击输入框内部」不会收起键盘。手势不拦截其它触摸（cancelsTouchesInView = false），
/// 按钮点击与列表滚动都不受影响。
struct TapToDismissKeyboard: UIViewRepresentable {

    func makeUIView(context: Context) -> HostView {
        let view = HostView()
        let coordinator = context.coordinator
        view.onMoveToWindow = { window in coordinator.attach(to: window) }
        return view
    }

    func updateUIView(_ uiView: HostView, context: Context) {}

    static func dismantleUIView(_ uiView: HostView, coordinator: Coordinator) {
        coordinator.detach()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// 用于感知自身何时进入窗口，避免 makeUIView 时 window 仍为 nil
    final class HostView: UIView {
        var onMoveToWindow: ((UIWindow) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window else { return }
            onMoveToWindow?(window)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private weak var attachedWindow: UIWindow?
        private weak var recognizer: UITapGestureRecognizer?

        func attach(to window: UIWindow) {
            guard attachedWindow !== window else { return }
            detach()
            let tap = UITapGestureRecognizer(
                target: self,
                action: #selector(dismissKeyboard)
            )
            tap.cancelsTouchesInView = false
            tap.delegate = self
            window.addGestureRecognizer(tap)
            recognizer = tap
            attachedWindow = window
        }

        func detach() {
            if let recognizer {
                recognizer.view?.removeGestureRecognizer(recognizer)
            }
            recognizer = nil
            attachedWindow = nil
        }

        @objc func dismissKeyboard() {
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil,
                from: nil,
                for: nil
            )
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            !(touch.view?.isTextInput ?? false)
        }
    }
}

private extension UIView {
    /// 触摸是否落在文本输入控件内部
    var isTextInput: Bool {
        if self is UITextField || self is UITextView { return true }
        return superview?.isTextInput ?? false
    }
}