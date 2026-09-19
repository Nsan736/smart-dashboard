import Foundation
import Observation

enum TrainRailwaySelection {
    /// 「すべての路線」を表す値
    static let all = ""
}

/// 電車タブの表示の状態(地図/路線図、絞り込み、選んだ路線)。
/// 地図と路線図で1つを共有し、どちらで変えてももう一方に反映される。UserDefaults に保存し、開き直しても同じ状態で開く。
@MainActor
@Observable
final class TrainDisplayState {
    var mode: TrainViewMode {
        didSet { defaults.set(mode.rawValue, forKey: Keys.mode) }
    }
    var filter: TrainFilter {
        didSet { defaults.set(filter.rawValue, forKey: Keys.filter) }
    }
    /// 選んだ路線のID。空文字は「すべての路線」。
    var selectedRailwayID: String {
        didSet { defaults.set(selectedRailwayID, forKey: Keys.railway) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = defaults.string(forKey: Keys.mode).flatMap(TrainViewMode.init(rawValue:)) ?? .map
        filter = defaults.string(forKey: Keys.filter).flatMap(TrainFilter.init(rawValue:)) ?? .all
        selectedRailwayID = defaults.string(forKey: Keys.railway) ?? TrainRailwaySelection.all
    }

    var showsAllRailways: Bool { selectedRailwayID == TrainRailwaySelection.all }

    /// 路線を追加・削除したあとに呼ぶ。選んでいた路線がなくなっていたら「すべての路線」に戻す。
    func validate(available: [String]) {
        let resolved = Self.resolved(selectedRailwayID, available: available)
        if resolved != selectedRailwayID { selectedRailwayID = resolved }
    }

    /// 保存されている選択を、今ある路線に合わせる。
    /// - 「すべての路線」はそのまま
    /// - 選んでいた路線が残っていればそのまま
    /// - なくなっていたら「すべての路線」に戻す(路線が1本だけなら、選ぶ意味がないので「すべての路線」)
    nonisolated static func resolved(_ stored: String, available: [String]) -> String {
        guard stored != TrainRailwaySelection.all, available.count > 1, available.contains(stored) else { return TrainRailwaySelection.all }
        return stored
    }

    /// 選択に応じて、その路線を強調するか(falseなら薄く表示する)
    nonisolated static func isEmphasized(_ railwayID: String, selected: String) -> Bool {
        selected == TrainRailwaySelection.all || selected == railwayID
    }

    private enum Keys {
        static let mode = "train.viewMode"
        static let filter = "train.filter"
        static let railway = "train.selectedRailway"
    }
}
