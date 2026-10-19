// サイコロ(JavaScript 版)。個数(1〜10)と面の数を選ぶ。6面は点、ほかは数字。振ると約0.5秒、目を切り替えながら傾ける。
var count = 2;
var faces = 6;
var dice = [];
var rolling = null;
var history = [];

var Dice = {
  roll: function (n, f, rnd) {
    var out = [];
    for (var i = 0; i < n; i++) out.push(1 + Math.min(f - 1, Math.floor(rnd() * f)));
    return out;
  },
  sum: function (list) { return list.reduce(function (a, b) { return a + b; }, 0); },
  // 6面の点の位置(-1〜1)
  pips: function (v) {
    var c = [0, 0], tl = [-1, -1], tr = [1, -1], ml = [-1, 0], mr = [1, 0], bl = [-1, 1], br = [1, 1];
    return [[], [c], [tl, br], [tl, c, br], [tl, tr, bl, br], [tl, tr, c, bl, br], [tl, tr, ml, mr, bl, br]][v] || [];
  }
};

function rnd() { return random.next(); }

function setup() {
  var saved = storage.get('dice') || {};
  count = saved.count || 2;
  faces = saved.faces || 6;
  history = saved.history || [];
  dice = Dice.roll(count, faces, rnd);
  ui.slider('count', { label: '個数', min: 1, max: 10, step: 1, value: count });
  ui.choice('faces', { label: '面の数', options: ['4', '6', '8', '10', '12', '20', '100'], value: String(faces) });
  ui.button('roll', '振る');
}
function save() { storage.set('dice', { count: count, faces: faces, history: history }); }

function start() {
  if (rolling) return;
  rolling = { t: 0, next: 0, final: Dice.roll(count, faces, rnd) };
  haptic('medium');
}

function onInput(name, value) {
  if (name === 'count') { count = Math.round(value); dice = Dice.roll(count, faces, rnd); save(); }
  else if (name === 'faces') { faces = +value; dice = Dice.roll(count, faces, rnd); save(); }
  else if (name === 'roll') start();
  K.invalidate();
}

function onTouch(e) {
  var p = K.touch(e);
  if (p && K.hit(p)) start();
}

function frame(t, dt) {
  if (rolling) {
    rolling.t += dt;
    rolling.next -= dt;
    if (rolling.next <= 0) { dice = Dice.roll(count, faces, rnd); rolling.next = 0.07; sound.play('click'); }
    if (rolling.t >= 0.5) {
      dice = rolling.final;
      rolling = null;
      history.unshift(dice.length > 1 ? dice.join('+') + '=' + Dice.sum(dice) : String(dice[0]));
      history = history.slice(0, 8);
      save();
      sound.play('pop');
    }
    K.invalidate();
  }
  K.frame(draw);
}

function draw(w, h, th) {
  var pad = 12, cols = count <= 2 ? count : (count <= 6 ? 3 : 4), rows = Math.ceil(count / cols);
  var cell = Math.min((w - pad * 2) / cols, Math.max(80, (h - 140) / rows), 130), size = cell * 0.8;
  var top = 16, left = (w - cell * cols) / 2;
  K.area('dice', 0, 0, w, top + rows * cell);
  for (var i = 0; i < dice.length; i++) {
    var cx = left + (i % cols) * cell + cell / 2, cy = top + Math.floor(i / cols) * cell + cell / 2;
    ctx.save();
    ctx.translate(cx, cy);
    if (rolling) ctx.rotate(Math.sin(rolling.t * 40 + i) * 0.35);
    ctx.fillStyle = faces === 6 ? '#ffffff' : K.palette[(i + 4) % K.palette.length];
    K.roundRect(-size / 2, -size / 2, size, size, size * 0.18);
    ctx.fill();
    ctx.strokeStyle = th.line;
    ctx.lineWidth = 2;
    ctx.stroke();
    if (faces === 6) {
      var pts = Dice.pips(dice[i]);
      ctx.fillStyle = dice[i] === 1 ? '#e63946' : '#1c1c1e';
      for (var j = 0; j < pts.length; j++) {
        ctx.beginPath();
        ctx.arc(pts[j][0] * size * 0.27, pts[j][1] * size * 0.27, size * (dice[i] === 1 ? 0.13 : 0.085), 0, Math.PI * 2);
        ctx.fill();
      }
    } else {
      ctx.fillStyle = '#ffffff';
      ctx.textAlign = 'center';
      ctx.textBaseline = 'middle';
      K.fitText(String(dice[i]), 0, 2, size * 0.8, size * 0.45, true);
    }
    ctx.restore();
  }
  var y = top + rows * cell + 8;
  ctx.fillStyle = th.fg;
  ctx.textAlign = 'center';
  ctx.textBaseline = 'top';
  if (count > 1) K.fitText('合計 ' + Dice.sum(dice), w / 2, y, w - pad * 2, 28, true);
  y += 40;
  ctx.fillStyle = th.sub;
  K.fitText(rolling ? '' : 'サイコロをタップしても振れます', w / 2, y, w - pad * 2, 13, false);
  y += 24;
  if (history.length) y += K.paragraph('履歴: ' + history.join('、'), pad, y, w - pad * 2, 13, th.sub);
  return y + 20;
}
