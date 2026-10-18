// 地点を指すコンパス: 登録した地点の方角と距離(app.places)と、端末の方位(app.sensors.heading)を使う。方位のセンサーは、このツールを開いている間だけ動く。
var places = null, target = '', sensorStarted = false;
var heading = null, shown = 0;

function setup() {
  places = app.places;
  sensorStarted = app.sensors.start('heading');
  updateChoices();
}

function onData(kind) {
  if (kind === 'places') {
    places = app.places;
    updateChoices();
  }
  if (kind === 'sensors') {
    var h = app.sensors.heading;
    heading = h ? h.degrees : null;
  }
}

function onInput(name, value) {
  if (name === 'target') target = value;
}

function onStop() {
  app.sensors.stop('heading');
}

function items() {
  if (!places) return [];
  return places.items.filter(function (p) { return !p.hidden; });
}

function labels(list) {
  var seen = {};
  return list.slice(0, 30).map(function (p) {
    var name = p.name || '名前なし';
    seen[name] = (seen[name] || 0) + 1;
    return seen[name] > 1 ? name + '(' + seen[name] + ')' : name;
  });
}

function updateChoices() {
  var list = items();
  if (!list.length) { ui.remove('target'); return; }
  var names = labels(list);
  if (names.indexOf(target) < 0) target = names[0];
  ui.choice('target', { label: '地点', options: names, value: target });
}

function selected() {
  var list = items(), names = labels(list), i = names.indexOf(target);
  return i >= 0 ? list[i] : list[0];
}

function distanceText(m) {
  if (m === null) return '';
  return m < 1000 ? Math.round(m) + 'm' : (m / 1000).toFixed(m < 10000 ? 2 : 1) + 'km';
}

function frame() {
  var dark = screen.dark, W = screen.width, H = screen.height;
  var fg = dark ? '#f2f2f7' : '#1c1c1e', sub = dark ? '#98989f' : '#6c6c70';
  if (heading !== null) {
    var diff = ((heading - shown + 540) % 360) - 180;
    shown = (shown + diff * 0.2 + 360) % 360;
  }
  ctx.fillStyle = dark ? '#000000' : '#ffffff';
  ctx.fillRect(0, 0, W, H);
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  var cx = W / 2, cy = Math.min(H * 0.42, W / 2 + 20), r = Math.min(W, H) * 0.36;
  var rot = heading === null ? 0 : -shown * Math.PI / 180;

  ctx.save();
  ctx.translate(cx, cy);
  ctx.rotate(rot);
  ctx.strokeStyle = sub;
  ctx.lineWidth = 2;
  ctx.beginPath();
  ctx.arc(0, 0, r, 0, Math.PI * 2);
  ctx.stroke();
  for (var a = 0; a < 360; a += 15) {
    var len = a % 90 === 0 ? 14 : a % 45 === 0 ? 9 : 5;
    var t = a * Math.PI / 180;
    ctx.beginPath();
    ctx.moveTo(Math.sin(t) * r, -Math.cos(t) * r);
    ctx.lineTo(Math.sin(t) * (r - len), -Math.cos(t) * (r - len));
    ctx.stroke();
  }
  var marks = [['北', 0], ['東', 90], ['南', 180], ['西', 270]];
  ctx.font = 'bold 16px sans-serif';
  for (var i = 0; i < marks.length; i++) {
    var m = marks[i][1] * Math.PI / 180;
    ctx.fillStyle = marks[i][1] === 0 ? '#ff3b30' : fg;
    ctx.save();
    ctx.translate(Math.sin(m) * (r - 30), -Math.cos(m) * (r - 30));
    ctx.rotate(-rot);
    ctx.fillText(marks[i][0], 0, 0);
    ctx.restore();
  }
  var place = selected();
  if (place && place.bearing !== null) {
    var b = place.bearing * Math.PI / 180;
    ctx.rotate(b);
    ctx.fillStyle = place.color;
    ctx.beginPath();
    ctx.moveTo(0, -r + 18);
    ctx.lineTo(12, -r + 44);
    ctx.lineTo(4, -r + 44);
    ctx.lineTo(4, 0);
    ctx.lineTo(-4, 0);
    ctx.lineTo(-4, -r + 44);
    ctx.lineTo(-12, -r + 44);
    ctx.closePath();
    ctx.fill();
  }
  ctx.restore();

  ctx.fillStyle = fg;
  ctx.beginPath();
  ctx.moveTo(cx, cy - r - 14);
  ctx.lineTo(cx - 7, cy - r - 2);
  ctx.lineTo(cx + 7, cy - r - 2);
  ctx.closePath();
  ctx.fill();

  var y = cy + r + 30;
  if (!places) {
    ctx.fillStyle = sub;
    ctx.font = '14px sans-serif';
    ctx.fillText(app.permissions && app.permissions.places ? '地点のデータがありません' : '「地点」のデータを許可していません', cx, y);
    return;
  }
  if (!place) {
    ctx.fillStyle = sub;
    ctx.font = '14px sans-serif';
    ctx.fillText('スコープの「地点」で登録すると、ここに出ます', cx, y);
    return;
  }
  ctx.fillStyle = fg;
  ctx.font = 'bold 20px sans-serif';
  ctx.fillText(place.name, cx, y);
  ctx.font = '15px sans-serif';
  if (place.bearing === null) {
    ctx.fillStyle = sub;
    ctx.fillText('現在地が分からないため、方角を出せません', cx, y + 26);
  } else {
    var line = place.compass + ' ' + Math.round(place.bearing) + '°  ' + distanceText(place.distance);
    if (place.heightDifference !== null) line += '  ' + (place.heightDifference >= 0 ? '↑' : '↓') + Math.abs(Math.round(place.heightDifference)) + 'm';
    ctx.fillText(line, cx, y + 26);
  }
  ctx.fillStyle = sub;
  ctx.font = '13px sans-serif';
  var note = !sensorStarted ? 'センサーを許可していないため、北を上にしています'
           : heading === null ? '方位を測っています(北を上にしています)'
           : '向いている方角 ' + Math.round(shown) + '°';
  ctx.fillText(note, cx, y + 50);
}
