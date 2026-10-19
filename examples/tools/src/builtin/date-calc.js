// 日付計算(JavaScript 版)。2つの日付の差、◯日後・◯日前、曜日。祝日の名前はアプリの計算(app.holidayName)。
var mode = '日数の差';
var values = { from: '', to: '', days: '100', base: '' };

var DateCalc = {
  // 2つの日付の差(日)。b が後なら正
  diff: function (a, b) { return K.days(b.y, b.m, b.d) - K.days(a.y, a.m, a.d); },
  add: function (c, n) { return K.civil(K.days(c.y, c.m, c.d) + n); },
  daysInMonth: function (y, m) { return m === 12 ? 31 : K.civil(K.days(y, m + 1, 1) - 1).d; },
  // a に n か月を足す(日は、その月の日数までに切り詰める)
  addMonths: function (a, n) {
    var index = a.y * 12 + (a.m - 1) + n, y = Math.floor(index / 12), m = index - y * 12 + 1;
    return { y: y, m: m, d: Math.min(a.d, DateCalc.daysInMonth(y, m)) };
  },
  // 「◯年◯か月◯日」(a から b まで。a ≦ b)
  span: function (a, b) {
    var months = (b.y - a.y) * 12 + (b.m - a.m);
    if (b.d < a.d) months -= 1;
    var anchor = DateCalc.addMonths(a, months);
    return { years: Math.floor(months / 12), months: months % 12, days: DateCalc.diff(anchor, b) };
  },
  weekday: function (c) { return K.weekdayNames[K.weekday(K.days(c.y, c.m, c.d))]; }
};

function holiday(c) {
  var name = app.holidayName(c.y, c.m, c.d);
  return name ? '(' + name + ')' : '';
}

function showControls() {
  ['from', 'to', 'days', 'base'].forEach(function (id) { ui.remove(id); });
  var t = K.today(), today = t.y + '/' + t.m + '/' + t.d;
  if (!values.from) values.from = today;
  if (!values.to) values.to = (t.y + 1) + '/1/1';
  if (!values.base) values.base = today;
  if (mode === '日数の差') {
    ui.text('from', { label: '始めの日(例 2026/10/19、10/19)', value: values.from, keyboard: 'number' });
    ui.text('to', { label: '終わりの日', value: values.to, keyboard: 'number' });
  } else if (mode === '◯日後') {
    ui.text('base', { label: '基準の日', value: values.base, keyboard: 'number' });
    ui.text('days', { label: '日数(前は -。例 100、-30)', value: values.days, keyboard: 'number' });
  } else {
    ui.text('base', { label: '日付', value: values.base, keyboard: 'number' });
  }
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
  K.card(pad, y, cw, 160, th);
  y += 14;
  if (mode === '日数の差') {
    var a = K.parseDate(values.from, t), b = K.parseDate(values.to, t);
    if (!a || !b) { K.paragraph('日付を読めませんでした(例 2026/10/19)', x, y, iw, 15, th.danger); return 200; }
    var d = DateCalc.diff(a, b);
    y += K.valueRow('差', K.group(d) + '日', x, y, iw, th, { size: 30 }) + 10;
    y += K.valueRow('両端を含めると', K.group(Math.abs(d) + 1) + '日', x, y, iw, th, { size: 16 });
    var s = d >= 0 ? DateCalc.span(a, b) : DateCalc.span(b, a);
    y += K.valueRow('', s.years + '年' + s.months + 'か月' + s.days + '日', x, y, iw, th, { size: 16 });
    y += K.valueRow('週で', Math.floor(Math.abs(d) / 7) + '週' + (Math.abs(d) % 7) + '日', x, y, iw, th, { size: 16 });
  } else if (mode === '◯日後') {
    var base = K.parseDate(values.base, t), n = K.parseNumber(values.days);
    if (!base || n === null || Math.abs(n) > 1000000) { K.paragraph('日付か日数を読めませんでした', x, y, iw, 15, th.danger); return 200; }
    var r = DateCalc.add(base, Math.round(n));
    y += K.valueRow(n < 0 ? Math.abs(n) + '日前' : n + '日後', r.y + '/' + r.m + '/' + r.d, x, y, iw, th, { size: 30 }) + 10;
    y += K.valueRow('曜日', DateCalc.weekday(r) + '曜日' + holiday(r), x, y, iw, th, { size: 16 });
  } else {
    var c = K.parseDate(values.base, t);
    if (!c) { K.paragraph('日付を読めませんでした', x, y, iw, 15, th.danger); return 200; }
    y += K.valueRow(c.y + '/' + c.m + '/' + c.d, DateCalc.weekday(c) + '曜日', x, y, iw, th, { size: 30 }) + 10;
    var hn = holiday(c);
    if (hn) y += K.valueRow('祝日', hn.slice(1, -1), x, y, iw, th, { size: 16 });
    var fromToday = DateCalc.diff(t, c);
    y += K.valueRow('今日から', fromToday === 0 ? '今日' : (fromToday > 0 ? fromToday + '日後' : (-fromToday) + '日前'), x, y, iw, th, { size: 16 });
  }
  return 200;
}
