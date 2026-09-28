import MapKit
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// 地図の上に指が触れている間、外側の縦スクロール(List など)を止める。
/// 地図の上をなぞったときは地図の操作(移動・拡大・タップ)、地図の外をなぞったときは画面のスクロールになる。
/// 自分では何も認識しない(ほかのジェスチャーの邪魔をしない)で、触れた・離れたことだけを使う。
final class ParentScrollLockRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    private weak var lockedScrollView: UIScrollView?
    private var activeTouches = 0

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        activeTouches += touches.count
        guard lockedScrollView == nil, let scrollView = enclosingScrollView() else { return }
        scrollView.isScrollEnabled = false
        lockedScrollView = scrollView
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        release(touches.count)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        release(touches.count)
    }

    override func reset() {
        super.reset()
        activeTouches = 0
        unlock()
    }

    private func release(_ count: Int) {
        activeTouches = max(0, activeTouches - count)
        if activeTouches == 0 {
            unlock()
            state = .failed
        }
    }

    private func unlock() {
        lockedScrollView?.isScrollEnabled = true
        lockedScrollView = nil
    }

    /// 地図を囲む一番近いスクロール(地図の中のビューは含めない)
    private func enclosingScrollView() -> UIScrollView? {
        var current = view?.superview
        while let candidate = current {
            if let scrollView = candidate as? UIScrollView { return scrollView }
            current = candidate.superview
        }
        return nil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

/// 地図の表示範囲の覚え書き。スクロールで地図が画面の外に出て作り直されても、同じ範囲で開き直す。
enum MapRegionMemory {
    static var regions: [String: MKCoordinateRegion] = [:]
}
