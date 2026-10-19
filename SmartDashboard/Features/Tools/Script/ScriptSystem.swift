import Foundation
import Security
import UIKit
import UserNotifications

/// スクリプトからの通知の依頼(v0.9.32、`notify.*`)。タイマーなどで、アプリを閉じていても時間を知らせる
/// 通知の指定の誤り
struct ScriptNotifyIssue: Error, Equatable {
    let message: String
}

enum ScriptNotificationRequest: Equatable {
    case schedule(id: String, seconds: Double, title: String, body: String)
    case cancel(id: String)
    case cancelAll

    /// 1つのツールで予約しておける通知の数
    static let maxPending = 8
    static let maxSeconds = 86_400.0
    static let maxTitle = 40
    static let maxBody = 120
    /// 1回の呼び出し(1コマ)で受け付ける依頼の数
    static let maxPerCall = 4

    /// JSON の文字列(土台の JavaScript が作る)から読む。読めないときは理由
    static func parse(_ json: String) -> Result<ScriptNotificationRequest, ScriptNotifyIssue> {
        guard let data = json.data(using: .utf8), let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let op = raw["op"] as? String else { return .failure(ScriptNotifyIssue(message: "読めない指定です")) }
        if op == "cancelAll" { return .success(.cancelAll) }
        guard let id = raw["id"] as? String, id.range(of: "^[A-Za-z0-9_-]{1,30}$", options: .regularExpression) != nil else {
            return .failure(ScriptNotifyIssue(message: "id は英数字と _ - だけの30文字までにしてください"))
        }
        switch op {
        case "cancel":
            return .success(.cancel(id: id))
        case "schedule":
            guard let seconds = (raw["seconds"] as? NSNumber)?.doubleValue, seconds.isFinite, seconds >= 1, seconds <= maxSeconds else {
                return .failure(ScriptNotifyIssue(message: "秒は1〜\(Int(maxSeconds))にしてください"))
            }
            let title = String(((raw["title"] as? String) ?? "").prefix(maxTitle))
            let body = String(((raw["body"] as? String) ?? "").prefix(maxBody))
            return .success(.schedule(id: id, seconds: seconds, title: title.isEmpty ? "小ツール" : title, body: body))
        default:
            return .failure(ScriptNotifyIssue(message: "読めない指定です"))
        }
    }

    /// 通知の識別子(ツールごとに分ける。ほかのツールやアプリのタイマーの通知には触れない)
    static func identifier(toolID: String, id: String) -> String { "script.\(toolID).\(id)" }
    static func prefix(toolID: String) -> String { "script.\(toolID)." }
}

/// スクリプトの通知を、端末のローカル通知にする(通信しない)
enum ScriptNotifications {
    static func apply(_ request: ScriptNotificationRequest, toolID: String, toolName: String) {
        let center = UNUserNotificationCenter.current()
        switch request {
        case .schedule(let id, let seconds, let title, let body):
            let identifier = ScriptNotificationRequest.identifier(toolID: toolID, id: id)
            center.getPendingNotificationRequests { pending in
                let prefix = ScriptNotificationRequest.prefix(toolID: toolID)
                let others = pending.filter { $0.identifier.hasPrefix(prefix) && $0.identifier != identifier }
                // 上限を超える予約はしない(ツールが通知を出しすぎないように)
                guard others.count < ScriptNotificationRequest.maxPending else { return }
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    guard granted else { return }
                    let content = UNMutableNotificationContent()
                    content.title = title
                    content.body = body.isEmpty ? toolName : body
                    content.sound = .default
                    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
                    center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
                }
            }
        case .cancel(let id):
            let identifier = ScriptNotificationRequest.identifier(toolID: toolID, id: id)
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            center.removeDeliveredNotifications(withIdentifiers: [identifier])
        case .cancelAll:
            cancelAll(toolID: toolID)
        }
    }

    /// そのツールの通知をすべて取り消す(ツールを削除したときも)
    static func cancelAll(toolID: String) {
        let center = UNUserNotificationCenter.current()
        let prefix = ScriptNotificationRequest.prefix(toolID: toolID)
        center.getPendingNotificationRequests { pending in
            center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(prefix) })
        }
    }
}

/// 暗号に使える乱数(SecRandomCopyBytes)。パスワードを作るツール用(`random.secure()`)。0 以上 1 未満
enum ScriptSecureRandom {
    static func next() -> Double {
        var value: UInt64 = 0
        let status = withUnsafeMutableBytes(of: &value) { SecRandomCopyBytes(kSecRandomDefault, 8, $0.baseAddress!) }
        if status != errSecSuccess { value = UInt64.random(in: 0...UInt64.max) }
        return Double(value >> 11) / Double(1 << 53)
    }
}

/// クリップボードへのコピーの上限(書くだけ。読むことはできない)
enum ScriptClipboard {
    static let maxLength = 10_000
}
