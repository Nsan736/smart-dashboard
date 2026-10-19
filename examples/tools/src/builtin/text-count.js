// 文字数カウント(JavaScript 版)。文字数(改行を含む・含まない)、空白を除く、全角を2とした半角換算、行数、原稿用紙(400字)、UTF-8 のバイト数。
var text = '';

var TextCount = {
  // 文字(サロゲートペア・結合文字をまとめた見た目の1文字に近い数。絵文字の結合は1文字として数えない場合がある)
  chars: function (s) { return Array.from(s).filter(function (c) { return !/[̀-゙゚ͯ︎️‍]/.test(c); }).length; },
  count: function (s) {
    var noNewline = s.replace(/\r?\n/g, '');
    var units = 0;
    Array.from(noNewline).forEach(function (c) {
      var code = c.codePointAt(0);
      units += (code <= 0x7e || (code >= 0xff61 && code <= 0xff9f)) ? 1 : 2;
    });
    var bytes = 0;
    Array.from(s).forEach(function (c) {
      var code = c.codePointAt(0);
      bytes += code < 0x80 ? 1 : code < 0x800 ? 2 : code < 0x10000 ? 3 : 4;
    });
    return {
      all: TextCount.chars(s),
      noNewline: TextCount.chars(noNewline),
      noSpace: TextCount.chars(s.replace(/[\s　]/g, '')),
      halfUnits: units,
      lines: s === '' ? 0 : s.split(/\r?\n/).length,
      bytes: bytes
    };
  }
};

function setup() {
  var saved = storage.get('text');
  text = typeof saved === 'string' ? saved : '';
  ui.text('text', { label: '文章', value: text, multiline: true, placeholder: 'ここに文章を入れる(5000文字まで)' });
  ui.button('clear', '消す');
}
function onInput(name, value) {
  if (name === 'text') text = value;
  else if (name === 'clear') { text = ''; ui.set('text', ''); }
  storage.set('text', text);
  K.invalidate();
}
function onTouch(e) { K.touch(e); }
function frame() { K.frame(draw); }

function draw(w, h, th) {
  var pad = 12, cw = w - pad * 2, y = 12, x = pad + 14, iw = cw - 28;
  var c = TextCount.count(text);
  K.card(pad, y, cw, 262, th);
  y += 10;
  y += K.valueRow('文字数', K.group(c.all), x, y, iw, th, { size: 34, color: th.accent }) + 12;
  y += K.valueRow('改行を除く', K.group(c.noNewline), x, y, iw, th);
  y += K.valueRow('空白・改行を除く', K.group(c.noSpace), x, y, iw, th);
  y += K.valueRow('半角換算(全角=2)', K.group(c.halfUnits), x, y, iw, th);
  y += K.valueRow('行数', K.group(c.lines), x, y, iw, th);
  y += K.valueRow('原稿用紙(400字)', (c.noNewline / 400).toFixed(1) + '枚', x, y, iw, th);
  y += K.valueRow('UTF-8', K.group(c.bytes) + 'バイト', x, y, iw, th);
  return y + 30;
}
