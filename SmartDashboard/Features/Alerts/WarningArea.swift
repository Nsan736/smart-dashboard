import Foundation

/// 警報の発表単位(市区町村)と、その府県予報区
struct WarningArea: Codable, Equatable {
    /// 府県予報区のコード(例: 130000)。警報のファイル名に使う。
    var officeCode: String
    /// 市区町村のコード。気象庁が1つの市を複数に分けている場合(例: 横浜市北部・南部)は、すべて入れる。
    var areaCodes: [String]
    /// 表示名(例: 千代田区、横浜市)
    var name: String
    /// 都道府県名(例: 東京都)
    var prefecture: String

    /// 分割されている市で、どの区域にいるかは名前から決められないため、全区域をまとめて扱っている
    var coversWholeCity: Bool { areaCodes.count > 1 }
}

/// 気象庁の地域の一覧(area.json)から、市区町村と府県予報区だけを取り出してアプリに同梱した表。
/// 元の一覧は約260KB(転送時は約51KB)あるので、通信では取得しない。
struct JMAAreaTable {
    struct Entry: Equatable {
        var code: String
        var name: String
        var officeCode: String
    }

    let entries: [Entry]

    init(entries: [Entry]) {
        self.entries = entries
    }

    /// 同梱した jma_areas.json の形式: {"class20": [[コード, 名前, 府県予報区], ...]}
    init(data: Data) throws {
        struct File: Decodable { let class20: [[String]] }
        let file = try JSONDecoder().decode(File.self, from: data)
        entries = file.class20.compactMap { row in
            row.count == 3 ? Entry(code: row[0], name: row[1], officeCode: row[2]) : nil
        }
    }

    static func bundled() -> JMAAreaTable? {
        guard let url = Bundle(for: BundleToken.self).url(forResource: "jma_areas", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JMAAreaTable(data: data)
    }

    private final class BundleToken {}
}

enum WarningAreaResolver {
    /// 都道府県名(JISの順)。市区町村コードの先頭2桁と対応する。
    static let prefectures = [
        "北海道", "青森県", "岩手県", "宮城県", "秋田県", "山形県", "福島県", "茨城県", "栃木県", "群馬県", "埼玉県", "千葉県",
        "東京都", "神奈川県", "新潟県", "富山県", "石川県", "福井県", "山梨県", "長野県", "岐阜県", "静岡県", "愛知県", "三重県",
        "滋賀県", "京都府", "大阪府", "兵庫県", "奈良県", "和歌山県", "鳥取県", "島根県", "岡山県", "広島県", "山口県", "徳島県",
        "香川県", "愛媛県", "高知県", "福岡県", "佐賀県", "長崎県", "熊本県", "大分県", "宮崎県", "鹿児島県", "沖縄県",
    ]

    static func prefectureCode(_ name: String?) -> String? {
        guard let name, let index = prefectures.firstIndex(of: name) else { return nil }
        return String(format: "%02d", index + 1)
    }

    /// 逆ジオコーディングで得た都道府県名と市区町村名から、警報の発表単位を決める。
    /// - 名前が一致する市区町村を探す(「黒川郡大和町」のように郡が付いていても一致させる)
    /// - 気象庁が分割している市(「横浜市北部」など)は、名前だけでは区域を決められないので、全区域を対象にする
    /// - 決められないときは nil(推測で別の地域を出さない)
    static func resolve(prefecture: String?, municipality: String?, table: JMAAreaTable) -> WarningArea? {
        guard let prefix = prefectureCode(prefecture), let municipality, !municipality.isEmpty else { return nil }
        let candidates = table.entries.filter { $0.code.hasPrefix(prefix) }
        var names = [municipality]
        // 「◯◯郡△△町」→「△△町」。「郡山市」「大和郡山市」を壊さないよう、郡のあとに町・村が続く場合だけ
        if let range = municipality.range(of: "郡"), range.lowerBound != municipality.startIndex {
            let rest = String(municipality[range.upperBound...])
            if rest.hasSuffix("町") || rest.hasSuffix("村") { names.append(rest) }
        }
        for name in names {
            if let exact = candidates.first(where: { $0.name == name }) {
                return WarningArea(officeCode: exact.officeCode, areaCodes: [exact.code], name: name, prefecture: prefecture ?? "")
            }
        }
        for name in names {
            let parts = candidates.filter { $0.name.hasPrefix(name) && $0.name.count > name.count }
            if let first = parts.first, parts.allSatisfy({ $0.officeCode == first.officeCode }) {
                return WarningArea(officeCode: first.officeCode, areaCodes: parts.map(\.code), name: name, prefecture: prefecture ?? "")
            }
        }
        return nil
    }
}
