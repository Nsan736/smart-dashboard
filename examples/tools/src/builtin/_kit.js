// 組み込みのツールの JavaScript 版で共通に使う部品(各ツールの先頭に付けてから JSON にする)。
// 読み込んだ時点ではアプリの関数(ctx・ui・storage など)を呼ばない。テストは計算の関数だけを、そのまま動かして確かめる。
var K = (function () {
  'use strict';
  var buttons = [];
  var last = { w: -1, h: -1, dark: null };
  var touchStart = null;
  var api = {
    dirty: true,
    scrollY: 0,
    contentHeight: 0,
    viewHeight: 0
  };

  // ---- 色(ダークモードに合わせる) ----
  api.theme = function (dark) {
    return dark ? {
      bg: '#000000', card: '#1c1c1e', card2: '#2c2c2e', fg: '#f2f2f7', sub: '#98989f', line: '#3a3a3c',
      accent: '#0a84ff', accentFg: '#ffffff', danger: '#ff453a', ok: '#30d158', warn: '#ffd60a'
    } : {
      bg: '#f2f2f7', card: '#ffffff', card2: '#e5e5ea', fg: '#1c1c1e', sub: '#6c6c70', line: '#d1d1d6',
      accent: '#007aff', accentFg: '#ffffff', danger: '#ff3b30', ok: '#34c759', warn: '#ff9500'
    };
  };
  api.palette = ['#e63946', '#f4a261', '#e9c46a', '#2a9d8f', '#457b9d', '#9b5de5', '#f15bb5', '#00bbf9', '#8ac926', '#ff7f51', '#6a4c93', '#43aa8b'];

  // ---- 描き直し(変わったときだけ描く) ----
  api.invalidate = function () { api.dirty = true; };
  // draw(w, h, theme) は描いた内容の高さを返す(画面より高ければ縦にスクロールできる)
  api.frame = function (draw) {
    var w = screen.width, h = screen.height, dark = screen.dark;
    if (w !== last.w || h !== last.h || dark !== last.dark) { api.dirty = true; last.w = w; last.h = h; last.dark = dark; }
    if (!api.dirty || w <= 0 || h <= 0) return;
    api.dirty = false;
    buttons = [];
    var theme = api.theme(dark);
    api.viewHeight = h;
    ctx.fillStyle = theme.bg;
    ctx.fillRect(0, 0, w, h);
    ctx.save();
    ctx.translate(0, -api.scrollY);
    var height = draw(w, h, theme) || h;
    ctx.restore();
    api.contentHeight = height;
    var maxScroll = Math.max(0, height - h);
    if (api.scrollY > maxScroll) { api.scrollY = maxScroll; api.dirty = true; }
    if (maxScroll > 0) {
      var barH = Math.max(30, h * h / height), barY = (h - barH) * (api.scrollY / maxScroll);
      ctx.fillStyle = theme.sub;
      ctx.globalAlpha = 0.5;
      ctx.fillRect(w - 4, barY, 3, barH);
      ctx.globalAlpha = 1;
    }
  };

  // ---- 触れる: 指を動かしたらスクロール、動かさずに離したらタップ(内容の座標で返す) ----
  api.touch = function (e) {
    if (e.type === 'down') { touchStart = { x: e.x, y: e.y, scroll: api.scrollY, moved: false }; return null; }
    if (!touchStart) return null;
    if (e.type === 'move') {
      if (Math.abs(e.y - touchStart.y) > 8 || Math.abs(e.x - touchStart.x) > 8) touchStart.moved = true;
      if (touchStart.moved) {
        var maxScroll = Math.max(0, api.contentHeight - api.viewHeight);
        var next = Math.min(maxScroll, Math.max(0, touchStart.scroll - (e.y - touchStart.y)));
        if (next !== api.scrollY) { api.scrollY = next; api.dirty = true; }
      }
      return null;
    }
    var start = touchStart;
    touchStart = null;
    if (e.type === 'up' && !start.moved) return { x: e.x, y: e.y + api.scrollY };
    return null;
  };
  api.scrollTo = function (y) { api.scrollY = Math.max(0, y); api.dirty = true; };

  // ---- キャンバスのボタン ----
  api.button = function (id, x, y, w, h, label, o) {
    o = o || {};
    var theme = api.theme(screen.dark);
    ctx.fillStyle = o.fill || (o.primary ? theme.accent : theme.card2);
    api.roundRect(x, y, w, h, o.radius === undefined ? 10 : o.radius);
    ctx.fill();
    ctx.fillStyle = o.color || (o.primary ? theme.accentFg : theme.fg);
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    api.fitText(label, x + w / 2, y + h / 2, w - 8, o.size || 16, o.bold !== false);
    buttons.push({ id: id, x: x, y: y, w: w, h: h, data: o.data });
  };
  // タップした所のボタン(内容の座標)。なければ null
  api.hit = function (p) {
    if (!p) return null;
    for (var i = buttons.length - 1; i >= 0; i--) {
      var b = buttons[i];
      if (p.x >= b.x && p.x <= b.x + b.w && p.y >= b.y && p.y <= b.y + b.h) return b;
    }
    return null;
  };
  // 描かずに、タップできる範囲だけを足す
  api.area = function (id, x, y, w, h, data) { buttons.push({ id: id, x: x, y: y, w: w, h: h, data: data }); };

  api.roundRect = function (x, y, w, h, r) {
    r = Math.max(0, Math.min(r, w / 2, h / 2));
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.lineTo(x + w - r, y);
    ctx.arc(x + w - r, y + r, r, -Math.PI / 2, 0);
    ctx.lineTo(x + w, y + h - r);
    ctx.arc(x + w - r, y + h - r, r, 0, Math.PI / 2);
    ctx.lineTo(x + r, y + h);
    ctx.arc(x + r, y + h - r, r, Math.PI / 2, Math.PI);
    ctx.lineTo(x, y + r);
    ctx.arc(x + r, y + r, r, Math.PI, Math.PI * 1.5);
    ctx.closePath();
  };
  api.card = function (x, y, w, h, theme) {
    ctx.fillStyle = theme.card;
    api.roundRect(x, y, w, h, 12);
    ctx.fill();
  };

  // ---- 文字 ----
  api.font = function (size, bold) { return (bold ? 'bold ' : '') + Math.round(size) + 'px sans-serif'; };
  // 幅に収まるように、文字を小さくして描く(最小は size の半分)
  api.fitText = function (text, x, y, maxWidth, size, bold) {
    text = String(text);
    var s = size;
    ctx.font = api.font(s, bold);
    var width = ctx.measureText(text).width;
    if (width > maxWidth && maxWidth > 0) {
      s = Math.max(size * 0.5, size * maxWidth / width);
      ctx.font = api.font(s, bold);
    }
    ctx.fillText(text, x, y);
    return s;
  };
  // 幅で折り返した行の一覧(今の ctx.font で測る)
  api.wrap = function (text, maxWidth) {
    var out = [];
    String(text).split('\n').forEach(function (para) {
      if (para === '') { out.push(''); return; }
      var line = '';
      for (var i = 0; i < para.length; i++) {
        var next = line + para[i];
        if (line !== '' && ctx.measureText(next).width > maxWidth) { out.push(line); line = para[i]; } else { line = next; }
      }
      out.push(line);
    });
    return out;
  };
  // 折り返して描き、描いた高さを返す
  api.paragraph = function (text, x, y, maxWidth, size, color, bold) {
    ctx.font = api.font(size, bold);
    ctx.fillStyle = color;
    ctx.textAlign = 'left';
    ctx.textBaseline = 'top';
    var lines = api.wrap(text, maxWidth), lh = Math.round(size * 1.35);
    for (var i = 0; i < lines.length; i++) ctx.fillText(lines[i], x, y + i * lh);
    return lines.length * lh;
  };
  // 見出しと大きな値の行
  api.valueRow = function (label, value, x, y, w, theme, o) {
    o = o || {};
    ctx.textBaseline = 'middle';
    ctx.textAlign = 'left';
    ctx.fillStyle = theme.sub;
    api.fitText(label, x, y + 14, w * 0.45, 14, false);
    ctx.textAlign = 'right';
    ctx.fillStyle = o.color || theme.fg;
    api.fitText(value, x + w, y + 14, w * 0.55, o.size || 20, true);
    return 32;
  };

  // ---- 数 ----
  api.group = function (n) {
    if (!isFinite(n)) return String(n);
    var neg = n < 0, s = String(Math.abs(Math.round(n)));
    var out = '';
    while (s.length > 3) { out = ',' + s.slice(-3) + out; s = s.slice(0, -3); }
    return (neg ? '−' : '') + s + out;
  };
  // 有効数字7桁までの数の表示(末尾の0は消す)
  api.number = function (v, digits) {
    if (!isFinite(v)) return '—';
    if (v === 0) return '0';
    digits = digits || 7;
    var abs = Math.abs(v);
    if (abs >= 1e15 || abs < 1e-6) return v.toExponential(digits - 1).replace(/\.?0+e/, 'e');
    var text = v.toPrecision(digits);
    if (text.indexOf('e') >= 0) text = Number(text).toString();
    if (text.indexOf('.') >= 0) text = text.replace(/0+$/, '').replace(/\.$/, '');
    var parts = text.replace('-', '').split('.');
    var head = api.group(Number(parts[0])).replace('−', '');
    return (v < 0 ? '−' : '') + head + (parts[1] ? '.' + parts[1] : '');
  };
  // 全角の数字・記号を半角に(入力の表記ゆれ)
  api.half = function (text) {
    return String(text).replace(/[！-～]/g, function (c) { return String.fromCharCode(c.charCodeAt(0) - 0xFEE0); })
      .replace(/　/g, ' ').replace(/[−ー－]/g, '-');
  };
  api.parseNumber = function (text) {
    var s = api.half(text).replace(/[,\s円]/g, '');
    if (s === '' || !/^[-+]?(\d+\.?\d*|\.\d+)$/.test(s)) return null;
    var v = Number(s);
    return isFinite(v) ? v : null;
  };
  api.pad2 = function (n) { return (n < 10 ? '0' : '') + n; };

  // ---- 名前の一覧(改行・カンマ・読点で区切る) ----
  api.splitNames = function (text) {
    return String(text).split(/[\n,、，]/).map(function (s) { return s.trim(); }).filter(function (s) { return s !== ''; });
  };
  // 並べ替え(rnd は 0〜1 の乱数を返す関数。指定しなければ random.next)
  api.shuffle = function (list, rnd) {
    rnd = rnd || function () { return random.next(); };
    var a = list.slice();
    for (var i = a.length - 1; i > 0; i--) {
      var j = Math.floor(rnd() * (i + 1));
      var t = a[i]; a[i] = a[j]; a[j] = t;
    }
    return a;
  };

  // ---- 日付(グレゴリオ暦。1970-01-01 からの日数) ----
  api.days = function (y, m, d) {
    y -= m <= 2 ? 1 : 0;
    var era = Math.floor(y / 400), yoe = y - era * 400;
    var mp = (m + 9) % 12, doy = Math.floor((153 * mp + 2) / 5) + d - 1;
    var doe = yoe * 365 + Math.floor(yoe / 4) - Math.floor(yoe / 100) + doy;
    return era * 146097 + doe - 719468;
  };
  api.civil = function (z) {
    z += 719468;
    var era = Math.floor(z / 146097), doe = z - era * 146097;
    var yoe = Math.floor((doe - Math.floor(doe / 1460) + Math.floor(doe / 36524) - Math.floor(doe / 146096)) / 365);
    var y = yoe + era * 400, doy = doe - (365 * yoe + Math.floor(yoe / 4) - Math.floor(yoe / 100));
    var mp = Math.floor((5 * doy + 2) / 153), d = doy - Math.floor((153 * mp + 2) / 5) + 1, m = mp < 10 ? mp + 3 : mp - 9;
    return { y: m <= 2 ? y + 1 : y, m: m, d: d };
  };
  api.weekday = function (z) { return ((z + 4) % 7 + 7) % 7; };
  api.weekdayNames = ['日', '月', '火', '水', '木', '金', '土'];
  api.validDate = function (y, m, d) {
    if (m < 1 || m > 12 || d < 1) return false;
    var c = api.civil(api.days(y, m, d));
    return c.y === y && c.m === m && c.d === d;
  };
  // 「2026-10-19」「2026/10/19」「20261019」「10/19」(年は today の年)。読めなければ null
  api.parseDate = function (text, today) {
    var s = api.half(text).trim().replace(/[年月.]/g, '/').replace(/日/g, '').replace(/-/g, '/');
    var m, y, mo, d;
    if ((m = /^(\d{4})\/(\d{1,2})\/(\d{1,2})$/.exec(s))) { y = +m[1]; mo = +m[2]; d = +m[3]; }
    else if ((m = /^(\d{4})(\d{2})(\d{2})$/.exec(s))) { y = +m[1]; mo = +m[2]; d = +m[3]; }
    else if ((m = /^(\d{1,2})\/(\d{1,2})$/.exec(s)) && today) { y = today.y; mo = +m[1]; d = +m[2]; }
    else return null;
    return api.validDate(y, mo, d) ? { y: y, m: mo, d: d } : null;
  };
  api.today = function () { var t = new Date(); return { y: t.getFullYear(), m: t.getMonth() + 1, d: t.getDate() }; };
  api.dateText = function (c) { return c.y + '年' + c.m + '月' + c.d + '日(' + api.weekdayNames[api.weekday(api.days(c.y, c.m, c.d))] + ')'; };

  // ---- 時間の長さ ----
  // 「1:30」(時:分)、「1:30:15」、「90」(分)、「1時間30分」「45秒」「1h30m」。秒の整数。読めなければ null
  api.parseDuration = function (text) {
    var body = api.half(text).toLowerCase().replace(/\s/g, '');
    if (body === '') return null;
    var sign = 1;
    if (body[0] === '-') { sign = -1; body = body.slice(1); } else if (body[0] === '+') { body = body.slice(1); }
    if (body === '') return null;
    if (body.indexOf(':') >= 0) {
      var parts = body.split(':');
      if (parts.length < 2 || parts.length > 3) return null;
      for (var i = 0; i < parts.length; i++) if (!/^\d+$/.test(parts[i])) return null;
      return sign * (+parts[0] * 3600 + +parts[1] * 60 + (parts.length === 3 ? +parts[2] : 0));
    }
    if (/^\d+$/.test(body)) return sign * +body * 60;
    var normalized = body.replace(/時間/g, 'h').replace(/分/g, 'm').replace(/秒/g, 's');
    var total = 0, digits = '', found = false;
    for (var j = 0; j < normalized.length; j++) {
      var c = normalized[j];
      if (c >= '0' && c <= '9') { digits += c; continue; }
      if (digits === '') return null;
      if (c === 'h') total += +digits * 3600;
      else if (c === 'm') total += +digits * 60;
      else if (c === 's') total += +digits;
      else return null;
      digits = '';
      found = true;
    }
    if (digits !== '' || !found) return null;
    return sign * total;
  };
  // 「1:30:00」(負なら先頭に「−」)
  api.clock = function (seconds) {
    var v = Math.abs(Math.round(seconds));
    var text = Math.floor(v / 3600) + ':' + api.pad2(Math.floor(v / 60) % 60) + ':' + api.pad2(v % 60);
    return seconds < 0 ? '−' + text : text;
  };
  // 「1時間30分」(0の単位は出さない)
  api.japaneseDuration = function (seconds) {
    var v = Math.abs(Math.round(seconds)), text = '';
    if (v >= 3600) text += Math.floor(v / 3600) + '時間';
    if (Math.floor(v / 60) % 60 > 0) text += (Math.floor(v / 60) % 60) + '分';
    if (v % 60 > 0 || text === '') text += (v % 60) + '秒';
    return seconds < 0 ? '−' + text : text;
  };

  return api;
})();

