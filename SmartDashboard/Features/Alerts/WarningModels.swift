import Foundation

/// 警報・注意報の段階。気象庁の警報ページの区分(レベル2〜5)に合わせる。
enum WarningLevel: Int, Codable, Comparable, CaseIterable {
    case unknown = 0
    case advisory = 20
    case warning = 30
    case danger = 40
    case special = 50

    static func < (a: WarningLevel, b: WarningLevel) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .unknown: return "不明"
        case .advisory: return "注意報"
        case .warning: return "警報"
        case .danger: return "危険警報"
        case .special: return "特別警報"
        }
    }
}

/// 警報のコードと名称・段階の対応。
/// 気象庁の警報ページ(https://www.jma.go.jp/bosai/warning/)のスクリプトにある表を 2026-09-20 に確認して写したもの。
/// 河川の氾濫(別のファイル flood_xml.json)は扱わない。表にないコードは「不明」として名称にコードを出す。
enum WarningCatalog {
    static let table: [String: (name: String, level: WarningLevel)] = [
        "33": ("大雨特別警報", .special), "43": ("大雨危険警報", .danger), "03": ("大雨警報", .warning), "10": ("大雨注意報", .advisory),
        "39": ("土砂災害特別警報", .special), "49": ("土砂災害危険警報", .danger), "09": ("土砂災害警報", .warning), "29": ("土砂災害注意報", .advisory),
        "38": ("高潮特別警報", .special), "48": ("高潮危険警報", .danger), "08": ("高潮警報", .warning), "19": ("高潮注意報", .advisory),
        "35": ("暴風特別警報", .special), "05": ("暴風警報", .warning), "15": ("強風注意報", .advisory),
        "32": ("暴風雪特別警報", .special), "02": ("暴風雪警報", .warning), "13": ("風雪注意報", .advisory),
        "36": ("大雪特別警報", .special), "06": ("大雪警報", .warning), "12": ("大雪注意報", .advisory),
        "37": ("波浪特別警報", .special), "07": ("波浪警報", .warning), "16": ("波浪注意報", .advisory),
        "14": ("雷注意報", .advisory), "17": ("融雪注意報", .advisory), "20": ("濃霧注意報", .advisory),
        "21": ("乾燥注意報", .advisory), "22": ("なだれ注意報", .advisory), "23": ("低温注意報", .advisory),
        "24": ("霜注意報", .advisory), "25": ("着氷注意報", .advisory), "26": ("着雪注意報", .advisory),
    ]

    static func entry(_ code: String) -> (name: String, level: WarningLevel) {
        table[code] ?? ("警報・注意報(コード\(code))", .unknown)
    }
}

/// https://www.jma.go.jp/bosai/warning/data/r8/{府県予報区}.json の応答。
/// 種類ごとの報(大雨、土砂災害、風、波、雷など)が配列で入っている。公式のAPIではない。
struct JMAWarningReport: Decodable {
    struct Kind: Decodable {
        let code: String?
        let status: String?
        let additions: [String]?
    }

    struct Item: Decodable {
        let areaCode: String
        let kinds: [Kind]
    }

    struct Body: Decodable {
        let class20Items: [Item]?
    }

    let reportDatetime: String?
    let headlineText: String?
    let warning: Body?

    static func decode(_ data: Data) throws -> [JMAWarningReport] {
        try JSONDecoder().decode([JMAWarningReport].self, from: data)
    }
}

/// 発表中の警報・注意報(1件)
struct ActiveWarning: Codable, Equatable, Identifiable {
    var code: String
    var name: String
    var level: WarningLevel
    /// 「発表」「継続」「警報から注意報」など
    var status: String
    /// 「うねり」「突風」などの付加事項
    var additions: [String]
    var id: String { code }
}

enum WarningExtractor {
    /// 指定した市区町村(分割されている市は複数)に発表中の警報・注意報を取り出す。
    /// 解除されたものと、コードのない項目(発表なし)は除く。重い順に並べる。
    static func active(reports: [JMAWarningReport], areaCodes: [String]) -> [ActiveWarning] {
        let targets = Set(areaCodes)
        var found: [String: ActiveWarning] = [:]
        for report in reports {
            for item in report.warning?.class20Items ?? [] where targets.contains(item.areaCode) {
                for kind in item.kinds {
                    guard let code = kind.code, !code.isEmpty else { continue }
                    let status = kind.status ?? ""
                    if status.contains("解除") { continue }
                    let entry = WarningCatalog.entry(code)
                    var warning = found[code] ?? ActiveWarning(code: code, name: entry.name, level: entry.level, status: status, additions: [])
                    for addition in kind.additions ?? [] where !warning.additions.contains(addition) {
                        warning.additions.append(addition)
                    }
                    found[code] = warning
                }
            }
        }
        return found.values.sorted { ($0.level, $1.code) > ($1.level, $0.code) }
    }

    /// 最新の発表時刻(報ごとに違うので一番新しいもの)
    static func latestReportDate(_ reports: [JMAWarningReport]) -> Date? {
        let formatter = ISO8601DateFormatter()
        return reports.compactMap { $0.reportDatetime.flatMap(formatter.date(from:)) }.max()
    }
}

/// キャッシュと表示に使う警報・注意報
struct WarningSnapshot: Codable, Equatable {
    var area: WarningArea
    var warnings: [ActiveWarning]
    var reportedAt: Date?

    var maxLevel: WarningLevel? { warnings.map(\.level).max() }
}
