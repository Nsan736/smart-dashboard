// 花火: パーティクル(火花は400個まで)、タップで打ち上げ、効果音と振動。
var rockets = [];
var sparks = [];
var timer = 0;

function launch(x, y) {
  rockets.push({ x: x, y: screen.height, ty: y, vy: -Math.max(260, (screen.height - y) * 1.6), hue: random.int(0, 359) });
  sound.play('jump');
}

function burst(x, y, hue) {
  var n = 60;
  for (var i = 0; i < n; i++) {
    if (sparks.length >= 400) sparks.shift();
    var a = (i / n) * Math.PI * 2 + random.range(-0.05, 0.05);
    var sp = random.range(60, 180);
    sparks.push({ x: x, y: y, vx: Math.cos(a) * sp, vy: Math.sin(a) * sp, life: random.range(0.9, 1.6), age: 0, hue: hue + random.int(-20, 20) });
  }
  sound.play('pop');
  haptic('light');
}

function onTouch(e) {
  if (e.type === 'down') launch(e.x, e.y);
}

function frame(t, dt) {
  var w = screen.width, h = screen.height;
  ctx.fillStyle = '#05060f';
  ctx.fillRect(0, 0, w, h);
  timer -= dt;
  if (timer <= 0) {
    timer = random.range(0.9, 1.8);
    launch(random.range(w * 0.2, w * 0.8), random.range(h * 0.15, h * 0.45));
  }
  for (var i = rockets.length - 1; i >= 0; i--) {
    var r = rockets[i];
    r.y += r.vy * dt;
    ctx.fillStyle = '#ffffff';
    ctx.fillRect(r.x - 1.5, r.y, 3, 8);
    if (r.y <= r.ty) {
      burst(r.x, r.ty, r.hue);
      rockets.splice(i, 1);
    }
  }
  for (var j = sparks.length - 1; j >= 0; j--) {
    var s = sparks[j];
    s.age += dt;
    if (s.age >= s.life) { sparks.splice(j, 1); continue; }
    s.vy += 90 * dt;
    s.vx *= 0.985;
    s.vy *= 0.985;
    s.x += s.vx * dt;
    s.y += s.vy * dt;
    ctx.globalAlpha = 1 - s.age / s.life;
    ctx.fillStyle = 'hsl(' + s.hue + ', 100%, 65%)';
    ctx.fillRect(s.x - 1.5, s.y - 1.5, 3, 3);
  }
  ctx.globalAlpha = 1;
}
