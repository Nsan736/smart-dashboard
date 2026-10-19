// パーセント・割引・消費税(JavaScript 版)。2進数の誤差で1円ずれないよう、小数第3位で丸めてから円未満を処理する。
var values = { price: '1980', off: 20, tax: '10%', a: '30', b: '120' };

var PercentCalc = {
  settled: function (v) { return Math.round(v * 1000) / 1000; },
  // ◯%引き(円未満は切り捨て)
  discounted: function (price, off) { return Math.floor(PercentCalc.settled(price * (100 - off) / 100)); },
  // 税抜 → 税込(切り捨て)
  withTax: function (price, rate) { return Math.floor(PercentCalc.settled(price * (100 + rate) / 100)); },
  // 税込 → 税抜(切り上げ。税込に戻したときに元を下回らないように)
  withoutTax: function (price, rate) { return Math.ceil(PercentCalc.settled(price * 100 / (100 + rate))); },
  ratio: function (a, b) { return b === 0 ? null : a / b * 100; }
};

function onInput(name, value) { values[name] = value; K.invalidate(); }
function onTouch(e) { K.touch(e); }
function frame() { K.frame(draw); }

function draw(w, h, th) {
  var pad = 12, cw = w - pad * 2, y = 12, x = pad + 14, iw = cw - 28;
  var price = K.parseNumber(values.price), off = Math.round(values.off), rate = values.tax === '8%' ? 8 : 10;
  K.card(pad, y, cw, 190, th);
  y += 12;
  if (price === null) {
    y += K.paragraph('値段を入れてください', x, y, iw, 15, th.danger) + 10;
  } else {
    var d = PercentCalc.discounted(price, off);
    y += K.valueRow(off + '%引き', K.group(d) + '円', x, y, iw, th, { size: 28, color: th.accent }) + 6;
    y += K.valueRow('引かれる額', K.group(price - d) + '円', x, y, iw, th, { size: 16 });
    y += K.valueRow('割引後の税込(' + rate + '%)', K.group(PercentCalc.withTax(d, rate)) + '円', x, y, iw, th, { size: 16 });
    y += K.valueRow('値段の税込(' + rate + '%)', K.group(PercentCalc.withTax(price, rate)) + '円', x, y, iw, th, { size: 16 });
    y += K.valueRow('値段を税込として税抜', K.group(PercentCalc.withoutTax(price, rate)) + '円', x, y, iw, th, { size: 16 });
  }
  y = Math.max(y, 214);
  K.card(pad, y, cw, 70, th);
  var a = K.parseNumber(values.a), b = K.parseNumber(values.b), r = a === null || b === null ? null : PercentCalc.ratio(a, b);
  K.valueRow(K.number(a === null ? NaN : a) + ' は ' + K.number(b === null ? NaN : b) + ' の', r === null ? '—' : K.number(r, 5) + '%', x, y + 20, iw, th, { size: 24 });
  return y + 90;
}
