// 的あてゲーム: 30秒で、出てくる的をタップする。最高点は保存領域(storage)に残す。効果音と振動。
var ROUND = 30;
var targets = [];
var effects = [];
var score = 0;
var best = 0;
var timeLeft = 0;
var playing = false;
var spawn = 0;

function setup() {
  best = storage.get('best') || 0;
}

function start() {
  targets = [];
  effects = [];
  score = 0;
  timeLeft = ROUND;
  playing = true;
  spawn = 0;
  sound.play('beep');
}

function onInput(name) {
  if (name === 'start') start();
}

function onTouch(e) {
  if (e.type !== 'down') return;
  if (!playing) { start(); return; }
  for (var i = targets.length - 1; i >= 0; i--) {
    var tg = targets[i], dx = e.x - tg.x, dy = e.y - tg.y;
    if (dx * dx + dy * dy <= tg.r * tg.r) {
      var points = tg.r < 24 ? 3 : 1;
      score += points;
      effects.push({ x: tg.x, y: tg.y, age: 0, text: '+' + points });
      targets.splice(i, 1);
      sound.play('coin');
      haptic('light');
      return;
    }
  }
  sound.play('click');
}

function update(dt, w, h) {
  timeLeft -= dt;
  spawn -= dt;
  if (spawn <= 0 && targets.length < 6) {
    spawn = random.range(0.35, 0.8);
    var r = random.range(18, 40);
    targets.push({ x: random.range(r, w - r), y: random.range(60 + r, h - r), r: r, life: random.range(1.2, 2.2), age: 0 });
  }
  for (var i = targets.length - 1; i >= 0; i--) {
    targets[i].age += dt;
    if (targets[i].age >= targets[i].life) targets.splice(i, 1);
  }
  if (timeLeft <= 0) {
    playing = false;
    targets = [];
    if (score > best) {
      best = score;
      storage.set('best', best);
      sound.play('success');
      haptic('success');
    } else {
      sound.play('failure');
    }
  }
}

function frame(t, dt) {
  var w = screen.width, h = screen.height;
  if (playing) update(dt, w, h);
  ctx.fillStyle = screen.dark ? '#101820' : '#eef4f8';
  ctx.fillRect(0, 0, w, h);
  for (var j = 0; j < targets.length; j++) {
    var g = targets[j];
    ctx.globalAlpha = Math.min(1, (1 - g.age / g.life) * 3);
    ctx.fillStyle = '#e63946';
    ctx.beginPath(); ctx.arc(g.x, g.y, g.r, 0, Math.PI * 2); ctx.fill();
    ctx.fillStyle = '#ffffff';
    ctx.beginPath(); ctx.arc(g.x, g.y, g.r * 0.62, 0, Math.PI * 2); ctx.fill();
    ctx.fillStyle = '#e63946';
    ctx.beginPath(); ctx.arc(g.x, g.y, g.r * 0.28, 0, Math.PI * 2); ctx.fill();
  }
  ctx.globalAlpha = 1;
  ctx.font = 'bold 20px sans-serif';
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  for (var m = effects.length - 1; m >= 0; m--) {
    var fx = effects[m];
    fx.age += dt;
    if (fx.age > 0.6) { effects.splice(m, 1); continue; }
    ctx.globalAlpha = 1 - fx.age / 0.6;
    ctx.fillStyle = '#2a9d8f';
    ctx.fillText(fx.text, fx.x, fx.y - fx.age * 40);
  }
  ctx.globalAlpha = 1;
  ctx.fillStyle = screen.dark ? '#eeeeee' : '#222222';
  ctx.font = 'bold 18px sans-serif';
  ctx.textBaseline = 'top';
  ctx.textAlign = 'left';
  ctx.fillText('点 ' + score, 12, 12);
  ctx.textAlign = 'right';
  ctx.fillText(playing ? '残り ' + Math.ceil(timeLeft) + '秒' : '最高 ' + best, w - 12, 12);
  if (!playing) {
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.font = 'bold 22px sans-serif';
    ctx.fillText('タップで始める(' + ROUND + '秒)', w / 2, h / 2);
    ctx.font = '14px sans-serif';
    ctx.fillText('小さい的は3点', w / 2, h / 2 + 30);
  }
}
