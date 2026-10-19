// コイントス(JavaScript 版)。タップで投げる。横軸の回転で、角度から手前の面(表=金、裏=銀)を決める。回数を数える。
var FLIP_TIME = 1.0;
var side = 0;
var flip = null;
var counts = [0, 0];
var recent = [];

var Coin = {
  // 0=表、1=裏
  toss: function (rnd) { return rnd() < 0.5 ? 0 : 1; },
  // 回転の角度(ラジアン)で手前の面。cos が負なら裏返っている
  faceAt: function (start, angle) { return Math.cos(angle) >= 0 ? start : 1 - start; },
  // 結果が result になるように、半回転の回数を決める(最低 minHalf 回)
  halfTurns: function (start, result, minHalf) { var n = minHalf; if ((n % 2 === 0) !== (start === result)) n += 1; return n; }
};

function setup() {
  var saved = storage.get('coin') || {};
  counts = saved.counts || [0, 0];
  recent = saved.recent || [];
  ui.button('toss', '投げる');
  ui.button('reset', '回数を消す');
}
function save() { storage.set('coin', { counts: counts, recent: recent }); }

function toss() {
  if (flip) return;
  var result = Coin.toss(function () { return random.next(); });
  flip = { t: 0, start: side, result: result, half: Coin.halfTurns(side, result, 9) };
  haptic('light');
}

function onInput(name) {
  if (name === 'toss') toss();
  else if (name === 'reset') { counts = [0, 0]; recent = []; save(); }
  K.invalidate();
}
function onTouch(e) { var p = K.touch(e); if (p) toss(); }

function frame(t, dt) {
  if (flip) {
    flip.t += dt;
    if (flip.t >= FLIP_TIME) {
      side = flip.result;
      counts[side] += 1;
      recent.unshift(side === 0 ? '表' : '裏');
      recent = recent.slice(0, 20);
      save();
      flip = null;
      sound.play('coin');
    }
    K.invalidate();
  }
  K.frame(draw);
}

function draw(w, h, th) {
  var r = Math.min(w, h - 160) * 0.32, cx = w / 2, cy = 30 + r;
  var angle = 0, lift = 0, face = side;
  if (flip) {
    var p = flip.t / FLIP_TIME, e = 1 - Math.pow(1 - p, 2);
    angle = e * flip.half * Math.PI;
    lift = Math.sin(p * Math.PI) * r * 0.6;
    face = Coin.faceAt(flip.start, angle);
  }
  var sy = Math.max(0.04, Math.abs(Math.cos(angle)));
  ctx.save();
  ctx.translate(cx, cy - lift);
  ctx.scale(1, sy);
  ctx.fillStyle = face === 0 ? '#d4a017' : '#a8a9ad';
  ctx.beginPath(); ctx.arc(0, 0, r, 0, Math.PI * 2); ctx.fill();
  ctx.fillStyle = face === 0 ? '#f2c94c' : '#d1d3d6';
  ctx.beginPath(); ctx.arc(0, 0, r * 0.82, 0, Math.PI * 2); ctx.fill();
  ctx.fillStyle = face === 0 ? '#8a6510' : '#5f6368';
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  ctx.font = K.font(r * 0.7, true);
  ctx.fillText(face === 0 ? '表' : '裏', 0, 0);
  ctx.restore();
  var y = cy + r + 24;
  ctx.fillStyle = th.fg;
  ctx.textAlign = 'center';
  ctx.textBaseline = 'top';
  K.fitText(flip ? '…' : (counts[0] + counts[1] ? (side === 0 ? '表' : '裏') : 'タップで投げる'), w / 2, y, w - 24, 26, true);
  y += 40;
  var total = counts[0] + counts[1];
  ctx.fillStyle = th.sub;
  K.fitText('表 ' + counts[0] + ' 回 / 裏 ' + counts[1] + ' 回' + (total ? '(表 ' + Math.round(counts[0] / total * 100) + '%)' : ''), w / 2, y, w - 24, 15, false);
  y += 26;
  if (recent.length) y += K.paragraph('最近: ' + recent.join(' '), 12, y, w - 24, 13, th.sub);
  return y + 20;
}
