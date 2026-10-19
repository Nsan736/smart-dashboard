// 文字の変換(JavaScript 版)。ひらがな・カタカナ、全角・半角(英数字と記号、カタカナ)。結果はコピーできる。
var text = '';
var mode = 'ひらがな→カタカナ';
var alnum = true;
var kana = true;
var message = '';

var Kana = {
  HALF: '｡｢｣､･ｦｧｨｩｪｫｬｭｮｯｰｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿﾀﾁﾂﾃﾄﾅﾆﾇﾈﾉﾊﾋﾌﾍﾎﾏﾐﾑﾒﾓﾔﾕﾖﾗﾘﾙﾚﾛﾜﾝﾞﾟ',
  FULL: '。「」、・ヲァィゥェォャュョッーアイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワン゛゜',
  toKatakana: function (s) {
    return s.replace(/[ぁ-ゖゝゞ]/g, function (c) { return String.fromCharCode(c.charCodeAt(0) + 0x60); });
  },
  toHiragana: function (s) {
    return s.replace(/[ァ-ヶヽヾ]/g, function (c) { return String.fromCharCode(c.charCodeAt(0) - 0x60); });
  },
  // 全角 → 半角
  toHalf: function (s, o) {
    o = o || { alnum: true, kana: true };
    var out = '';
    if (o.kana) s = s.normalize('NFD');
    for (var i = 0; i < s.length; i++) {
      var c = s[i], code = c.charCodeAt(0);
      if (o.alnum && code >= 0xff01 && code <= 0xff5e) out += String.fromCharCode(code - 0xfee0);
      else if (o.alnum && code === 0x3000) out += ' ';
      else if (o.kana && (code === 0x3099 || code === 0x309a) && Kana.HALF.indexOf(out.slice(-1)) >= 0) out += code === 0x3099 ? 'ﾞ' : 'ﾟ';
      else if (o.kana && Kana.FULL.indexOf(c) >= 0) out += Kana.HALF[Kana.FULL.indexOf(c)];
      else out += c;
    }
    return o.kana ? out.normalize('NFC') : out;
  },
  // 半角 → 全角(濁点・半濁点は前の文字とまとめる)
  toFull: function (s, o) {
    o = o || { alnum: true, kana: true };
    var out = '';
    for (var i = 0; i < s.length; i++) {
      var c = s[i], code = c.charCodeAt(0), k = Kana.HALF.indexOf(c);
      if (o.alnum && code >= 0x21 && code <= 0x7e) out += String.fromCharCode(code + 0xfee0);
      else if (o.alnum && c === ' ') out += '　';
      else if (o.kana && (c === 'ﾞ' || c === 'ﾟ')) {
        var mark = c === 'ﾞ' ? '゙' : '゚', prev = out.slice(-1);
        var joined = (prev + mark).normalize('NFC');
        out = joined.length === 1 ? out.slice(0, -1) + joined : out + (c === 'ﾞ' ? '゛' : '゜');
      }
      else if (o.kana && k >= 0) out += Kana.FULL[k];
      else out += c;
    }
    return out;
  },
  convert: function (s, mode, o) {
    if (mode === 'ひらがな→カタカナ') return Kana.toKatakana(s);
    if (mode === 'カタカナ→ひらがな') return Kana.toHiragana(Kana.toFull(s, { alnum: false, kana: true }));
    if (mode === '全角→半角') return Kana.toHalf(s, o);
    return Kana.toFull(s, o);
  }
};

function setup() {
  var saved = storage.get('kana') || {};
  text = typeof saved.text === 'string' ? saved.text : '';
  ui.text('text', { label: '変換する文字', value: text, multiline: true });
  ui.button('copy', '結果をコピー');
}
function onInput(name, value) {
  message = '';
  if (name === 'text') { text = value; storage.set('kana', { text: text }); }
  else if (name === 'mode') mode = value;
  else if (name === 'alnum') alnum = value;
  else if (name === 'kana') kana = value;
  else if (name === 'copy') {
    var result = Kana.convert(text, mode, { alnum: alnum, kana: kana });
    if (result.length > 10000) message = '長すぎてコピーできません';
    else clipboard.copy(result);
  }
  K.invalidate();
}
function onTouch(e) { K.touch(e); }
function frame() { K.frame(draw); }

function draw(w, h, th) {
  var pad = 12, cw = w - pad * 2, y = 12;
  var result = Kana.convert(text, mode, { alnum: alnum, kana: kana });
  ctx.fillStyle = th.sub;
  ctx.textAlign = 'left';
  ctx.textBaseline = 'top';
  K.fitText(mode + (mode.indexOf('角') >= 0 ? '(' + [alnum ? '英数字・記号' : '', kana ? 'カタカナ' : ''].filter(Boolean).join('・') + ')' : ''), pad, y, cw, 13, false);
  y += 22;
  if (message) y += K.paragraph(message, pad, y, cw, 13, th.danger) + 6;
  ctx.font = K.font(17, false);
  // 長い結果は、表示を先頭の2000文字までにする(コピーは全部)
  var shown = result.length > 2000 ? result.slice(0, 2000) + '…(表示は2000文字まで)' : result;
  var lines = K.wrap(result === '' ? '(下の欄に文字を入れてください)' : shown, cw - 24);
  var boxH = 20 + lines.length * 24;
  K.card(pad, y, cw, boxH, th);
  ctx.fillStyle = result === '' ? th.sub : th.fg;
  ctx.textBaseline = 'top';
  ctx.font = K.font(17, false);
  for (var i = 0; i < lines.length; i++) ctx.fillText(lines[i], pad + 12, y + 10 + i * 24);
  return y + boxH + 20;
}
