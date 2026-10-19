// 時間計算(JavaScript 版)。時間の合計、時刻に足す・引く、2つの時刻の間。
var mode = '合計';
var values = { lines: '1:30\n45分\n2時間15分', time: '9:00', delta: '1時間30分', start: '9:00', end: '17:30', rest: '1時間' };

var TimeCalc = {
  parse: K.parseDuration,
  // 1行に1つの時間を足す(先頭が「-」の行は引く)。読めない行の番号(1始まり)も返す
  sum: function (text) {
    var total = 0, invalid = [];
    String(text).split('\n').forEach(function (line, i) {
      var s = line.trim();
      if (s === '') return;
      var v = TimeCalc.parse(s);
      if (v === null) invalid.push(i + 1); else total += v;
    });
    return { total: total, invalid: invalid };
  },
  // 「9:30」「930」「9時30分」を0時からの分に。読めなければ null
  clockMinutes: function (text) {
    var s = K.half(text).replace(/\s/g, '').replace('時', ':').replace('分', '');
    var m = /^(\d{1,2}):(\d{1,2})$/.exec(s) || /^(\d{1,2})(\d{2})$/.exec(s);
    if (!m) { if (/^\d{1,2}:?$/.test(s)) m = [s, s.replace(':', ''), '0']; else return null; }
    var hh = +m[1], mm = +m[2];
    if (hh > 47 || mm > 59) return null;
    return hh * 60 + mm;
  },
  // 開始から終了までの分。終了のほうが早ければ、翌日の時刻として数える
  minutesBetween: function (start, end) {
    var d = end - start;
    return d < 0 ? d + 1440 : d;
  },
  // 時刻(0時からの分)に秒を足す。{ text: '11:00', dayOffset: 0 }
  addToClock: function (minutes, seconds) {
    var totalSeconds = minutes * 60 + seconds;
    var day = Math.floor(totalSeconds / 86400), rest = totalSeconds - day * 86400;
    var hh = Math.floor(rest / 3600), mm = Math.floor(rest / 60) % 60, ss = rest % 60;
    return { text: hh + ':' + K.pad2(mm) + (ss ? ':' + K.pad2(ss) : ''), dayOffset: day };
  },
  dayText: function (offset) {
    if (offset === 0) return '';
    if (offset === 1) return '(翌日)';
    if (offset === -1) return '(前日)';
    return offset > 0 ? '(' + offset + '日後)' : '(' + (-offset) + '日前)';
  }
};

function showControls() {
  ['lines', 'time', 'delta', 'start', 'end', 'rest'].forEach(function (id) { ui.remove(id); });
  if (mode === '合計') {
    ui.text('lines', { label: '1行に1つ(例 1:30、45分、-15分)', value: values.lines, multiline: true });
  } else if (mode === '時刻に足す') {
    ui.text('time', { label: '時刻(例 9:30)', value: values.time, keyboard: 'number' });
    ui.text('delta', { label: '足す時間(引くときは -。例 1時間30分、-45分)', value: values.delta });
  } else {
    ui.text('start', { label: '開始の時刻(例 9:00)', value: values.start, keyboard: 'number' });
    ui.text('end', { label: '終了の時刻(例 17:30)', value: values.end, keyboard: 'number' });
    ui.text('rest', { label: '休憩(省略可。例 1時間)', value: values.rest });
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
  var pad = 12, cw = w - pad * 2, y = 12;
  K.card(pad, y, cw, 150, th);
  var x = pad + 14, iw = cw - 28;
  y += 14;
  if (mode === '合計') {
    var r = TimeCalc.sum(values.lines);
    y += K.valueRow('合計', K.clock(r.total), x, y, iw, th, { size: 30 }) + 10;
    y += K.valueRow('', K.japaneseDuration(r.total), x, y, iw, th, { size: 18 });
    y += K.valueRow('分で', K.number(r.total / 60, 6) + '分', x, y, iw, th, { size: 16 });
    if (r.invalid.length) y += K.paragraph('読めない行: ' + r.invalid.join('、') + '行目', x, y + 4, iw, 13, th.danger);
  } else if (mode === '時刻に足す') {
    var base = TimeCalc.clockMinutes(values.time), delta = TimeCalc.parse(values.delta);
    if (base === null || delta === null) {
      y += K.paragraph(base === null ? '時刻を読めませんでした' : '時間を読めませんでした', x, y, iw, 15, th.danger);
    } else {
      var res = TimeCalc.addToClock(base, delta);
      y += K.valueRow('結果', res.text + TimeCalc.dayText(res.dayOffset), x, y, iw, th, { size: 30 }) + 10;
      y += K.valueRow(delta < 0 ? '引いた時間' : '足した時間', K.japaneseDuration(Math.abs(delta)), x, y, iw, th, { size: 16 });
    }
  } else {
    var s = TimeCalc.clockMinutes(values.start), e = TimeCalc.clockMinutes(values.end);
    var rest = values.rest.trim() === '' ? 0 : TimeCalc.parse(values.rest);
    if (s === null || e === null || rest === null) {
      y += K.paragraph('時刻か休憩を読めませんでした', x, y, iw, 15, th.danger);
    } else {
      var minutes = TimeCalc.minutesBetween(s, e), work = minutes * 60 - rest;
      y += K.valueRow('間の時間', K.clock(minutes * 60).replace(/:00$/, ''), x, y, iw, th, { size: 30 }) + 10;
      if (rest) y += K.valueRow('休憩を引くと', K.japaneseDuration(work), x, y, iw, th, { size: 18 });
      y += K.valueRow('時間(10進)', K.number(work / 3600, 4) + '時間', x, y, iw, th, { size: 16 });
      if (e < s) y += K.paragraph('終了が開始より早いので、翌日の時刻として数えています', x, y + 4, iw, 13, th.sub);
    }
  }
  return Math.max(y + 30, 180);
}
