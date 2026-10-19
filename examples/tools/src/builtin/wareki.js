// 和暦・西暦・年齢(JavaScript 版)。明治以降の元号。元年は「元」と書く。
var mode = '西暦→和暦';
var values = { year: '', era: '令和8', birth: '2000/4/1' };

var Wareki = {
  // 新しい順。始まりの日
  eras: [
    { name: '令和', short: 'r', y: 2019, m: 5, d: 1 },
    { name: '平成', short: 'h', y: 1989, m: 1, d: 8 },
    { name: '昭和', short: 's', y: 1926, m: 12, d: 25 },
    { name: '大正', short: 't', y: 1912, m: 7, d: 30 },
    { name: '明治', short: 'm', y: 1868, m: 1, d: 25 }
  ],
  yearText: function (n) { return n === 1 ? '元' : String(n); },
  // その日の和暦。明治より前は null
  fromDate: function (c) {
    var z = K.days(c.y, c.m, c.d);
    for (var i = 0; i < Wareki.eras.length; i++) {
      var e = Wareki.eras[i];
      if (z >= K.days(e.y, e.m, e.d)) return { era: e.name, year: c.y - e.y + 1, text: e.name + Wareki.yearText(c.y - e.y + 1) + '年' };
    }
    return null;
  },
  // その年に使われた和暦(改元の年は2つ)
  fromYear: function (y) {
    var out = [];
    for (var i = Wareki.eras.length - 1; i >= 0; i--) {
      var e = Wareki.eras[i], next = Wareki.eras[i - 1];
      var endYear = next ? next.y : 9999;
      if (y >= e.y && y <= endYear && !(next && y === next.y && next.m === 1 && next.d === 1)) {
        out.push(e.name + Wareki.yearText(y - e.y + 1) + '年');
      }
    }
    return out.reverse();
  },
  // 「令和8」「R8」「平成元年」「h31」→ 西暦の年。読めなければ null
  toYear: function (text) {
    var s = K.half(text).trim().toLowerCase().replace(/\s/g, '').replace(/年$/, '');
    for (var i = 0; i < Wareki.eras.length; i++) {
      var e = Wareki.eras[i], rest = null;
      if (s.indexOf(e.name) === 0) rest = s.slice(e.name.length);
      else if (s[0] === e.short) rest = s.slice(1);
      if (rest === null) continue;
      var n = rest === '元' ? 1 : (/^\d{1,2}$/.test(rest) ? +rest : null);
      if (n === null || n < 1) return null;
      return { year: e.y + n - 1, era: e.name, n: n };
    }
    return null;
  },
  zodiac: function (y) { return ['子', '丑', '寅', '卯', '辰', '巳', '午', '未', '申', '酉', '戌', '亥'][((y - 4) % 12 + 12) % 12]; },
  // 満年齢(誕生日の前日の終わりに1つ増える扱いではなく、誕生日に増える)
  age: function (birth, today) {
    var a = today.y - birth.y;
    if (today.m < birth.m || (today.m === birth.m && today.d < birth.d)) a -= 1;
    return a;
  },
  // 次の誕生日までの日数(2/29 生まれは、うるう年でない年は 3/1 とする)
  daysToBirthday: function (birth, today) {
    function on(y) { return K.validDate(y, birth.m, birth.d) ? K.days(y, birth.m, birth.d) : K.days(y, 3, 1); }
    var z = K.days(today.y, today.m, today.d), next = on(today.y);
    if (next < z) next = on(today.y + 1);
    return next - z;
  }
};

function showControls() {
  ['year', 'era', 'birth'].forEach(function (id) { ui.remove(id); });
  if (!values.year) values.year = String(K.today().y);
  if (mode === '西暦→和暦') ui.text('year', { label: '西暦の年か日付(例 2019、2019/5/1)', value: values.year, keyboard: 'number' });
  else if (mode === '和暦→西暦') ui.text('era', { label: '和暦(例 令和8、平成元年、S64、h31)', value: values.era });
  else ui.text('birth', { label: '生年月日(例 2000/4/1)', value: values.birth, keyboard: 'number' });
}

function setup() { showControls(); }
function onInput(name, value) {
  if (name === 'mode') { if (value !== mode) { mode = value; showControls(); } }
  else values[name] = value;
  K.invalidate();
}
function onTouch(e) { K.touch(e); }
function frame() { K.frame(draw); }

function draw(w, h, th) {
  var pad = 12, cw = w - pad * 2, y = 12, x = pad + 14, iw = cw - 28, t = K.today();
  K.card(pad, y, cw, 170, th);
  y += 14;
  if (mode === '西暦→和暦') {
    var text = K.half(values.year).trim();
    if (/^\d{3,4}$/.test(text)) {
      var yy = +text, list = Wareki.fromYear(yy);
      y += K.valueRow(yy + '年', list.length ? list.join(' / ') : '明治より前', x, y, iw, th, { size: 26 }) + 10;
      y += K.valueRow('干支', Wareki.zodiac(yy) + '年', x, y, iw, th, { size: 16 });
      y += K.valueRow('今年で', (t.y - yy) + '歳(満、誕生日の後)', x, y, iw, th, { size: 16 });
    } else {
      var c = K.parseDate(values.year, t), wr = c ? Wareki.fromDate(c) : null;
      if (!c) { K.paragraph('年か日付を読めませんでした', x, y, iw, 15, th.danger); return 210; }
      y += K.valueRow(c.y + '/' + c.m + '/' + c.d, wr ? wr.text + c.m + '月' + c.d + '日' : '明治より前', x, y, iw, th, { size: 22 }) + 10;
      y += K.valueRow('干支', Wareki.zodiac(c.y) + '年', x, y, iw, th, { size: 16 });
    }
  } else if (mode === '和暦→西暦') {
    var r = Wareki.toYear(values.era);
    if (!r) { K.paragraph('和暦を読めませんでした(例 令和8、平成元年、S64)', x, y, iw, 15, th.danger); return 210; }
    y += K.valueRow(r.era + Wareki.yearText(r.n) + '年', r.year + '年', x, y, iw, th, { size: 30 }) + 10;
    var all = Wareki.fromYear(r.year);
    if (all.length > 1) y += K.valueRow('同じ年', all.join(' / '), x, y, iw, th, { size: 15 });
    y += K.valueRow('干支', Wareki.zodiac(r.year) + '年', x, y, iw, th, { size: 16 });
  } else {
    var b = K.parseDate(values.birth, t);
    if (!b || K.days(b.y, b.m, b.d) > K.days(t.y, t.m, t.d)) { K.paragraph('生年月日を読めませんでした', x, y, iw, 15, th.danger); return 210; }
    var age = Wareki.age(b, t), wb = Wareki.fromDate(b);
    y += K.valueRow('満年齢', age + '歳', x, y, iw, th, { size: 30 }) + 10;
    y += K.valueRow('数え年', (t.y - b.y + 1) + '歳', x, y, iw, th, { size: 16 });
    y += K.valueRow('生まれ', (wb ? wb.text : '') + '・' + Wareki.zodiac(b.y) + '年', x, y, iw, th, { size: 16 });
    var left = Wareki.daysToBirthday(b, t);
    y += K.valueRow('次の誕生日', left === 0 ? '今日' : 'あと' + left + '日', x, y, iw, th, { size: 16 });
  }
  return 210;
}
