// カウンター(JavaScript 版)。8個まで。数は保存領域に残す。「削除」と「0に戻す」は、2回続けてタップしたときだけ。
var MAX = 8;
var counters = [];
var nextID = 1;
var nameText = '';
var armed = null;

var Counter = {
  add: function (list, name, id) {
    if (list.length >= MAX) return false;
    list.push({ id: id, name: name || ('カウンター' + id), value: 0 });
    return true;
  },
  // 範囲は −999,999〜999,999
  step: function (c, delta) { c.value = Math.max(-999999, Math.min(999999, c.value + delta)); return c.value; },
  total: function (list) { return list.reduce(function (a, c) { return a + c.value; }, 0); }
};

function setup() {
  var saved = storage.get('counter');
  if (saved && Array.isArray(saved.list)) { counters = saved.list; nextID = saved.nextID || counters.length + 1; }
  if (!counters.length) { Counter.add(counters, '', nextID++); }
}
function save() { storage.set('counter', { list: counters, nextID: nextID }); }

function onInput(name, value) {
  if (name === 'name') nameText = value;
  else if (name === 'add') {
    if (Counter.add(counters, nameText.trim().slice(0, 20), nextID)) { nextID++; ui.set('name', ''); nameText = ''; save(); }
  }
  K.invalidate();
}

function onTouch(e) {
  var b = K.hit(K.touch(e));
  if (!b) { armed = null; K.invalidate(); return; }
  var c = counters.filter(function (x) { return x.id === b.data; })[0];
  if (!c) return;
  if (b.id === 'plus') { Counter.step(c, 1); sound.play('click'); haptic('light'); armed = null; }
  else if (b.id === 'minus') { Counter.step(c, -1); sound.play('click'); haptic('light'); armed = null; }
  else if (b.id === 'reset' || b.id === 'delete') {
    var key = b.id + c.id;
    if (armed !== key) { armed = key; K.invalidate(); return; }
    armed = null;
    if (b.id === 'reset') c.value = 0; else counters = counters.filter(function (x) { return x !== c; });
    haptic('medium');
  }
  save();
  K.invalidate();
}
function frame() { K.frame(draw); }

function draw(w, h, th) {
  var pad = 12, cw = w - pad * 2, y = 12;
  if (counters.length > 1) {
    ctx.fillStyle = th.sub;
    ctx.textAlign = 'left';
    ctx.textBaseline = 'top';
    K.fitText('合計 ' + K.group(Counter.total(counters)), pad, y, cw, 15, true);
    y += 26;
  }
  counters.forEach(function (c) {
    var rowH = 128;
    K.card(pad, y, cw, rowH, th);
    ctx.fillStyle = th.sub;
    ctx.textAlign = 'left';
    ctx.textBaseline = 'top';
    K.fitText(c.name, pad + 12, y + 10, cw * 0.5, 15, true);
    var sw = 70;
    K.button('reset', pad + cw - 12 - sw * 2 - 6, y + 6, sw, 26, armed === 'reset' + c.id ? 'もう一度' : '0に戻す', { data: c.id, size: 12, color: armed === 'reset' + c.id ? th.danger : th.fg });
    K.button('delete', pad + cw - 12 - sw, y + 6, sw, 26, armed === 'delete' + c.id ? 'もう一度' : '削除', { data: c.id, size: 12, color: th.danger });
    var bw = Math.min(90, cw * 0.26);
    K.button('minus', pad + 12, y + 44, bw, 72, '−', { data: c.id, size: 34 });
    K.button('plus', pad + cw - 12 - bw, y + 44, bw, 72, '+', { data: c.id, size: 34, primary: true });
    ctx.fillStyle = th.fg;
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    K.fitText(K.group(c.value), w / 2, y + 80, cw - bw * 2 - 40, 46, true);
    y += rowH + 10;
  });
  if (counters.length >= MAX) y += K.paragraph('カウンターは' + MAX + '個までです', pad, y, cw, 13, th.sub);
  return y + 20;
}
