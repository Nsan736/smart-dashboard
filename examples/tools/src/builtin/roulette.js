// ルーレット(JavaScript 版)。項目は1行に1つ。円盤をタップするか「回す」で回す。くじ引き(出た項目を外す)と、履歴(10件)つき。
var SPIN_TIME = 3.0;
var items = [];
var drawn = [];
var history = [];
var rot = 0;
var spin = null;
var result = null;
var lottery = false;

var Roulette = {
  // 項目の番号を決める(rnd は 0〜1 の乱数)
  pick: function (n, rnd) { return Math.min(n - 1, Math.floor(rnd() * n)); },
  // 針(真上)の下にある項目の番号
  indexAt: function (rotation, n) {
    var two = Math.PI * 2, seg = two / n;
    var theta = ((-rotation % two) + two) % two;
    return Math.min(n - 1, Math.floor(theta / seg));
  },
  // index の扇形の中(端から15〜85%)で止まる回転。current から turns 回以上回す
  stopRotation: function (current, index, n, offset, turns) {
    var two = Math.PI * 2, seg = two / n;
    var f = 0.15 + 0.7 * offset;
    var want = -(index + f) * seg;
    var base = current + turns * two;
    var k = Math.ceil((base - want) / two);
    return want + k * two;
  },
  // 回り方(はじめ速く、だんだん遅く)
  ease: function (p) { return 1 - Math.pow(1 - p, 3); },
  // くじ引きのときに残っている項目(出た番号を除く)
  remaining: function (list, drawnList) {
    return list.map(function (name, i) { return i; }).filter(function (i) { return drawnList.indexOf(i) < 0; });
  }
};

var DEFAULT_ITEMS = 'カレー\nラーメン\n寿司\nうどん\n焼肉\nパスタ';
var itemsText = DEFAULT_ITEMS;

// 入れた項目も保存するので、部品は setup で、保存した値から作る
function setup() {
  var saved = storage.get('roulette') || {};
  history = saved.history || [];
  drawn = saved.drawn || [];
  lottery = !!saved.lottery;
  itemsText = typeof saved.itemsText === 'string' ? saved.itemsText : DEFAULT_ITEMS;
  items = K.splitNames(itemsText).slice(0, 30);
  ui.text('items', { label: '項目(1行に1つ、30個まで)', value: itemsText, multiline: true });
  ui.toggle('lottery', { label: 'くじ引き(出た項目を外す)', value: lottery });
  ui.button('spin', '回す');
  ui.button('reset', '履歴を消す');
}
function save() { storage.set('roulette', { history: history, drawn: drawn, lottery: lottery, itemsText: itemsText }); }

function onInput(name, value) {
  if (name === 'items') {
    itemsText = value;
    var next = K.splitNames(value).slice(0, 30);
    if (next.join('\n') !== items.join('\n')) { items = next; drawn = []; result = null; }
    save();
  } else if (name === 'lottery') { lottery = value; save(); }
  else if (name === 'spin') { start(); }
  else if (name === 'reset') { drawn = []; history = []; result = null; save(); }
  K.invalidate();
}

function start() {
  if (spin || items.length < 2) return;
  var pool = lottery ? Roulette.remaining(items, drawn) : items.map(function (s, i) { return i; });
  if (!pool.length) { result = 'すべて出ました(「履歴を消す」でやり直し)'; K.invalidate(); return; }
  var index = pool[Roulette.pick(pool.length, function () { return random.next(); })];
  var target = Roulette.stopRotation(rot, index, items.length, random.next(), 4);
  spin = { from: rot, to: target, t: 0, index: index, lastSeg: -1 };
  result = null;
}

function onTouch(e) {
  var p = K.touch(e);
  if (!p) return;
  var b = K.hit(p);
  if (b && b.id === 'wheel') start();
}

function frame(t, dt) {
  if (spin) {
    spin.t += dt;
    var p = Math.min(1, spin.t / SPIN_TIME);
    rot = spin.from + (spin.to - spin.from) * Roulette.ease(p);
    var seg = Roulette.indexAt(rot, items.length);
    if (seg !== spin.lastSeg) { spin.lastSeg = seg; if (p < 0.97) sound.play('click'); }
    if (p >= 1) {
      var name = items[spin.index];
      result = name;
      if (lottery) drawn.push(spin.index);
      history.unshift(name);
      history = history.slice(0, 10);
      save();
      spin = null;
      sound.play('success');
      haptic('success');
    }
    K.invalidate();
  }
  K.frame(draw);
}

function draw(w, h, th) {
  var pad = 12, y = 10;
  if (items.length < 2) { K.paragraph('下の欄に、項目を1行に1つ(2つ以上)入れてください。', pad, y + 10, w - pad * 2, 15, th.sub); return 80; }
  var size = Math.min(w - pad * 2, Math.max(180, h - 120)), r = size / 2 - 6, cx = w / 2, cy = y + 16 + size / 2;
  var n = items.length, seg = Math.PI * 2 / n;
  ctx.save();
  ctx.translate(cx, cy);
  ctx.rotate(rot);
  for (var i = 0; i < n; i++) {
    var a0 = -Math.PI / 2 + i * seg;
    ctx.fillStyle = K.palette[i % K.palette.length];
    ctx.globalAlpha = lottery && drawn.indexOf(i) >= 0 ? 0.25 : 1;
    ctx.beginPath(); ctx.moveTo(0, 0); ctx.arc(0, 0, r, a0, a0 + seg); ctx.closePath(); ctx.fill();
    ctx.save();
    ctx.rotate(a0 + seg / 2);
    ctx.fillStyle = '#ffffff';
    ctx.textAlign = 'right';
    ctx.textBaseline = 'middle';
    K.fitText(items[i].slice(0, 12), r - 10, 0, r * 0.62, Math.min(18, 8 + 120 / n), true);
    ctx.restore();
  }
  ctx.globalAlpha = 1;
  ctx.restore();
  ctx.fillStyle = th.card;
  ctx.beginPath(); ctx.arc(cx, cy, r * 0.12, 0, Math.PI * 2); ctx.fill();
  // 針(真上)
  ctx.fillStyle = th.fg;
  ctx.beginPath(); ctx.moveTo(cx - 12, cy - r - 12); ctx.lineTo(cx + 12, cy - r - 12); ctx.lineTo(cx, cy - r + 14); ctx.closePath(); ctx.fill();
  K.area('wheel', cx - r, cy - r, r * 2, r * 2);
  y = cy + r + 16;
  ctx.textAlign = 'center';
  ctx.textBaseline = 'top';
  ctx.fillStyle = result ? th.accent : th.sub;
  K.fitText(result || (spin ? '回っています…' : '円盤をタップして回す'), w / 2, y, w - pad * 2, result ? 28 : 16, !!result);
  y += 40;
  if (lottery) { ctx.fillStyle = th.sub; K.fitText('くじ引き: 残り ' + Roulette.remaining(items, drawn).length + ' / ' + n, w / 2, y, w - pad * 2, 14, false); y += 24; }
  if (history.length) {
    y += K.paragraph('履歴: ' + history.join('、'), pad, y, w - pad * 2, 13, th.sub);
  }
  return y + 20;
}
