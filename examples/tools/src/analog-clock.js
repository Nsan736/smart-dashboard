// アナログ時計: 変形(translate・rotate)と文字の例。1秒に15コマで十分なので、fps は15にしている。
function hand(angle, length, width, color) {
  ctx.save();
  ctx.rotate(angle);
  ctx.strokeStyle = color;
  ctx.lineWidth = width;
  ctx.lineCap = 'round';
  ctx.beginPath();
  ctx.moveTo(0, length * 0.15);
  ctx.lineTo(0, -length);
  ctx.stroke();
  ctx.restore();
}

function frame(t, dt) {
  var w = screen.width, h = screen.height, r = Math.min(w, h) * 0.42;
  var ink = screen.dark ? '#dddddd' : '#222222';
  ctx.fillStyle = screen.dark ? '#000000' : '#ffffff';
  ctx.fillRect(0, 0, w, h);
  ctx.save();
  ctx.translate(w / 2, h / 2);
  ctx.strokeStyle = ink;
  ctx.lineWidth = 4;
  ctx.beginPath();
  ctx.arc(0, 0, r, 0, Math.PI * 2);
  ctx.stroke();
  ctx.lineCap = 'round';
  for (var i = 0; i < 60; i++) {
    var a = i * Math.PI / 30;
    var major = i % 5 === 0;
    var inner = major ? 0.85 : 0.92;
    ctx.lineWidth = major ? 4 : 1.5;
    ctx.beginPath();
    ctx.moveTo(Math.sin(a) * r * inner, -Math.cos(a) * r * inner);
    ctx.lineTo(Math.sin(a) * r * 0.97, -Math.cos(a) * r * 0.97);
    ctx.stroke();
  }
  ctx.fillStyle = ink;
  ctx.font = 'bold ' + Math.round(r * 0.16) + 'px sans-serif';
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  for (var n = 1; n <= 12; n++) {
    var b = n * Math.PI / 6;
    ctx.fillText(String(n), Math.sin(b) * r * 0.7, -Math.cos(b) * r * 0.7);
  }
  var now = new Date();
  var s = now.getSeconds() + now.getMilliseconds() / 1000;
  var m = now.getMinutes() + s / 60;
  var hr = (now.getHours() % 12) + m / 60;
  hand(hr * Math.PI / 6, r * 0.5, 8, ink);
  hand(m * Math.PI / 30, r * 0.75, 5, ink);
  hand(s * Math.PI / 30, r * 0.85, 2, 'crimson');
  ctx.fillStyle = 'crimson';
  ctx.beginPath();
  ctx.arc(0, 0, 6, 0, Math.PI * 2);
  ctx.fill();
  ctx.restore();
}
