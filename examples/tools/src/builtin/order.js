// 順番決め(JavaScript 版)。名前を1行に1つ入れて、ランダムな順に並べる。名前をタップすると、済みの印を付けられる。
var DEFAULT_NAMES = 'Aさん\nBさん\nCさん\nDさん\nEさん';
var namesText = DEFAULT_NAMES;
var order = [];
var done = [];

var Order = {
  make: function (names, rnd) { return K.shuffle(names, rnd); }
};

function setup() {
  var saved = storage.get('order') || {};
  namesText = typeof saved.namesText === 'string' ? saved.namesText : DEFAULT_NAMES;
  order = saved.order || [];
  done = saved.done || [];
  ui.text('names', { label: 'メンバー(1行に1人)', value: namesText, multiline: true });
  ui.button('shuffle', '順番を決める');
}
function save() { storage.set('order', { namesText: namesText, order: order, done: done }); }

function onInput(name, value) {
  if (name === 'names') namesText = value;
  else if (name === 'shuffle') {
    order = Order.make(K.splitNames(namesText), function () { return random.next(); });
    done = [];
    sound.play('pop');
    K.scrollTo(0);
  }
  save();
  K.invalidate();
}

function onTouch(e) {
  var b = K.hit(K.touch(e));
  if (!b) return;
  var i = done.indexOf(b.data);
  if (i >= 0) done.splice(i, 1); else done.push(b.data);
  haptic('selection');
  save();
  K.invalidate();
}
function frame() { K.frame(draw); }

function draw(w, h, th) {
  var pad = 12, cw = w - pad * 2, y = 12;
  if (!order.length) { y += K.paragraph('「順番を決める」を押してください。', pad, y, cw, 15, th.sub); return y + 20; }
  order.forEach(function (name, i) {
    var isDone = done.indexOf(i) >= 0;
    K.card(pad, y, cw, 44, th);
    ctx.globalAlpha = isDone ? 0.4 : 1;
    ctx.fillStyle = th.accent;
    ctx.beginPath(); ctx.arc(pad + 26, y + 22, 14, 0, Math.PI * 2); ctx.fill();
    ctx.fillStyle = th.accentFg;
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    K.fitText(String(i + 1), pad + 26, y + 22, 24, 15, true);
    ctx.fillStyle = th.fg;
    ctx.textAlign = 'left';
    K.fitText(name + (isDone ? '(済み)' : ''), pad + 50, y + 22, cw - 60, 17, true);
    ctx.globalAlpha = 1;
    K.area('row', pad, y, cw, 44, i);
    y += 50;
  });
  return y + 20;
}
