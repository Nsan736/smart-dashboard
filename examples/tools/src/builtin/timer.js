// タイマー(JavaScript 版)。終了の時刻で持つので、画面を閉じても進む。終わったら通知(notify)と、開いていれば音と振動。
// タイマーの一覧は保存領域(storage)の 'timers' に残す。
var MAX_TIMERS = 6;
var timers = [];
var nextID = 1;
var notifyOn = true;
var durationText = '5分';
var labelText = '';
var message = '';
var lastKey = '';
var ringUntil = 0;
var ringNext = 0;

var TimerLogic = {
  // 残りの秒(小数)。now はミリ秒
  remaining: function (t, now) {
    if (t.state === 'running') return Math.max(0, (t.endAt - now) / 1000);
    if (t.state === 'paused') return t.left;
    if (t.state === 'done') return 0;
    return t.total;
  },
  start: function (t, now) {
    var left = t.state === 'paused' ? t.left : t.total;
    t.state = 'running';
    t.endAt = now + left * 1000;
    return t;
  },
  pause: function (t, now) {
    t.left = TimerLogic.remaining(t, now);
    t.state = 'paused';
    t.endAt = null;
    return t;
  },
  reset: function (t) { t.state = 'idle'; t.endAt = null; t.left = t.total; return t; },
  // 時刻を進めて、今終わったタイマーを返す
  advance: function (list, now) {
    var finished = [];
    list.forEach(function (t) {
      if (t.state === 'running' && t.endAt <= now) { t.state = 'done'; t.endAt = null; finished.push(t); }
    });
    return finished;
  },
  // 表示(1時間以上は 時:分:秒)。切り上げて、0.2秒で「0:01」と出す
  text: function (seconds) {
    var s = Math.ceil(seconds - 1e-6);
    if (s >= 3600) return K.clock(s);
    return Math.floor(s / 60) + ':' + K.pad2(s % 60);
  }
};

function save() { storage.set('timers', { list: timers, nextID: nextID }); }

function setup() {
  var saved = storage.get('timers');
  if (saved && Array.isArray(saved.list)) { timers = saved.list; nextID = saved.nextID || timers.length + 1; }
  // 閉じていた間に終わったものは、終わった状態にする(音は鳴らさない)
  TimerLogic.advance(timers, Date.now());
  save();
}

function schedule(t) {
  if (!notifyOn) return;
  var seconds = Math.max(1, Math.round((t.endAt - Date.now()) / 1000));
  try {
    notify.schedule('t' + t.id, seconds, { title: (t.label || 'タイマー') + 'が終わりました', body: TimerLogic.text(t.total) + ' のタイマー' });
  } catch (e) { message = String(e.message || e); }
}
function unschedule(t) { notify.cancel('t' + t.id); }

function add() {
  var seconds = K.parseDuration(durationText);
  if (seconds === null || seconds <= 0) { message = '時間を読めませんでした(例: 5分、90秒、1時間30分、1:30:00)'; K.invalidate(); return; }
  if (seconds > 86400) { message = '24時間までにしてください'; K.invalidate(); return; }
  if (timers.length >= MAX_TIMERS) { message = 'タイマーは' + MAX_TIMERS + '個までです(終わったものを削除してください)'; K.invalidate(); return; }
  var t = { id: nextID++, label: labelText.trim().slice(0, 20), total: seconds, left: seconds, state: 'idle', endAt: null };
  TimerLogic.start(t, Date.now());
  timers.push(t);
  schedule(t);
  message = '';
  sound.play('click');
  save();
  K.invalidate();
}

function onInput(name, value) {
  if (name === 'duration') durationText = value;
  else if (name === 'label') labelText = value;
  else if (name === 'add') add();
  else if (name === 'awake') screen.keepAwake(value);
  else if (name === 'notify') {
    notifyOn = value;
    timers.forEach(function (t) { if (t.state === 'running') { if (notifyOn) schedule(t); else unschedule(t); } });
  }
}

function onTouch(e) {
  var b = K.hit(K.touch(e));
  if (!b) return;
  var t = timers.filter(function (x) { return x.id === b.data; })[0];
  if (b.id === 'stopRing') { ringUntil = 0; K.invalidate(); return; }
  if (!t) return;
  var now = Date.now();
  if (b.id === 'toggle') {
    if (t.state === 'running') { TimerLogic.pause(t, now); unschedule(t); }
    else { if (t.state === 'done') TimerLogic.reset(t); TimerLogic.start(t, now); schedule(t); }
    ringUntil = 0;
  } else if (b.id === 'reset') {
    unschedule(t); TimerLogic.reset(t); ringUntil = 0;
  } else if (b.id === 'delete') {
    unschedule(t); timers = timers.filter(function (x) { return x !== t; }); ringUntil = 0;
  }
  haptic('light');
  save();
  K.invalidate();
}

function frame() {
  var now = Date.now();
  var finished = TimerLogic.advance(timers, now);
  if (finished.length) {
    save();
    ringUntil = now + 10000;
    ringNext = now;
    haptic('success');
  }
  if (ringUntil > now && now >= ringNext) { sound.play('success'); ringNext = now + 1200; }
  // 表示の秒が変わったときだけ描く
  var key = timers.map(function (t) { return t.id + t.state + TimerLogic.text(TimerLogic.remaining(t, now)); }).join('|') + (ringUntil > now);
  if (key !== lastKey) { lastKey = key; K.invalidate(); }
  K.frame(draw);
}

function draw(w, h, th) {
  var now = Date.now(), y = 12, pad = 12, cw = w - pad * 2;
  if (message) { y += K.paragraph(message, pad, y, cw, 14, th.danger) + 8; }
  if (ringUntil > now) {
    K.button('stopRing', pad, y, cw, 44, '音を止める', { primary: true });
    y += 56;
  }
  if (!timers.length) {
    y += K.paragraph('下の欄に時間を入れて「追加して開始」を押すと、タイマーが動きます。閉じても進み、終わったら通知します。', pad, y + 20, cw, 15, th.sub);
    return y + 40;
  }
  timers.forEach(function (t) {
    var rowH = 112;
    K.card(pad, y, cw, rowH, th);
    var left = TimerLogic.remaining(t, now);
    ctx.textAlign = 'left';
    ctx.textBaseline = 'top';
    ctx.fillStyle = th.sub;
    K.fitText((t.label || 'タイマー') + '  ' + TimerLogic.text(t.total), pad + 12, y + 10, cw - 24, 14, false);
    ctx.fillStyle = t.state === 'done' ? th.danger : (t.state === 'running' ? th.fg : th.sub);
    ctx.textBaseline = 'top';
    K.fitText(t.state === 'done' ? '終了' : TimerLogic.text(left), pad + 12, y + 30, cw * 0.6, 40, true);
    if (t.state === 'running') {
      var end = new Date(t.endAt);
      ctx.fillStyle = th.sub;
      ctx.textAlign = 'right';
      K.fitText(end.getHours() + ':' + K.pad2(end.getMinutes()) + ' に終了', pad + cw - 12, y + 44, cw * 0.38, 13, false);
    }
    var bw = (cw - 24 - 16) / 3, by = y + rowH - 38;
    K.button('toggle', pad + 12, by, bw, 30, t.state === 'running' ? '一時停止' : (t.state === 'paused' ? '再開' : '開始'), { primary: t.state !== 'running', data: t.id, size: 14 });
    K.button('reset', pad + 12 + bw + 8, by, bw, 30, 'リセット', { data: t.id, size: 14 });
    K.button('delete', pad + 12 + (bw + 8) * 2, by, bw, 30, '削除', { data: t.id, size: 14, color: th.danger });
    y += rowH + 10;
  });
  return y + 10;
}
