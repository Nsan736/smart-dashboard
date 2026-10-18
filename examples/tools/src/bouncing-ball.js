// 跳ねるボール: スライダー(速さ)、ボタン(消す)、タップで足す。グラデーションの例。
var balls = [];
var speed = 200;

function add(x, y) {
  if (balls.length >= 30) balls.shift();
  var a = random.range(0, Math.PI * 2);
  balls.push({ x: x, y: y, vx: Math.cos(a), vy: Math.sin(a), r: random.range(12, 26), hue: random.int(0, 359) });
}

function setup() {
  for (var i = 0; i < 3; i++) add(random.range(40, screen.width - 40), random.range(40, screen.height - 40));
}

function onInput(name, value) {
  if (name === 'speed') speed = value;
  if (name === 'clear') balls = [];
}

function onTouch(e) {
  if (e.type === 'down') {
    add(e.x, e.y);
    sound.play('pop');
  }
}

function frame(t, dt) {
  var w = screen.width, h = screen.height;
  ctx.fillStyle = screen.dark ? '#111111' : '#f4f4f4';
  ctx.fillRect(0, 0, w, h);
  for (var i = 0; i < balls.length; i++) {
    var b = balls[i];
    b.x += b.vx * speed * dt;
    b.y += b.vy * speed * dt;
    if (b.x < b.r) { b.x = b.r; b.vx = Math.abs(b.vx); }
    if (b.x > w - b.r) { b.x = w - b.r; b.vx = -Math.abs(b.vx); }
    if (b.y < b.r) { b.y = b.r; b.vy = Math.abs(b.vy); }
    if (b.y > h - b.r) { b.y = h - b.r; b.vy = -Math.abs(b.vy); }
    var g = ctx.createRadialGradient(b.x - b.r * 0.3, b.y - b.r * 0.3, 2, b.x, b.y, b.r);
    g.addColorStop(0, 'hsl(' + b.hue + ', 90%, 75%)');
    g.addColorStop(1, 'hsl(' + b.hue + ', 80%, 45%)');
    ctx.fillStyle = g;
    ctx.beginPath();
    ctx.arc(b.x, b.y, b.r, 0, Math.PI * 2);
    ctx.fill();
  }
  ctx.fillStyle = screen.dark ? '#aaaaaa' : '#555555';
  ctx.font = '13px sans-serif';
  ctx.textAlign = 'left';
  ctx.textBaseline = 'top';
  ctx.fillText('タップでボールを足す(' + balls.length + '個)', 10, 10);
}
