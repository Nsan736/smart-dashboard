import Foundation

/// 多言語のタイトル。日本語を優先する。
struct ODPTTitle: Codable, Equatable {
    let ja: String?
    let en: String?

    var text: String? { ja ?? en }
}

/// 仕様上は多言語オブジェクトだが、文字列で返る場合も受けられるようにする
struct ODPTFlexibleText: Decodable, Equatable {
    let text: String?

    init(from decoder: Decoder) throws {
        if let title = try? ODPTTitle(from: decoder) {
            text = title.text
        } else {
            text = try? decoder.singleValueContainer().decode(String.self)
        }
    }
}

struct ODPTTrainInformation: Decodable {
    let sameAs: String
    let date: String?
    let railway: String?
    let operatorID: String
    let timeOfOrigin: String?
    /// 平常時は省略される
    let status: ODPTFlexibleText?
    let text: ODPTFlexibleText?

    enum CodingKeys: String, CodingKey {
        case sameAs = "owl:sameAs"
        case date = "dc:date"
        case railway = "odpt:railway"
        case operatorID = "odpt:operator"
        case timeOfOrigin = "odpt:timeOfOrigin"
        case status = "odpt:trainInformationStatus"
        case text = "odpt:trainInformationText"
    }
}

struct ODPTRailway: Codable, Equatable, Identifiable {
    struct StationOrder: Codable, Equatable {
        let index: Int
        let station: String
        let stationTitle: ODPTTitle?

        enum CodingKeys: String, CodingKey {
            case index = "odpt:index"
            case station = "odpt:station"
            case stationTitle = "odpt:stationTitle"
        }
    }

    let sameAs: String
    let title: String?
    let railwayTitle: ODPTTitle?
    let operatorID: String
    let stationOrder: [StationOrder]?
    /// 路線の色 (例 "#FF535F")。ない路線もある。
    let color: String?
    let ascendingRailDirection: String?
    let descendingRailDirection: String?

    var id: String { sameAs }
    var name: String { railwayTitle?.text ?? title ?? ODPTID.tail(sameAs) }
    var directions: [String] { [ascendingRailDirection, descendingRailDirection].compactMap { $0 } }

    enum CodingKeys: String, CodingKey {
        case sameAs = "owl:sameAs"
        case title = "dc:title"
        case railwayTitle = "odpt:railwayTitle"
        case operatorID = "odpt:operator"
        case stationOrder = "odpt:stationOrder"
        case color = "odpt:color"
        case ascendingRailDirection = "odpt:ascendingRailDirection"
        case descendingRailDirection = "odpt:descendingRailDirection"
    }
}

struct ODPTStation: Codable, Equatable {
    let sameAs: String
    let title: String?
    let stationTitle: ODPTTitle?
    /// 緯度経度 (geo:lat / geo:long)。提供されない駅もありうる。
    let latitude: Double?
    let longitude: Double?

    var name: String { stationTitle?.text ?? title ?? ODPTID.tail(sameAs) }

    enum CodingKeys: String, CodingKey {
        case sameAs = "owl:sameAs"
        case title = "dc:title"
        case stationTitle = "odpt:stationTitle"
        case latitude = "geo:lat"
        case longitude = "geo:long"
    }
}

struct ODPTRailDirection: Codable, Equatable {
    let sameAs: String
    let title: String?
    let railDirectionTitle: ODPTTitle?

    var name: String { railDirectionTitle?.text ?? title ?? ODPTID.tail(sameAs) }

    enum CodingKeys: String, CodingKey {
        case sameAs = "owl:sameAs"
        case title = "dc:title"
        case railDirectionTitle = "odpt:railDirectionTitle"
    }
}

struct ODPTTrainType: Codable, Equatable {
    let sameAs: String
    let title: String?
    let trainTypeTitle: ODPTTitle?

    var name: String { trainTypeTitle?.text ?? title ?? ODPTID.tail(sameAs) }

    enum CodingKeys: String, CodingKey {
        case sameAs = "owl:sameAs"
        case title = "dc:title"
        case trainTypeTitle = "odpt:trainTypeTitle"
    }
}

struct ODPTStationTimetable: Decodable {
    struct Object: Decodable {
        let departureTime: String?
        let trainType: String?
        let destinationStation: [String]?
        let isLast: Bool?

        enum CodingKeys: String, CodingKey {
            case departureTime = "odpt:departureTime"
            case trainType = "odpt:trainType"
            case destinationStation = "odpt:destinationStation"
            case isLast = "odpt:isLast"
        }
    }

    let sameAs: String
    let issued: String?
    let station: String
    let railDirection: String?
    let calendar: String?
    let objects: [Object]

    enum CodingKeys: String, CodingKey {
        case sameAs = "owl:sameAs"
        case issued = "dct:issued"
        case station = "odpt:station"
        case railDirection = "odpt:railDirection"
        case calendar = "odpt:calendar"
        case objects = "odpt:stationTimetableObject"
    }
}

enum ODPTID {
    /// "odpt.Station:Keisei.Oshiage.Aoto" -> "Aoto"。名前が引けないときの代替表示。
    static func tail(_ id: String) -> String {
        id.split(whereSeparator: { $0 == "." || $0 == ":" }).last.map(String.init) ?? id
    }
}
