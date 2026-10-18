// 自分好みの天気の表示: アプリが取得した天気(app.weather)と警報(app.warnings)を読むだけで、通信はしない。データが変わったときだけ描き直す。
var weather = null, warnings = null, hours = 24;
var dirty = true, lastKey = '', lastMinute = -1;

function setup() {
  weather = app.weather;
  warnings = app.warnings;
}

function onData(kind) {
  if (kind === 'weather') weather = app.weather;
  if (kind === 'warnings') warnings = app.warnings;
  dirty = true;
}

function onInput(name, value) {
  if (name === 'hours') {
    hours = parseInt(value, 10) || 24;
    dirty = true;
  }
}

function frame() {
  var key = screen.width + 'x' + screen.height + (screen.dark ? 'd' : 'l');
  var minute = Math.floor(Date.now() / 60000);
  if (key !== lastKey || minute !== lastMinute) { lastKey = key; lastMinute = minute; dirty = true; }
  if (!dirty) return;
  dirty = false;
  draw();
}

function colors() {
  return screen.dark
    ? { bg: '#000000', fg: '#f2f2f7', sub: '#98989f', grid: '#2c2c2e', temp: '#ff9f0a', rain: '#0a84ff' }
    : { bg: '#ffffff', fg: '#1c1c1e', sub: '#6c6c70', grid: '#e5e5ea', temp: '#ff8c00', rain: '#007aff' };
}

function ago(ms) {
  var m = Math.max(0, Math.round((Date.now() - ms) / 60000));
  if (m < 1) return 'たった今';
  if (m < 60) return m + '分前';
  if (m < 1440) return Math.floor(m / 60) + '時間前';
  return Math.floor(m / 1440) + '日前';
}

function wrap(text, x, y, width, lineHeight, maxLines) {
  var line = '', lines = 0;
  for (var i = 0; i < text.length; i++) {
    var next = line + text[i];
    if (line && ctx.measureText(next).width > width) {
      ctx.fillText(line, x, y + lines * lineHeight);
      lines++;
      line = text[i];
      if (lines >= maxLines) return lines;
    } else {
      line = next;
    }
  }
  if (line) { ctx.fillText(line, x, y + lines * lineHeight); lines++; }
  return lines;
}

function levelColor(level) {
  if (level >= 50) return '#000000';
  if (level >= 40) return '#a020f0';
  if (level >= 30) return '#ff3b30';
  return '#f5c400';
}

function draw() {
  var c = colors(), W = screen.width, H = screen.height;
  ctx.fillStyle = c.bg;
  ctx.fillRect(0, 0, W, H);
  ctx.textAlign = 'left';
  ctx.textBaseline = 'top';
  if (!weather) {
    ctx.fillStyle = c.fg;
    ctx.font = 'bold 18px sans-serif';
    ctx.fillText('天気のデータがありません', 16, 24);
    ctx.fillStyle = c.sub;
    ctx.font = '14px sans-serif';
    var allowed = app.permissions && app.permissions.weather;
    wrap(allowed ? '天気タブで取得すると、ここに出ます(このツールは通信しません)。'
                 : '「天気」のデータを許可していません。ツールの画面の「その他」→「データの許可」で変えられます。',
         16, 54, W - 32, 20, 4);
    return;
  }
  var now = weather.current;
  ctx.fillStyle = c.fg;
  ctx.font = 'bold 56px sans-serif';
  ctx.fillText(Math.round(now.temperature) + '°', 16, 12);
  var tempWidth = ctx.measureText(Math.round(now.temperature) + '°').width;
  ctx.font = 'bold 20px sans-serif';
  ctx.fillText(now.label, 24 + tempWidth, 22);
  ctx.font = '14px sans-serif';
  ctx.fillStyle = c.sub;
  ctx.fillText('体感 ' + Math.round(now.apparentTemperature) + '°', 24 + tempWidth, 50);
  ctx.fillText('湿度 ' + Math.round(now.humidity) + '%  風 ' + now.windSpeed + 'm/s', 16, 80);
  ctx.fillText((weather.place ? weather.place + '・' : '') + ago(weather.fetchedAt) + 'の情報', 16, 100);

  var y = 126;
  if (weather.rain && weather.rain.headline) {
    ctx.fillStyle = c.rain;
    ctx.font = 'bold 15px sans-serif';
    y += wrap(weather.rain.headline, 16, y, W - 32, 20, 2) * 20 + 4;
  }

  var items = warnings && warnings.items ? warnings.items : [];
  if (items.length) {
    ctx.font = 'bold 13px sans-serif';
    var x = 16;
    for (var i = 0; i < items.length && i < 8; i++) {
      var label = items[i].name;
      var w = ctx.measureText(label).width + 16;
      if (x + w > W - 16) { x = 16; y += 26; }
      ctx.fillStyle = levelColor(items[i].level);
      ctx.fillRect(x, y, w, 22);
      ctx.fillStyle = items[i].level >= 30 ? '#ffffff' : '#000000';
      ctx.fillText(label, x + 8, y + 4);
      x += w + 6;
    }
    y += 32;
  }

  var list = weather.hourly.filter(function (h) { return h.time > Date.now() - 3600000; }).slice(0, hours);
  var top = y + 8, bottom = H - 28, left = 16, right = W - 16;
  if (list.length < 2 || bottom - top < 80) return;
  var temps = list.map(function (h) { return h.temperature; }).filter(function (v) { return v !== null; });
  var lo = Math.floor(Math.min.apply(null, temps)) - 1, hi = Math.ceil(Math.max.apply(null, temps)) + 1;
  var step = (right - left) / (list.length - 1);
  function px(i) { return left + i * step; }
  function py(v) { return bottom - (v - lo) / (hi - lo) * (bottom - top); }

  ctx.strokeStyle = c.grid;
  ctx.lineWidth = 1;
  ctx.beginPath();
  ctx.moveTo(left, bottom); ctx.lineTo(right, bottom);
  ctx.stroke();

  ctx.fillStyle = c.rain;
  ctx.globalAlpha = 0.25;
  for (var j = 0; j < list.length; j++) {
    var p = list[j].precipitationProbability || 0;
    var bh = p / 100 * (bottom - top) * 0.6;
    ctx.fillRect(px(j) - step * 0.35, bottom - bh, step * 0.7, bh);
  }
  ctx.globalAlpha = 1;

  ctx.strokeStyle = c.temp;
  ctx.lineWidth = 2.5;
  ctx.beginPath();
  var started = false;
  for (var k = 0; k < list.length; k++) {
    if (list[k].temperature === null) continue;
    if (!started) { ctx.moveTo(px(k), py(list[k].temperature)); started = true; } else { ctx.lineTo(px(k), py(list[k].temperature)); }
  }
  ctx.stroke();

  var every = list.length > 30 ? 6 : list.length > 14 ? 3 : 2;
  ctx.font = '11px sans-serif';
  ctx.textAlign = 'center';
  for (var n = 0; n < list.length; n += every) {
    var d = new Date(list[n].time);
    ctx.fillStyle = c.sub;
    ctx.textBaseline = 'top';
    ctx.fillText(d.getHours() + '時', px(n), bottom + 6);
    if (list[n].temperature !== null) {
      ctx.fillStyle = c.fg;
      ctx.textBaseline = 'bottom';
      ctx.fillText(Math.round(list[n].temperature) + '°', px(n), py(list[n].temperature) - 4);
    }
  }
}
