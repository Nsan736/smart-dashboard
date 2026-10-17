"""線路の形に、線路の下の地面の標高と、区間の種類(高架・地上・地下)を付ける(update_railway_shapes.py から使う)。

- 地面の標高: 国土地理院の標高タイル(PNG)。DEM5A(航空レーザ、5mメッシュ、ズーム15)を使い、ない所は DEM5B(写真測量)、
  それもない所は DEM10B(10mメッシュ、ズーム14)。https://maps.gsi.go.jp/development/demtile.html
  航空レーザの標高は地表面(建物や橋を除いた地面)なので、高架や地下の区間でも「線路の下(上)の地面」の高さになる。
- 区間の種類: 国土地理院ベクトルタイル提供実験(experimental_bvmap)の鉄道中心線(railway)の railState(ズーム14)。
  0 通常部 → 地上、1 橋・高架 → 高架、2 トンネル・3 地下 → 地下、4 雪覆い → 地上、5〜7(運休中・その他・不明)→ 不明。
  路線の名前はないので、線路の点の近く(25m以内)で、向きが近く(35度以内)、種別のコード(rtCode の上5桁)が合う線を選ぶ。
  https://maps.gsi.go.jp/development/vt.html  属性: https://maps.gsi.go.jp/help/pdf/vector/attribute.pdf
- どちらも国土地理院コンテンツ利用規約(公共データ利用規約 第1.0版)で、出典と加工したことを書けば、加工して同梱できる。
- 外部のライブラリは使わない(PNG とベクトルタイルを標準ライブラリだけで読む)。タイルは一時フォルダにキャッシュする。
"""
import gzip
import math
import os
import struct
import tempfile
import time
import urllib.error
import urllib.request
import zlib

STEP_METERS = 25.0
MATCH_METERS = 25.0
MATCH_DEGREES = 35.0
VT_ZOOM = 14
CACHE = os.path.join(tempfile.gettempdir(), "smartdashboard_railway_heights")
DEM_SOURCES = [("dem5a_png", 15), ("dem5b_png", 15), ("dem_png", 14)]
KIND_CODES = {0: "g", 1: "e", 2: "u", 3: "u", 4: "g"}
EARTH = 6371000.0


# MARK: - 通信とキャッシュ

def fetch(url, name):
    os.makedirs(CACHE, exist_ok=True)
    path = os.path.join(CACHE, name)
    if os.path.exists(path):
        with open(path, "rb") as file:
            return file.read() or None
    request = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0", "Accept-Encoding": "gzip"})
    data = b""
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            data = response.read()
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise
    if data[:2] == b"\x1f\x8b":
        data = gzip.decompress(data)
    with open(path, "wb") as file:
        file.write(data)
    time.sleep(0.05)
    return data or None


def tile_of(lat, lon, z):
    n = 2 ** z
    fx = (lon + 180) / 360 * n
    fy = (1 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2 * n
    return fx, fy


def lonlat_of(fx, fy, z):
    n = 2 ** z
    lon = fx / n * 360 - 180
    lat = math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * fy / n))))
    return lon, lat


# MARK: - PNG(標高タイル)

def decode_png(data):
    """8bit RGB(またはRGBA)の PNG を、行ごとの (R, G, B) の並びにする"""
    assert data[:8] == b"\x89PNG\r\n\x1a\n"
    i, idat, width, height, color = 8, b"", 0, 0, 2
    while i < len(data):
        length = struct.unpack(">I", data[i:i + 4])[0]
        kind = data[i + 4:i + 8]
        body = data[i + 8:i + 8 + length]
        if kind == b"IHDR":
            width, height, depth, color = struct.unpack(">IIBB", body[:10])
            assert depth == 8 and color in (2, 6), "対応していない PNG"
        elif kind == b"IDAT":
            idat += body
        i += 12 + length
    raw = zlib.decompress(idat)
    bpp = 3 if color == 2 else 4
    stride = width * bpp
    rows, previous, pos = [], bytearray(stride), 0
    for _ in range(height):
        filter_type = raw[pos]
        line = bytearray(raw[pos + 1:pos + 1 + stride])
        pos += 1 + stride
        for x in range(stride):
            a = line[x - bpp] if x >= bpp else 0
            b = previous[x]
            c = previous[x - bpp] if x >= bpp else 0
            if filter_type == 1:
                line[x] = (line[x] + a) & 0xFF
            elif filter_type == 2:
                line[x] = (line[x] + b) & 0xFF
            elif filter_type == 3:
                line[x] = (line[x] + (a + b) // 2) & 0xFF
            elif filter_type == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                predictor = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                line[x] = (line[x] + predictor) & 0xFF
        rows.append(bytes(line))
        previous = line
    return rows, bpp


def elevation_from_rgb(r, g, b):
    """標高タイルの画素値から標高(m)。無効値 (128, 0, 0) は None。"""
    x = (r << 16) + (g << 8) + b
    if x == 1 << 23:
        return None
    return (x if x < 1 << 23 else x - (1 << 24)) * 0.01


class DemReader:
    def __init__(self):
        self.tiles = {}

    def _tile(self, name, z, x, y):
        key = (name, z, x, y)
        if key not in self.tiles:
            data = fetch(f"https://cyberjapandata.gsi.go.jp/xyz/{name}/{z}/{x}/{y}.png", f"{name}_{z}_{x}_{y}.png")
            self.tiles[key] = decode_png(data) if data else None
        return self.tiles[key]

    def elevation(self, lat, lon):
        """その地点の地面の標高(m)。DEM5A → DEM5B → DEM10B の順に、値のあるもの。"""
        for name, z in DEM_SOURCES:
            fx, fy = tile_of(lat, lon, z)
            tile = self._tile(name, z, int(fx), int(fy))
            if tile is None:
                continue
            rows, bpp = tile
            px = min(255, int((fx - int(fx)) * 256))
            py = min(255, int((fy - int(fy)) * 256))
            row = rows[py]
            value = elevation_from_rgb(row[px * bpp], row[px * bpp + 1], row[px * bpp + 2])
            if value is not None:
                return value
        return None


# MARK: - ベクトルタイル(鉄道中心線)

def _varint(buf, i):
    shift = result = 0
    while True:
        b = buf[i]
        i += 1
        result |= (b & 0x7F) << shift
        if b < 0x80:
            return result, i
        shift += 7


def _fields(buf):
    i = 0
    while i < len(buf):
        key, i = _varint(buf, i)
        number, wire = key >> 3, key & 7
        if wire == 0:
            value, i = _varint(buf, i)
            yield number, value
        elif wire == 2:
            length, i = _varint(buf, i)
            yield number, buf[i:i + length]
            i += length
        elif wire == 5:
            yield number, buf[i:i + 4]
            i += 4
        elif wire == 1:
            yield number, buf[i:i + 8]
            i += 8
        else:
            raise ValueError(f"対応していない wire type {wire}")


def _packed(buf):
    out, i = [], 0
    while i < len(buf):
        value, i = _varint(buf, i)
        out.append(value)
    return out


def _value(buf):
    for number, value in _fields(buf):
        if number == 1:
            return value.decode("utf-8")
        if number == 2:
            return struct.unpack("<f", value)[0]
        if number == 3:
            return struct.unpack("<d", value)[0]
        if number in (4, 5):
            return value
        if number == 6:
            return (value >> 1) ^ -(value & 1)
        if number == 7:
            return bool(value)
    return None


def railway_segments(data, z, tx, ty):
    """ベクトルタイルの railway の層の線を、(経度緯度の2点, railState, rtCode の上5桁) の区間の並びにする"""
    segments = []
    for number, layer in _fields(data):
        if number != 3:
            continue
        name, features, keys, values, extent = None, [], [], [], 4096
        for n, w in _fields(layer):
            if n == 1:
                name = w.decode("utf-8")
            elif n == 2:
                features.append(w)
            elif n == 3:
                keys.append(w.decode("utf-8"))
            elif n == 4:
                values.append(_value(w))
            elif n == 5:
                extent = w
        if name != "railway":
            continue
        for feature in features:
            tags, geometry = [], []
            for n, w in _fields(feature):
                if n == 2:
                    tags = _packed(w)
                elif n == 4:
                    geometry = _packed(w)
            props = {keys[tags[i]]: values[tags[i + 1]] for i in range(0, len(tags) - 1, 2)}
            state = props.get("railState")
            code = str(props.get("rtCode", ""))[:5]
            if not isinstance(state, int):
                continue
            x = y = 0
            i = 0
            line = []
            while i < len(geometry):
                command, count = geometry[i] & 7, geometry[i] >> 3
                i += 1
                if command in (1, 2):
                    for _ in range(count):
                        dx, dy = geometry[i], geometry[i + 1]
                        i += 2
                        x += (dx >> 1) ^ -(dx & 1)
                        y += (dy >> 1) ^ -(dy & 1)
                        point = lonlat_of(tx + x / extent, ty + y / extent, z)
                        if command == 1:
                            line = [point]
                        else:
                            segments.append((line[-1], point, state, code))
                            line.append(point)
    return segments


class RailStateReader:
    def __init__(self):
        self.tiles = {}

    def segments(self, tx, ty):
        key = (tx, ty)
        if key not in self.tiles:
            data = fetch(f"https://cyberjapandata.gsi.go.jp/xyz/experimental_bvmap/{VT_ZOOM}/{tx}/{ty}.pbf",
                         f"bvmap_{VT_ZOOM}_{tx}_{ty}.pbf")
            self.tiles[key] = railway_segments(data, VT_ZOOM, tx, ty) if data else []
        return self.tiles[key]

    def kind(self, lat, lon, bearing, codes):
        """その点の区間の種類("g" 地上、"e" 高架、"u" 地下、"?" 不明)。codes は優先する rtCode の上5桁の並び。"""
        fx, fy = tile_of(lat, lon, VT_ZOOM)
        tx, ty = int(fx), int(fy)
        candidates = list(self.segments(tx, ty))
        # タイルの端の近くでは、となりのタイルの線も見る
        margin = 0.02
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                if (dx, dy) == (0, 0):
                    continue
                near_x = (dx == -1 and fx - tx < margin) or (dx == 1 and tx + 1 - fx < margin) or dx == 0
                near_y = (dy == -1 and fy - ty < margin) or (dy == 1 and ty + 1 - fy < margin) or dy == 0
                if near_x and near_y:
                    candidates += self.segments(tx + dx, ty + dy)
        best = None
        for rank, code in enumerate(codes):
            for a, b, state, segment_code in candidates:
                if segment_code != code:
                    continue
                distance, segment_bearing = _segment_distance((lon, lat), a, b)
                if distance > MATCH_METERS:
                    continue
                difference = abs((segment_bearing - bearing + 90) % 180 - 90)
                if difference > MATCH_DEGREES:
                    continue
                if best is None or (rank, distance) < (best[0], best[1]):
                    best = (rank, distance, state)
            if best is not None:
                break
        if best is None:
            return "?"
        return KIND_CODES.get(best[2], "?")


def _local(point, origin):
    lat = math.radians((point[1] + origin[1]) / 2)
    return ((point[0] - origin[0]) * math.pi / 180 * EARTH * math.cos(lat), (point[1] - origin[1]) * math.pi / 180 * EARTH)


def _segment_distance(p, a, b):
    ax, ay = _local(a, p)
    bx, by = _local(b, p)
    dx, dy = bx - ax, by - ay
    length = dx * dx + dy * dy
    t = 0 if length == 0 else max(0.0, min(1.0, -(ax * dx + ay * dy) / length))
    return math.hypot(ax + dx * t, ay + dy * t), math.degrees(math.atan2(dx, dy)) % 360


# MARK: - 線路の形への付与

def preferred_codes(railway_id):
    """路線ごとに、ベクトルタイルの種別のコード(rtCode の上5桁)の優先順。JR(40201)は使わない。"""
    if railway_id.endswith(".Arakawa"):
        return ["40204", "40202"]
    operator = railway_id.split(":", 1)[-1].split(".")[0]
    if operator in ("TokyoMetro", "YokohamaMunicipal") or (operator == "Toei" and not railway_id.endswith(".NipporiToneri")):
        return ["40203", "40202"]
    return ["40202", "40203", "40204"]


def smooth(kinds, shortest=2):
    """前後と違う種類が shortest 点未満だけ続く所(交差する線を拾ったなど)を、前の種類にそろえる"""
    result = list(kinds)
    i = 0
    while i < len(result):
        j = i
        while j < len(result) and result[j] == result[i]:
            j += 1
        if 0 < i and j < len(result) and j - i < shortest and result[i - 1] == result[j]:
            for k in range(i, j):
                result[k] = result[i - 1]
        i = j
    return result


def runs(kinds):
    """[[始まりの番号, 種類], ...]"""
    out = []
    for index, kind in enumerate(kinds):
        if not out or out[-1][1] != kind:
            out.append([index, kind])
    return out


def build_profile(railway_id, points, dem, states):
    """points は [[緯度, 経度], ...]。STEP_METERS ごとの地面の標高(0.1m 単位の整数、なければ None)と、区間の種類の連なり。"""
    cumulative = [0.0]
    for a, b in zip(points, points[1:]):
        cumulative.append(cumulative[-1] + math.hypot(*_local((b[1], b[0]), (a[1], a[0]))))
    total = cumulative[-1]
    count = int(total // STEP_METERS) + 1
    codes = preferred_codes(railway_id)
    ground, kinds = [], []
    segment = 0
    for k in range(count):
        along = min(k * STEP_METERS, total)
        while segment < len(points) - 2 and cumulative[segment + 1] < along:
            segment += 1
        a, b = points[segment], points[segment + 1]
        span = cumulative[segment + 1] - cumulative[segment]
        t = 0 if span == 0 else (along - cumulative[segment]) / span
        lat = a[0] + (b[0] - a[0]) * t
        lon = a[1] + (b[1] - a[1]) * t
        bearing = math.degrees(math.atan2(*_local((b[1], b[0]), (a[1], a[0])))) % 360
        value = dem.elevation(lat, lon)
        ground.append(None if value is None else int(round(value * 10)))
        kinds.append(states.kind(lat, lon, bearing, codes))
    kinds = smooth(kinds)
    summary = {kind: kinds.count(kind) for kind in "geu?"}
    return {"step": STEP_METERS, "ground": ground, "kinds": runs(kinds)}, summary
