import XCTest
@testable import SmartDashboard

/// 電車タブの表示の状態(地図と路線図で共有し、保存する)
@MainActor
final class TrainDisplayStateTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let name = "TrainDisplayStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testDefaultsToMapAllTrainsAllRailways() {
        let state = TrainDisplayState(defaults: makeDefaults())
        XCTAssertEqual(state.mode, .map)
        XCTAssertEqual(state.filter, .all)
        XCTAssertEqual(state.selectedRailwayID, TrainRailwaySelection.all)
        XCTAssertTrue(state.showsAllRailways)
    }

    /// 地図と路線図は同じ TrainDisplayState を見るので、片方で変えた内容はもう片方でもそのまま読める。
    /// 表示(地図/路線図)を切り替えても、路線と絞り込みの選択は変わらない。
    func testSelectionSurvivesSwitchingBetweenMapAndDiagram() {
        let state = TrainDisplayState(defaults: makeDefaults())
        state.mode = .diagram
        state.selectedRailwayID = "odpt.Railway:Toei.Oedo"
        state.filter = .registered
        state.mode = .map
        XCTAssertEqual(state.selectedRailwayID, "odpt.Railway:Toei.Oedo")
        XCTAssertEqual(state.filter, .registered)
        state.selectedRailwayID = "odpt.Railway:Toei.Mita"
        state.mode = .diagram
        XCTAssertEqual(state.selectedRailwayID, "odpt.Railway:Toei.Mita")
        XCTAssertFalse(state.showsAllRailways)
    }

    func testStateIsRestoredAfterRelaunch() {
        let defaults = makeDefaults()
        let first = TrainDisplayState(defaults: defaults)
        first.mode = .diagram
        first.filter = .nearMe
        first.selectedRailwayID = "odpt.Railway:Toei.Asakusa"

        let relaunched = TrainDisplayState(defaults: defaults)
        XCTAssertEqual(relaunched.mode, .diagram)
        XCTAssertEqual(relaunched.filter, .nearMe)
        XCTAssertEqual(relaunched.selectedRailwayID, "odpt.Railway:Toei.Asakusa")
    }

    func testSelectionFallsBackWhenRailwayIsRemoved() {
        let defaults = makeDefaults()
        let state = TrainDisplayState(defaults: defaults)
        let asakusa = "odpt.Railway:Toei.Asakusa"
        let oedo = "odpt.Railway:Toei.Oedo"
        let mita = "odpt.Railway:Toei.Mita"
        state.selectedRailwayID = oedo

        // 残っていればそのまま
        state.validate(available: [asakusa, oedo, mita])
        XCTAssertEqual(state.selectedRailwayID, oedo)
        // 選んでいた路線を削除したら「すべての路線」に戻す
        state.validate(available: [asakusa, mita])
        XCTAssertEqual(state.selectedRailwayID, TrainRailwaySelection.all)
        // 戻した結果も保存される
        XCTAssertEqual(TrainDisplayState(defaults: defaults).selectedRailwayID, TrainRailwaySelection.all)
    }

    func testResolvedSelection() {
        let a = "a", b = "b"
        XCTAssertEqual(TrainDisplayState.resolved(a, available: [a, b]), a)
        XCTAssertEqual(TrainDisplayState.resolved("gone", available: [a, b]), TrainRailwaySelection.all)
        XCTAssertEqual(TrainDisplayState.resolved(TrainRailwaySelection.all, available: [a, b]), TrainRailwaySelection.all)
        // 路線が1本だけ(または0本)なら、選ぶ部品は出ないので「すべての路線」にそろえる
        XCTAssertEqual(TrainDisplayState.resolved(a, available: [a]), TrainRailwaySelection.all)
        XCTAssertEqual(TrainDisplayState.resolved(a, available: []), TrainRailwaySelection.all)
    }

    func testEmphasis() {
        // 「すべての路線」なら全路線を通常の表示にする
        XCTAssertTrue(TrainDisplayState.isEmphasized("a", selected: TrainRailwaySelection.all))
        XCTAssertTrue(TrainDisplayState.isEmphasized("a", selected: "a"))
        // 選んでいない路線は薄く表示する
        XCTAssertFalse(TrainDisplayState.isEmphasized("b", selected: "a"))
    }

    func testUnknownStoredValuesFallBackToDefaults() {
        let defaults = makeDefaults()
        defaults.set("broken", forKey: "train.viewMode")
        defaults.set("broken", forKey: "train.filter")
        let state = TrainDisplayState(defaults: defaults)
        XCTAssertEqual(state.mode, .map)
        XCTAssertEqual(state.filter, .all)
    }
}
