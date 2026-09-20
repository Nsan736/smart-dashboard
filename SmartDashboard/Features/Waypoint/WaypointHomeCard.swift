import SwiftUI

/// ホームのカード。ピン留めした地点(なければ一番近い地点)の名前・方角・距離を表示する。
/// 測位はしない(最後に分かった現在地を使う)。タップでコンパス表示を開く。
struct WaypointHomeCard: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let store = env.waypoints
        let featured = store.featured()
        NavigationLink {
            WaypointSightView(mode: .compass, selectedID: featured?.waypoint.id)
        } label: {
            HomeCard(title: "ウェイポイント", symbol: "mappin.and.ellipse") {
                if let featured {
                    HStack(spacing: 10) {
                        Circle().fill(WaypointPalette.color(featured.waypoint.colorIndex)).frame(width: 18, height: 18)
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 4) {
                                Text(featured.waypoint.name).font(.headline).fixedSize(horizontal: false, vertical: true)
                                if featured.waypoint.isPinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.orange) }
                            }
                            Text(featured.waypoint.isPinned ? "ピン留めした地点" : "一番近い地点").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    BigValue(value: WaypointMath.summary(bearing: featured.bearing, distance: featured.distance), size: 30)
                    if let origin = store.origin {
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            Text("\(Formatters.ageLabel(origin.time, now: context.date))の現在地から")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if store.waypoints.isEmpty {
                    Text("地点が登録されていません(「その他」→「ウェイポイント」で登録)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("現在地が分かると、方角と距離を表示します。タップしてコンパス表示を開いてください。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(store.waypoints.isEmpty)
    }
}
