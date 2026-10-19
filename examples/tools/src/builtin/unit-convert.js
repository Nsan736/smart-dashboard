// 単位換算(JavaScript 版)。入れた値を、同じ種類のすべての単位で出す。表の倍率は基準の単位(m、kg、m²、L、m/s)へのもの。
var kind = '長さ';
var values = { value: '1', from: '' };

var Units = {
  kinds: {
    '長さ': [['mm', 0.001], ['cm', 0.01], ['m', 1], ['km', 1000], ['インチ', 0.0254], ['フィート', 0.3048], ['ヤード', 0.9144], ['マイル', 1609.344], ['尺', 10 / 33]],
    '重さ': [['g', 0.001], ['kg', 1], ['t', 1000], ['オンス', 0.028349523125], ['ポンド', 0.45359237], ['匁', 0.00375]],
    '温度': [['℃', 1], ['℉', 1], ['K', 1]],
    '面積': [['cm²', 0.0001], ['m²', 1], ['km²', 1000000], ['a', 100], ['ha', 10000], ['坪', 400 / 121], ['畳', 1.62], ['エーカー', 4046.8564224]],
    '体積': [['mL', 0.001], ['L', 1], ['m³', 1000], ['合', 0.18039], ['升', 1.8039], ['カップ(日本)', 0.2], ['ガロン(米)', 3.785411784]],
    '速度': [['m/s', 1], ['km/h', 1 / 3.6], ['mph', 0.44704], ['ノット', 1852 / 3600]]
  },
  index: function (k, name) {
    var list = Units.kinds[k];
    for (var i = 0; i < list.length; i++) if (list[i][0] === name) return i;
    return -1;
  },
  convert: function (value, k, from, to) {
    var list = Units.kinds[k];
    if (!list || !list[from] || !list[to]) return null;
    if (k === '温度') {
      var c = from === 1 ? (value - 32) * 5 / 9 : (from === 2 ? value - 273.15 : value);
      return to === 1 ? c * 9 / 5 + 32 : (to === 2 ? c + 273.15 : c);
    }
    return value * list[from][1] / list[to][1];
  }
};

function names(k) { return Units.kinds[k].map(function (u) { return u[0]; }); }

function showUnits() {
  var list = names(kind);
  if (list.indexOf(values.from) < 0) values.from = kind === '長さ' ? 'm' : (kind === '重さ' ? 'kg' : list[kind === '面積' || kind === '体積' ? 1 : 0]);
  ui.choice('from', { label: '入れた値の単位', options: list, value: values.from });
}

function setup() { showUnits(); }
function onInput(name, value) {
  if (name === 'kind') { if (value !== kind) { kind = value; showUnits(); } }
  else values[name] = value;
  K.invalidate();
}
function onTouch(e) { K.touch(e); }
function frame() { K.frame(draw); }

function draw(w, h, th) {
  var pad = 12, cw = w - pad * 2, y = 12, x = pad + 14, iw = cw - 28;
  var v = K.parseNumber(values.value), from = Units.index(kind, values.from), list = Units.kinds[kind];
  if (v === null || from < 0) { K.paragraph('値を入れてください', x, y + 10, iw, 15, th.danger); return 80; }
  K.card(pad, y, cw, 20 + list.length * 34, th);
  y += 10;
  for (var i = 0; i < list.length; i++) {
    var r = Units.convert(v, kind, from, i);
    y += K.valueRow(list[i][0], K.number(r), x, y, iw, th, { size: 19, color: i === from ? th.accent : th.fg }) + 2;
  }
  return y + 30;
}
