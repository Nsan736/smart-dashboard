import SwiftUI
import UIKit

enum Keyboard {
    /// いま入力中の欄がどれであっても、キーボードを閉じる
    @MainActor
    static func dismiss() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

/// 入力欄のある画面に付ける共通のモディファイア。
/// - キーボードの上に「完了」ボタンを置く
/// - スクロールしたらキーボードを閉じる
/// 入力欄の外をタップしたら閉じる処理は、アプリ全体で1つ `KeyboardTapDismissInstaller` が受け持つ。
struct KeyboardDismissModifier: ViewModifier {
    /// 画面が重なっているとき(設定 → 地点の登録など)に「完了」が二重に出ないよう、表示中の画面だけがボタンを出す
    @State private var isVisible = false

    func body(content: Content) -> some View {
        content
            .scrollDismissesKeyboard(.interactively)
            .onAppear { isVisible = true }
            .onDisappear { isVisible = false }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    if isVisible {
                        Spacer()
                        Button("完了") { Keyboard.dismiss() }
                            .fontWeight(.semibold)
                    }
                }
            }
    }
}

extension View {
    /// 入力欄のある画面で使う。どの入力でもキーボードを確実に閉じられるようにする。
    func keyboardDismissable() -> some View {
        modifier(KeyboardDismissModifier())
    }
}

/// 数字キーボードのように改行キーがない入力欄の横に置く、閉じるボタン。
/// キーボード上のツールバーが表示されない場合の保険も兼ねる。
struct KeyboardCloseButton: View {
    let isFocused: Bool

    var body: some View {
        if isFocused {
            Button {
                Keyboard.dismiss()
            } label: {
                Image(systemName: "keyboard.chevron.compact.down")
                    .font(.title3)
                    .frame(width: 40, height: 36)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("キーボードを閉じる")
        }
    }
}

/// 入力欄の外をタップしたらキーボードを閉じる。ウィンドウに1つだけ認識器を付け、タップ自体は下の画面にそのまま届ける。
struct KeyboardTapDismissInstaller: UIViewRepresentable {
    func makeUIView(context: Context) -> InstallerView { InstallerView() }
    func updateUIView(_ uiView: InstallerView, context: Context) {}

    final class InstallerView: UIView, UIGestureRecognizerDelegate {
        private weak var installedWindow: UIWindow?
        private var recognizer: UITapGestureRecognizer?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window, installedWindow !== window else { return }
            if let recognizer, let installedWindow { installedWindow.removeGestureRecognizer(recognizer) }
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
            tap.cancelsTouchesInView = false
            tap.delaysTouchesBegan = false
            tap.delaysTouchesEnded = false
            tap.delegate = self
            window.addGestureRecognizer(tap)
            recognizer = tap
            installedWindow = window
        }

        @objc private func handleTap() {
            window?.endEditing(true)
        }

        /// 入力欄そのものへのタップでは閉じない(別の入力欄へ直接移れるようにする)
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let current = view {
                if current is UITextField || current is UITextView { return false }
                view = current.superview
            }
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
