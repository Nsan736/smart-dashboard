// 進数変換(JavaScript 版)。2〜36進。BigInt で、長い数(64桁まで)も誤差なく変換する。_ と空白は無視する。
var values = { value: 'FF', base: '16', custom: 36 };

var BaseConvert = {
  digits: '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ',
  // 文字 → BigInt。読めなければ null
  parse: function (text, base) {
    var s = K.half(text).trim().toUpperCase().replace(/[_\s]/g, '');
    var neg = false;
    if (s[0] === '-') { neg = true; s = s.slice(1); }
    if (base === 16 && s.indexOf('0X') === 0) s = s.slice(2);
    else if (base === 2 && s.indexOf('0B') === 0) s = s.slice(2);
    else if (base === 8 && s.indexOf('0O') === 0) s = s.slice(2);
    if (s === '' || s.length > 64) return null;
    var b = BigInt(base), v = BigInt(0);
    for (var i = 0; i < s.length; i++) {
      var d = BaseConvert.digits.indexOf(s[i]);
      if (d < 0 || d >= base) return null;
      v = v * b + BigInt(d);
    }
    return neg ? -v : v;
  },
  format: function (v, base) {
    if (v === BigInt(0)) return '0';
    var neg = v < BigInt(0), b = BigInt(base), out = '';
    if (neg) v = -v;
    while (v > BigInt(0)) { out = BaseConvert.digits[Number(v % b)] + out; v = v / b; }
    return (neg ? '-' : '') + out;
  },
  // 4桁ずつ区切る(2進と16進の読みやすさ)
  grouped: function (text, size) {
    var neg = text[0] === '-', s = neg ? text.slice(1) : text, out = '';
    while (s.length > size) { out = ' ' + s.slice(-size) + out; s = s.slice(0, -size); }
    return (neg ? '-' : '') + s + out;
  }
};

function onInput(name, value) { values[name] = value; K.invalidate(); }
function onTouch(e) { K.touch(e); }
function frame() { K.frame(draw); }

function draw(w, h, th) {
  var pad = 12, cw = w - pad * 2, y = 12, x = pad + 14, iw = cw - 28;
  var base = values.base === 'その他' ? Math.round(values.custom) : +values.base;
  var v = BaseConvert.parse(values.value, base);
  if (v === null) { K.paragraph(base + '進数として読めませんでした(使える文字は ' + BaseConvert.digits.slice(0, base) + ')', x, y + 10, iw, 15, th.danger); return 90; }
  var rows = [['2進', BaseConvert.grouped(BaseConvert.format(v, 2), 4)], ['8進', BaseConvert.format(v, 8)], ['10進', BaseConvert.grouped(BaseConvert.format(v, 10), 3).replace(/ /g, ',')],
              ['16進', BaseConvert.grouped(BaseConvert.format(v, 16), 4)]];
  if ([2, 8, 10, 16].indexOf(base) < 0) rows.push([base + '進', BaseConvert.format(v, base)]);
  K.card(pad, y, cw, 20 + rows.length * 58, th);
  y += 10;
  rows.forEach(function (r) {
    ctx.fillStyle = th.sub;
    ctx.font = K.font(13, false);
    ctx.textAlign = 'left';
    ctx.textBaseline = 'top';
    ctx.fillText(r[0], x, y);
    ctx.fillStyle = th.fg;
    K.fitText(r[1], x, y + 18, iw, 20, true);
    y += 58;
  });
  return y + 30;
}
