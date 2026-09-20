import Foundation

/// ホームのカードの種類。並びは初期の表示順で、新しいカードは末尾に足す。
enum HomeCardKind: String, Codable, CaseIterable, Identifiable {
    case timer
    case nextTrain
    case trainInfo
    case weather
    case rain
    case exchange
    case speed
    case sensors
    case warnings
    case quakes
    case pressure
    /// スコープ(以前の名前はウェイポイント。保存済みの設定を引き継ぐため、値は変えない)
    case waypoint

    var id: String { rawValue }

    var title: String {
        switch self {
        case .timer: return "タイマー"
        case .nextTrain: return "次の電車"
        case .trainInfo: return "運行情報"
        case .weather: return "天気"
        case .rain: return "雨の要約"
        case .exchange: return "為替"
        case .speed: return "速度"
        case .sensors: return "センサー"
        case .warnings: return "警報・注意報"
        case .quakes: return "地震"
        case .pressure: return "気圧"
        case .waypoint: return "スコープ"
        }
    }

    var symbol: String {
        switch self {
        case .timer: return "timer"
        case .nextTrain: return "tram"
        case .trainInfo: return "exclamationmark.bubble"
        case .weather: return "cloud.sun"
        case .rain: return "umbrella"
        case .exchange: return "yensign.circle"
        case .speed: return "speedometer"
        case .sensors: return "gauge.with.dots.needle.33percent"
        case .warnings: return "exclamationmark.triangle"
        case .quakes: return "waveform.path.ecg"
        case .pressure: return "barometer"
        case .waypoint: return "scope"
        }
    }

    /// 編集画面に出す補足
    var detail: String? {
        switch self {
        case .timer: return "動作中のタイマーがあるときだけ表示"
        case .nextTrain, .trainInfo: return "路線・駅を登録しているときだけ表示"
        case .speed: return "表示中は高精度のGPSを使います"
        case .waypoint: return "一番近い地点か、ピン留めした地点を表示(測位はしません)"
        default: return nil
        }
    }
}

/// ホームのカードの並び順と表示・非表示
struct HomeLayout: Codable, Equatable {
    var order: [HomeCardKind]
    var hidden: Set<HomeCardKind>

    /// 初期状態で非表示のカード
    static let defaultHidden: Set<HomeCardKind> = [.waypoint]

    static let initial = HomeLayout(order: HomeCardKind.allCases, hidden: defaultHidden)

    var visible: [HomeCardKind] { order.filter { !hidden.contains($0) } }

    func shows(_ kind: HomeCardKind) -> Bool { !hidden.contains(kind) }

    /// 保存してあった並びを、今あるカードに合わせる。
    /// なくなったカードは捨て、重複は除き、新しく増えたカードは末尾に足す。
    func normalized() -> HomeLayout {
        var seen = Set<HomeCardKind>()
        var result = order.filter { seen.insert($0).inserted }
        var newHidden = hidden
        for kind in HomeCardKind.allCases where !seen.contains(kind) {
            result.append(kind)
            // あとから増えたカードのうち、初期状態で非表示のものは、非表示で足す
            if Self.defaultHidden.contains(kind) { newHidden.insert(kind) }
        }
        return HomeLayout(order: result, hidden: newHidden)
    }

    /// 保存データから復元する。知らない種類が混ざっていても、読めるものだけを使う。
    static func decode(_ data: Data?) -> HomeLayout {
        struct Raw: Decodable {
            let order: [String]
            let hidden: [String]
        }
        guard let data, let raw = try? JSONDecoder().decode(Raw.self, from: data) else { return initial }
        return HomeLayout(order: raw.order.compactMap(HomeCardKind.init(rawValue:)),
                          hidden: Set(raw.hidden.compactMap(HomeCardKind.init(rawValue:)))).normalized()
    }

    func encoded() -> Data? {
        try? JSONEncoder().encode(["order": order.map(\.rawValue), "hidden": hidden.map(\.rawValue).sorted()])
    }

    /// ホームに出していないカードのデータは、起動時・復帰時の自動更新で取得しない
    /// (各タブを開いたときは、そのタブが自分で取得する)
    var needsWeather: Bool { shows(.weather) || shows(.rain) || shows(.pressure) || shows(.warnings) }
    var needsRain: Bool { shows(.rain) }
    var needsExchange: Bool { shows(.exchange) }
    var needsTrainInfo: Bool { shows(.trainInfo) }
    var needsWarnings: Bool { shows(.warnings) }
    var needsQuakes: Bool { shows(.quakes) }
}
