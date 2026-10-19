// パスワード・乱数(JavaScript 版)。暗号に使える乱数(random.secure)で作る。作ったものは保存しない。結果はコピーできる。
var mode = 'パスワード';
var opts = { length: 16, lower: true, upper: true, digits: true, symbols: false, noAmbiguous: true, min: '1', max: '100', count: 1, unique: true };
var results = [];
var message = '';

var Password = {
  sets: { lower: 'abcdefghijklmnopqrstuvwxyz', upper: 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', digits: '0123456789', symbols: '!#$%&*+-=?@_' },
  AMBIGUOUS: '0Oo1lI',
  // 選んだ文字の種類の一覧(紛らわしい文字を除く)
  alphabets: function (o) {
    var out = [];
    ['lower', 'upper', 'digits', 'symbols'].forEach(function (k) {
      if (!o[k]) return;
      var s = Password.sets[k];
      if (o.noAmbiguous) s = s.split('').filter(function (c) { return Password.AMBIGUOUS.indexOf(c) < 0; }).join('');
      out.push(s);
    });
    return out;
  },
  // 長さ length(1〜128)。選んだ種類が1文字ずつは入るようにする(長さが種類の数以上のとき)。rndInt(a, b) は a〜b の整数
  make: function (o, rndInt) {
    var sets = Password.alphabets(o), length = Math.max(1, Math.min(128, Math.round(o.length)));
    if (!sets.length) return null;
    var all = sets.join(''), chars = [];
    if (length >= sets.length) sets.forEach(function (s) { chars.push(s[rndInt(0, s.length - 1)]); });
    while (chars.length < length) chars.push(all[rndInt(0, all.length - 1)]);
    for (var i = chars.length - 1; i > 0; i--) { var j = rndInt(0, i), t = chars[i]; chars[i] = chars[j]; chars[j] = t; }
    return chars.join('');
  },
  // 1文字あたりの強さ(ビット)の目安
  bits: function (o) {
    var n = Password.alphabets(o).join('').length;
    return n ? Math.round(Math.log(n) / Math.LN2 * Math.round(o.length)) : 0;
  },
  // min〜max の整数を count 個。unique なら重ならない(範囲が足りなければ null)
  numbers: function (min, max, count, unique, rndInt) {
    if (min > max) { var t = min; min = max; max = t; }
    if (unique && max - min + 1 < count) return null;
    var out = [], seen = {};
    while (out.length < count) {
      var v = rndInt(min, max);
      if (unique && seen[v]) continue;
      seen[v] = true;
      out.push(v);
    }
    return out;
  }
};

function rndInt(a, b) { return random.secureInt(a, b); }

function showControls() {
  ['length', 'lower', 'upper', 'digits', 'symbols', 'noAmbiguous', 'min', 'max', 'count', 'unique'].forEach(function (id) { ui.remove(id); });
  if (mode === 'パスワード') {
    ui.slider('length', { label: '長さ', min: 4, max: 64, step: 1, value: opts.length });
    ui.toggle('lower', { label: '英小文字', value: opts.lower });
    ui.toggle('upper', { label: '英大文字', value: opts.upper });
    ui.toggle('digits', { label: '数字', value: opts.digits });
    ui.toggle('symbols', { label: '記号(' + Password.sets.symbols + ')', value: opts.symbols });
    ui.toggle('noAmbiguous', { label: '紛らわしい文字を除く(0 O o 1 l I)', value: opts.noAmbiguous });
  } else {
    ui.text('min', { label: '最小', value: opts.min, keyboard: 'number' });
    ui.text('max', { label: '最大', value: opts.max, keyboard: 'number' });
    ui.slider('count', { label: '個数', min: 1, max: 20, step: 1, value: opts.count });
    ui.toggle('unique', { label: '重ならないようにする', value: opts.unique });
  }
}

function generate() {
  message = '';
  if (mode === 'パスワード') {
    results = [];
    for (var i = 0; i < 5; i++) { var p = Password.make(opts, rndInt); if (p) results.push(p); }
    if (!results.length) message = '文字の種類を1つ以上選んでください';
  } else {
    var min = K.parseNumber(opts.min), max = K.parseNumber(opts.max);
    if (min === null || max === null || Math.abs(min) > 1e12 || Math.abs(max) > 1e12) { message = '最小と最大を整数で入れてください'; results = []; }
    else {
      var list = Password.numbers(Math.round(min), Math.round(max), Math.round(opts.count), opts.unique, rndInt);
      if (!list) { message = '範囲の数が、個数より少ないです'; results = []; } else results = [list.join('、')];
    }
  }
  K.invalidate();
}

function setup() { showControls(); generate(); }

function onInput(name, value) {
  if (name === 'mode') { if (value !== mode) { mode = value; showControls(); generate(); } return; }
  if (name === 'make') { generate(); sound.play('click'); return; }
  opts[name] = value;
  if (mode === 'パスワード') generate();
  K.invalidate();
}

function onTouch(e) {
  var b = K.hit(K.touch(e));
  if (b && b.id === 'copy') { clipboard.copy(results[b.data]); haptic('light'); }
}
function frame() { K.frame(draw); }

function draw(w, h, th) {
  var pad = 12, cw = w - pad * 2, y = 12;
  if (message) { y += K.paragraph(message, pad, y, cw, 15, th.danger) + 10; }
  if (mode === 'パスワード' && !message) {
    ctx.fillStyle = th.sub;
    ctx.textAlign = 'left';
    ctx.textBaseline = 'top';
    K.fitText('強さの目安 約' + Password.bits(opts) + 'ビット(タップでコピー)', pad, y, cw, 13, false);
    y += 22;
  }
  results.forEach(function (r, i) {
    ctx.font = K.font(18, true);
    var lines = K.wrap(r, cw - 24), boxH = 16 + lines.length * 26;
    K.card(pad, y, cw, boxH, th);
    ctx.fillStyle = th.fg;
    ctx.textAlign = 'left';
    ctx.textBaseline = 'top';
    ctx.font = K.font(18, true);
    for (var j = 0; j < lines.length; j++) ctx.fillText(lines[j], pad + 12, y + 9 + j * 26);
    K.area('copy', pad, y, cw, boxH, i);
    y += boxH + 8;
  });
  return y + 20;
}
