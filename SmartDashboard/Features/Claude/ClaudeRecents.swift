import Foundation
import Observation
import SwiftUI

/// Claude で作ったものの「最近作ったもの」の1件
protocol ClaudeRecentEntry: Codable, Identifiable, Equatable where ID == UUID {
    var createdAt: Date { get }
}

/// 最近作ったものの一覧の操作(新しい順、機能ごとに最新10件まで)。純粋なロジックとしてテストする
enum ClaudeRecentList {
    static let limit = 10

    /// 同じ ID のものは置き換え、新しい順に並べて、上限を超えた古いものを捨てる
    static func upserting<Entry: ClaudeRecentEntry>(_ entry: Entry, into list: [Entry], limit: Int = limit) -> [Entry] {
        var result = list.filter { $0.id != entry.id }
        result.append(entry)
        result.sort { $0.createdAt > $1.createdAt }
        return Array(result.prefix(limit))
    }

    static func encode<Entry: ClaudeRecentEntry>(_ entries: [Entry]) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return try? encoder.encode(entries)
    }

    /// 読めなければ空(壊れたファイルで落とさない)
    static func decode<Entry: ClaudeRecentEntry>(_ data: Data?, as type: Entry.Type) -> [Entry] {
        guard let data else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let entries = (try? decoder.decode([Entry].self, from: data)) ?? []
        return Array(entries.sorted { $0.createdAt > $1.createdAt }.prefix(limit))
    }

    /// 保存する場所(Application Support/SmartDashboard/claude-recents/)
    static func fileURL(_ name: String) -> URL {
        DiskCache.defaultDirectory("SmartDashboard").appendingPathComponent("claude-recents", isDirectory: true)
            .appendingPathComponent(name)
    }

    /// 一覧に出す日時(「10/18 21:05」)
    static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M/d HH:mm"
        return formatter.string(from: date)
    }
}

/// 最近作ったものの一覧。変えるたびに .atomic で保存する(キャッシュの削除では消さない)
@MainActor
@Observable
final class ClaudeRecents<Entry: ClaudeRecentEntry> {
    private(set) var entries: [Entry]
    @ObservationIgnored let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
        entries = ClaudeRecentList.decode(try? Data(contentsOf: fileURL), as: Entry.self)
    }

    func entry(_ id: UUID?) -> Entry? {
        guard let id else { return nil }
        return entries.first { $0.id == id }
    }

    func upsert(_ entry: Entry) {
        entries = ClaudeRecentList.upserting(entry, into: entries)
        save()
    }

    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    private func save() {
        guard let data = ClaudeRecentList.encode(entries) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// 機能の画面の上に出す帯。作っている間は「作成中…」、できたら「できました(確認する)」。タップで作る画面に戻る
struct ClaudeWorkBanner: View {
    let isRunning: Bool
    let hasResult: Bool
    var runningText = "作成中…"
    var doneText = "できました(確認する)"
    let action: () -> Void

    var body: some View {
        if isRunning || hasResult {
            Button(action: action) {
                HStack(spacing: 8) {
                    if isRunning {
                        ProgressView()
                    } else {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    Text(isRunning ? runningText : doneText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
        }
    }
}
