"""国土数値情報(鉄道データ N02)から、線路の形をアプリに同梱するファイルを作り直す。

使い方(リポジトリの直下で):
    python scripts/update_railway_shapes.py Toei              # 都営だけを作り直す(ほかの事業者の分は残す)
    python scripts/update_railway_shapes.py Toei TokyoMetro   # 複数の事業者
    python scripts/update_railway_shapes.py --all             # 対応表にあるすべての事業者
    python scripts/update_railway_shapes.py Toei --zip N02-25_GML.zip   # ダウンロード済みのファイルを使う

- 取得元: 国土数値情報ダウンロードサイト 鉄道データ(N02)https://nlftp.mlit.go.jp/ksj/gml/datalist/KsjTmplt-N02-2025.html
  利用条件は CC BY 4.0(2020年度以降の版)。出典の表記と、加工したことの明記が必要(アプリ内と README に書いてある)。
- 事業者と路線の対応は scripts/railway_shape_sources.json(ODPT の路線ID → N02 の運営会社と路線名)。事業者を増やすときは、そこに足す。
- 駅の順と位置は ODPT から取る(都営は公開エンドポイント。トークンが必要な事業者は、環境変数 ODPT_TOKEN にトークンを入れる)。
- 路線ごとに、N02 の線をつないだ網の上で、隣り合う駅の間の最短の道をつなぎ、駅の順に並んだ1本の線にする(大江戸線のように、同じ駅を2回通る路線も駅の順のまま)。
- 点は、線からのずれが5m以内になるように間引く(Douglas-Peucker)。
- SmartDashboard/Resources/railway_shapes.json に書く。取得日(fetched)と元のデータの版(source)を記録する。
- 年に1回程度(N02 の新しい版が出たとき)、手元で実行してコミットする。アプリは通信で取得しない。
"""
import argparse
import datetime
import heapq
import io
import json
import math
import os
import sys
import urllib.parse
import urllib.request
import zipfile

N02_VERSION = "N02-25"
N02_URL = "https://nlftp.mlit.go.jp/ksj/gml/data/N02/{v}/{v}_GML.zip"
SOURCES = "scripts/railway_shape_sources.json"
OUTPUT = "SmartDashboard/Resources/railway_shapes.json"
ODPT_BASE = {"public": "https://api-public.odpt.org/api/v4/", "token": "https://api.odpt.org/api/v4/"}
TOLERANCE_METERS = 5.0
EARTH = 6371000.0


def local(point, origin):
    """origin のまわりを平面とみなした座標(m)。点は (経度, 緯度)。"""
    lat = math.radians((point[1] + origin[1]) / 2)
    return ((point[0] - origin[0]) * math.pi / 180 * EARTH * math.cos(lat), (point[1] - origin[1]) * math.pi / 180 * EARTH)


def distance(a, b):
    x, y = local(b, a)
    return math.hypot(x, y)


def segment_distance(p, a, b):
    ax, ay = local(a, p)
    bx, by = local(b, p)
    dx, dy = bx - ax, by - ay
    length = dx * dx + dy * dy
    t = 0 if length == 0 else max(0.0, min(1.0, -(ax * dx + ay * dy) / length))
    return math.hypot(ax + dx * t, ay + dy * t)


def simplify(points, tolerance):
    """Douglas-Peucker。両端は必ず残す。"""
    if len(points) < 3:
        return points
    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    stack = [(0, len(points) - 1)]
    while stack:
        first, last = stack.pop()
        best, index = 0.0, -1
        for i in range(first + 1, last):
            d = segment_distance(points[i], points[first], points[last])
            if d > best:
                best, index = d, i
        if index >= 0 and best > tolerance:
            keep[index] = True
            stack.append((first, index))
            stack.append((index, last))
    return [p for p, k in zip(points, keep) if k]


def load_n02(zip_path):
    with zipfile.ZipFile(zip_path) as archive:
        name = next(n for n in archive.namelist() if n.endswith("RailroadSection.geojson") and "UTF-8" in n)
        return json.loads(archive.read(name).decode("utf-8"))["features"]


def fetch_json(url):
    request = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.loads(response.read().decode("utf-8"))


def odpt(endpoint, kind, **query):
    if endpoint == "token":
        token = os.environ.get("ODPT_TOKEN", "")
        if not token:
            raise SystemExit("この事業者はトークンが必要です。環境変数 ODPT_TOKEN を設定してください(トークンはコミットしない)")
        query["acl:consumerKey"] = token
    return fetch_json(ODPT_BASE[endpoint] + kind + "?" + urllib.parse.urlencode(query))


def build_graph(features, company, names):
    """N02 の線をつないだ網。点は座標(小数第6位で丸める)、辺は隣り合う点。"""
    graph = {}
    for feature in features:
        props = feature["properties"]
        if props.get("N02_004") != company or props.get("N02_003") not in names:
            continue
        lines = feature["geometry"]["coordinates"]
        if feature["geometry"]["type"] == "LineString":
            lines = [lines]
        for line in lines:
            points = [(round(p[0], 6), round(p[1], 6)) for p in line]
            for a, b in zip(points, points[1:]):
                if a == b:
                    continue
                d = distance(a, b)
                graph.setdefault(a, {})[b] = d
                graph.setdefault(b, {})[a] = d
    return graph


def shortest_path(graph, start, goal):
    if start == goal:
        return [start]
    best = {start: 0.0}
    previous = {}
    queue = [(0.0, start)]
    while queue:
        cost, node = heapq.heappop(queue)
        if node == goal:
            break
        if cost > best.get(node, math.inf):
            continue
        for neighbor, d in graph[node].items():
            value = cost + d
            if value < best.get(neighbor, math.inf):
                best[neighbor] = value
                previous[neighbor] = node
                heapq.heappush(queue, (value, neighbor))
    if goal not in best:
        return None
    path = [goal]
    while path[-1] != start:
        path.append(previous[path[-1]])
    return list(reversed(path))


def build_railway(graph, stations):
    """駅の順に、隣り合う駅の間の最短の道をつなぐ。stations は (駅ID, 名前, (経度, 緯度))。"""
    nodes = list(graph.keys())
    anchors = []
    for station_id, name, point in stations:
        node = min(nodes, key=lambda n: distance(point, n))
        anchors.append((station_id, name, point, node, distance(point, node)))
    points = [anchors[0][3]]
    for (_, name_a, _, a, _), (_, name_b, _, b, _) in zip(anchors, anchors[1:]):
        path = shortest_path(graph, a, b)
        if path is None:
            raise SystemExit(f"{name_a} と {name_b} の間が、線路の網でつながっていません")
        points.extend(path[1:])
    return points, anchors


SNAP_WINDOW = 100.0


def choose(candidates):
    """候補(線までの距離, 線に沿った位置)を位置の順に並べ、谷(前後より近い所)だけを残す。
    最短から100m以内の谷のうち、一番手前のもの。"""
    candidates = sorted(candidates, key=lambda c: c[1])
    valleys = []
    for i, c in enumerate(candidates):
        before = candidates[i - 1][0] if i > 0 else math.inf
        after = candidates[i + 1][0] if i + 1 < len(candidates) else math.inf
        if c[0] <= before and c[0] <= after:
            valleys.append(c)
    nearest = min(c[0] for c in valleys)
    return min((c for c in valleys if c[0] <= nearest + SNAP_WINDOW), key=lambda c: c[1])


def check_stations(points, stations):
    """アプリ(RideLine)と同じ規則で、駅を順に線へ投影する。
    前の駅より先の区間のうち、線までの距離が最短から100m以内の候補で、一番手前の位置を選ぶ(環状の区間で先へ飛ばないように)。
    線までの距離の最大と、すべての駅を順に投影できたかを返す。"""
    cumulative = [0.0]
    for a, b in zip(points, points[1:]):
        cumulative.append(cumulative[-1] + distance(a, b))
    previous = 0.0
    worst = (0.0, "")
    ordered = True
    for _, name, point in stations:
        candidates = []
        for i, (a, b) in enumerate(zip(points, points[1:])):
            if cumulative[i + 1] < previous:
                continue
            ax, ay = local(a, point)
            bx, by = local(b, point)
            dx, dy = bx - ax, by - ay
            length = dx * dx + dy * dy
            t = 0 if length == 0 else max(0.0, min(1.0, -(ax * dx + ay * dy) / length))
            along = cumulative[i] + (cumulative[i + 1] - cumulative[i]) * t
            if along < previous:
                along = previous
                t = (along - cumulative[i]) / max(1e-9, cumulative[i + 1] - cumulative[i])
            lateral = math.hypot(ax + dx * t, ay + dy * t)
            candidates.append((lateral, along))
        if not candidates:
            ordered = False
            continue
        lateral, along = choose(candidates)
        if lateral > worst[0]:
            worst = (lateral, name)
        previous = along
    return worst, ordered


def main():
    parser = argparse.ArgumentParser(description="国土数値情報(鉄道)から線路の形を作る")
    parser.add_argument("operators", nargs="*", help="事業者のキー(railway_shape_sources.json の operators)")
    parser.add_argument("--all", action="store_true", help="対応表のすべての事業者")
    parser.add_argument("--zip", help="ダウンロード済みの N02 の zip(省略するとダウンロードする)")
    args = parser.parse_args()

    with open(SOURCES, encoding="utf-8") as file:
        sources = json.load(file)["operators"]
    keys = list(sources.keys()) if args.all else args.operators
    if not keys:
        parser.error("事業者を指定してください(例: Toei)")
    unknown = [k for k in keys if k not in sources]
    if unknown:
        parser.error("対応表にない事業者です: " + ", ".join(unknown))

    zip_path = args.zip
    if not zip_path:
        url = N02_URL.format(v=N02_VERSION)
        print(f"{url} をダウンロードしています(約15MB)")
        request = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(request, timeout=300) as response:
            zip_path = io.BytesIO(response.read())
    features = load_n02(zip_path)

    output = {"railways": {}}
    if os.path.exists(OUTPUT):
        with open(OUTPUT, encoding="utf-8") as file:
            output = json.load(file)
    railways_out = output.get("railways", {})

    for key in keys:
        source = sources[key]
        endpoint = source["endpoint"]
        operator_id = source["odptOperator"]
        stations = {s["owl:sameAs"]: s for s in odpt(endpoint, "odpt:Station", **{"odpt:operator": operator_id})}
        railways = {r["owl:sameAs"]: r for r in odpt(endpoint, "odpt:Railway", **{"odpt:operator": operator_id})}
        for railway_id, names in source["railways"].items():
            railway = railways.get(railway_id)
            if railway is None:
                print(f"  {railway_id}: ODPT に路線がありません。飛ばします")
                continue
            order = sorted(railway.get("odpt:stationOrder", []), key=lambda o: o["odpt:index"])
            ordered = []
            for entry in order:
                station = stations.get(entry["odpt:station"])
                if station and "geo:lat" in station and "geo:long" in station:
                    ordered.append((entry["odpt:station"], station.get("dc:title", ""), (station["geo:long"], station["geo:lat"])))
            graph = build_graph(features, source["n02Company"], set(names))
            if not graph or len(ordered) < 2:
                print(f"  {railway_id}: N02 に {names} がないか、駅が足りません。飛ばします(アプリは駅を結んだ直線を使う)")
                continue
            points, anchors = build_railway(graph, ordered)
            simplified = simplify(points, TOLERANCE_METERS)
            length = sum(distance(a, b) for a, b in zip(points, points[1:]))
            worst, ordered = check_stations(simplified, ordered)
            if not ordered:
                print(f"  {railway_id}: 駅の順に線へ投影できませんでした。確認してください")
            railways_out[railway_id] = {
                "n02": names,
                "points": [[round(p[1], 6), round(p[0], 6)] for p in simplified],
            }
            print(f"  {railway_id}: {len(points)}点 → {len(simplified)}点、{length / 1000:.1f}km、"
                  f"駅と線路のずれの最大 {worst[0]:.0f}m({worst[1]})")

    output = {
        "source": f"国土数値情報(鉄道データ){N02_VERSION}(国土交通省)を加工して作成。CC BY 4.0",
        "sourceURL": "https://nlftp.mlit.go.jp/ksj/gml/datalist/KsjTmplt-N02-2025.html",
        "processing": f"運営会社と路線名で抜き出し、駅の順につないで1本の線にし、ずれ{TOLERANCE_METERS:.0f}m以内で点を間引いた",
        "fetched": datetime.date.today().isoformat(),
        "railways": dict(sorted(railways_out.items())),
    }
    with open(OUTPUT, "w", encoding="utf-8", newline="\n") as file:
        json.dump(output, file, ensure_ascii=False, separators=(",", ":"))
    print(f"{len(railways_out)}路線を {OUTPUT} に書きました")
    return 0


if __name__ == "__main__":
    sys.exit(main())
