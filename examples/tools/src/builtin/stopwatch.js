// ストップウォッチ(JavaScript 版)。始めた時刻で持つので、画面を閉じても進む。ラップは100件まで。
var MAX_LAPS = 100;
var sw = { startedAt: null, elapsed: 0, laps: [] };
var lastKey = '';

var StopwatchLogic = {
  // 経過のミリ秒
  elapsed: function (s, now) { return s.elapsed + (s.startedAt === null ? 0 : now - s.startedAt); },
  start: function (s, now) { if (s.startedAt === null) s.startedAt = now; return s; },
  stop: function (s, now) { if (s.startedAt !== null) { s.elapsed += now - s.startedAt; s.startedAt = null; } return s; },
  reset: function (s) { s.startedAt = null; s.elapsed = 0; s.laps = []; return s; },
  // ラップ: 経過の合計を記録する(区間は表示のときに前との差で出す)
  lap: function (s, now) {
    if (s.laps.length < MAX_LAPS) s.laps.push(StopwatchLogic.elapsed(s, now));
    return s;
  },
  // 「1:02.34」(1時間以上は「1:02:03.45」)。ms はミリ秒
  text: function (ms) {
    var cs = Math.floor(ms / 10), s = Math.floor(cs / 100), m = Math.floor(s / 60), hh = Math.floor(m / 60);
    var tail = K.pad2(s % 60) + '.' + K.pad2(cs % 100);
    return hh > 0 ? hh + ':' + K.pad2(m % 60) + ':' + tail : m + ':' + tail;
  }
};

function setup() {
  var saved = storage.get('stopwatch');
  if (saved && Array.isArray(saved.laps)) sw = saved;
}
function save() { storage.set('stopwatch', sw); }

function onTouch(e) {
  var b = K.hit(K.touch(e));
  if (!b) return;
  var now = Date.now();
  if (b.id === 'start') StopwatchLogic.start(sw, now);
  else if (b.id === 'stop') StopwatchLogic.stop(sw, now);
  else if (b.id === 'lap') StopwatchLogic.lap(sw, now);
  else if (b.id === 'reset') StopwatchLogic.reset(sw);
  haptic('light');
  save();
  K.invalidate();
}

function onInput(name, value) { if (name === 'awake') screen.keepAwake(value); }

function frame() {
  // 動いている間は毎コマ、止まっていれば変わったときだけ描く
  var key = sw.startedAt === null ? 'stop' + sw.elapsed + ':' + sw.laps.length : 'run';
  if (key === 'run' || key !== lastKey) { lastKey = key; K.invalidate(); }
  K.frame(draw);
}

function draw(w, h, th) {
  var now = Date.now(), pad = 12, cw = w - pad * 2, y = 16;
  var total = StopwatchLogic.elapsed(sw, now);
  ctx.textAlign = 'center';
  ctx.textBaseline = 'top';
  ctx.fillStyle = th.fg;
  K.fitText(StopwatchLogic.text(total), w / 2, y, cw, 56, true);
  y += 76;
  var running = sw.startedAt !== null, bw = (cw - 8) / 2;
  if (running) {
    K.button('lap', pad, y, bw, 48, 'ラップ');
    K.button('stop', pad + bw + 8, y, bw, 48, '停止', { fill: th.danger, color: '#ffffff' });
  } else {
    K.button('reset', pad, y, bw, 48, 'リセット');
    K.button('start', pad + bw + 8, y, bw, 48, total > 0 ? '再開' : '開始', { primary: true });
  }
  y += 64;
  if (!sw.laps.length) return y;
  // 区間の最短と最長に色を付ける
  var splits = sw.laps.map(function (v, i) { return v - (i ? sw.laps[i - 1] : 0); });
  var fastest = Math.min.apply(null, splits), slowest = Math.max.apply(null, splits);
  for (var i = sw.laps.length - 1; i >= 0; i--) {
    var color = splits.length > 1 && splits[i] === fastest ? th.ok : (splits.length > 1 && splits[i] === slowest ? th.danger : th.fg);
    ctx.textBaseline = 'middle';
    ctx.textAlign = 'left';
    ctx.fillStyle = th.sub;
    ctx.font = K.font(15, false);
    ctx.fillText('ラップ ' + (i + 1), pad, y + 14);
    ctx.textAlign = 'center';
    ctx.fillStyle = color;
    ctx.font = K.font(17, true);
    ctx.fillText(StopwatchLogic.text(splits[i]), w / 2 + 10, y + 14);
    ctx.textAlign = 'right';
    ctx.fillStyle = th.sub;
    ctx.font = K.font(15, false);
    ctx.fillText(StopwatchLogic.text(sw.laps[i]), w - pad, y + 14);
    ctx.fillStyle = th.line;
    ctx.fillRect(pad, y + 30, cw, 1);
    y += 32;
  }
  return y + 10;
}
