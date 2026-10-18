// 気圧の小さなグラフ: 端末で記録した気圧(実線)と予報(点線)を、前後24時間で描く(app.pressure)。データが変わったときだけ描き直す。
var pressure = null, dirty = true, lastKey = '', lastMinute = -1;

function setup() { pressure = app.pressure; }

function onData(kind) {
  if (kind === 'pressure') { pressure = app.pressure; dirty = true; }
}

function frame() {
  var key = screen.width + 'x' + screen.height + (screen.dark ? 'd' : 'l');
  var minute = Math.floor(Date.now() / 60000);
  if (key !== lastKey || minute !== lastMinute) { lastKey = key; lastMinute = minute; dirty = true; }
  if (!dirty) return;
  dirty = false;
  draw();
}

function draw() {
  var dark = screen.dark, W = screen.width, H = screen.height;
  var fg = dark ? '#f2f2f7' : '#1c1c1e', sub = dark ? '#98989f' : '#6c6c70', grid = dark ? '#2c2c2e' : '#e5e5ea';
  var blue = dark ? '#0a84ff' : '#007aff';
  ctx.fillStyle = dark ? '#000000' : '#ffffff';
  ctx.fillRect(0, 0, W, H);
  ctx.textAlign = 'left';
  ctx.textBaseline = 'top';
  if (!pressure) {
    ctx.fillStyle = sub;
    ctx.font = '15px sans-serif';
    ctx.fillText(app.permissions && app.permissions.pressure ? '気圧のデータがまだありません' : '「気圧」のデータを許可していません', 16, 24);
    return;
  }
  ctx.fillStyle = fg;
  ctx.font = 'bold 40px sans-serif';
  ctx.fillText(pressure.latest === null ? '--' : pressure.latest.toFixed(1), 16, 12);
  var w = ctx.measureText(pressure.latest === null ? '--' : pressure.latest.toFixed(1)).width;
  ctx.font = '16px sans-serif';
  ctx.fillText('hPa', 22 + w, 32);
  var change = pressure.change3h;
  if (change) {
    ctx.fillStyle = change.delta <= -3 ? '#ff9500' : sub;
    ctx.font = 'bold 15px sans-serif';
    ctx.fillText(change.text, 16, 62);
  }

  var now = Date.now(), from = now - 24 * 3600000, to = now + 24 * 3600000;
  var measured = pressure.measured.filter(function (p) { return p.time >= from && p.hPa !== null; });
  var forecast = pressure.forecast.filter(function (p) { return p.time >= from && p.time <= to && p.hPa !== null; });
  var values = measured.concat(forecast).map(function (p) { return p.hPa; });
  if (!values.length) return;
  var lo = Math.min.apply(null, values), hi = Math.max.apply(null, values);
  var mid = (lo + hi) / 2, span = Math.max(hi - lo + 2, 6);
  lo = Math.floor(mid - span / 2); hi = Math.ceil(mid + span / 2);
  var left = 44, right = W - 12, top = 92, bottom = H - 26;
  if (bottom - top < 60) return;
  function px(t) { return left + (t - from) / (to - from) * (right - left); }
  function py(v) { return bottom - (v - lo) / (hi - lo) * (bottom - top); }

  ctx.font = '11px sans-serif';
  ctx.textAlign = 'right';
  ctx.textBaseline = 'middle';
  var stepHPa = hi - lo > 12 ? 4 : 2;
  for (var v = Math.ceil(lo / stepHPa) * stepHPa; v <= hi; v += stepHPa) {
    ctx.strokeStyle = grid;
    ctx.lineWidth = 1;
    ctx.beginPath(); ctx.moveTo(left, py(v)); ctx.lineTo(right, py(v)); ctx.stroke();
    ctx.fillStyle = sub;
    ctx.fillText(String(v), left - 6, py(v));
  }
  ctx.strokeStyle = sub;
  ctx.setLineDash([3, 3]);
  ctx.beginPath(); ctx.moveTo(px(now), top); ctx.lineTo(px(now), bottom); ctx.stroke();
  ctx.setLineDash([]);
  ctx.textAlign = 'center';
  ctx.textBaseline = 'top';
  ctx.fillStyle = sub;
  ctx.fillText('24時間前', left + 24, bottom + 6);
  ctx.fillText('今', px(now), bottom + 6);
  ctx.fillText('24時間後', right - 24, bottom + 6);

  function line(points, color, width, dash) {
    if (points.length < 2) return;
    ctx.strokeStyle = color;
    ctx.lineWidth = width;
    ctx.setLineDash(dash);
    ctx.beginPath();
    ctx.moveTo(px(points[0].time), py(points[0].hPa));
    for (var i = 1; i < points.length; i++) ctx.lineTo(px(points[i].time), py(points[i].hPa));
    ctx.stroke();
    ctx.setLineDash([]);
  }
  line(forecast.filter(function (p) { return p.time >= now - 3600000; }), sub, 2, [5, 4]);
  line(measured, blue, 2.5, []);
}
