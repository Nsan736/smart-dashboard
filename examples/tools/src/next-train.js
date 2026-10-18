// 登録した駅の次の電車のカウントダウン: 保存した時刻表から作った次の発車(app.trains)を読むだけで、通信はしない。
var trains = null, calendar = null, dirty = true, lastKey = '';

function setup() {
  trains = app.trains;
  calendar = app.calendar;
}

function onData(kind) {
  if (kind === 'trains') trains = app.trains;
  if (kind === 'calendar') calendar = app.calendar;
  dirty = true;
}

function colors() {
  return screen.dark
    ? { bg: '#000000', fg: '#f2f2f7', sub: '#98989f', card: '#1c1c1e', accent: '#30d158', warn: '#ff9f0a' }
    : { bg: '#f2f2f7', fg: '#1c1c1e', sub: '#6c6c70', card: '#ffffff', accent: '#248a3d', warn: '#c93400' };
}

function two(n) { return n < 10 ? '0' + n : String(n); }

function clock(ms) {
  var d = new Date(ms);
  return d.getHours() + ':' + two(d.getMinutes());
}

function countdown(ms) {
  var s = Math.floor((ms - Date.now()) / 1000);
  if (s < 30) return 'まもなく';
  return Math.floor(s / 60) + ':' + two(s % 60);
}

function message(c, title, body) {
  ctx.fillStyle = c.fg;
  ctx.font = 'bold 18px sans-serif';
  ctx.fillText(title, 16, 24);
  ctx.fillStyle = c.sub;
  ctx.font = '14px sans-serif';
  var y = 54;
  for (var i = 0; i < body.length; i++) { ctx.fillText(body[i], 16, y); y += 20; }
}

function frame() {
  var key = Math.floor(Date.now() / 1000) + ':' + screen.width + 'x' + screen.height + (screen.dark ? 'd' : 'l');
  if (key === lastKey && !dirty) return;
  lastKey = key;
  dirty = false;
  draw();
}

function draw() {
  var c = colors(), W = screen.width, H = screen.height;
  ctx.fillStyle = c.bg;
  ctx.fillRect(0, 0, W, H);
  ctx.textAlign = 'left';
  ctx.textBaseline = 'top';
  if (!trains) {
    var allowed = app.permissions && app.permissions.trains;
    message(c, '電車のデータがありません', allowed ? ['移動タブで駅を登録すると、ここに出ます。'] : ['「電車」のデータを許可していません。', 'ツールの画面の「その他」から変えられます。']);
    return;
  }
  var head = '今日のダイヤ: ' + trains.dayTypeLabel;
  if (calendar && calendar.holiday) head += '(' + calendar.holiday + ')';
  ctx.fillStyle = c.sub;
  ctx.font = '13px sans-serif';
  ctx.fillText(head, 16, 12);

  var boards = trains.departures;
  if (!boards.length) {
    message(c, '登録した駅がありません', ['移動タブの設定で駅を登録し、', '時刻表を保存すると、ここに出ます。']);
    return;
  }
  var status = {};
  trains.lines.forEach(function (line) { status[line.id] = line; });
  var y = 36, cardHeight = 132;
  for (var i = 0; i < boards.length && y + cardHeight <= H; i++) {
    var board = boards[i];
    var upcoming = board.trains.filter(function (t) { return t.time > Date.now() - 20000; });
    ctx.fillStyle = c.card;
    ctx.fillRect(12, y, W - 24, cardHeight - 10);
    ctx.fillStyle = c.fg;
    ctx.font = 'bold 15px sans-serif';
    ctx.fillText(board.station + '(' + board.direction + ')', 24, y + 10);
    var line = status[board.railwayID];
    ctx.font = '12px sans-serif';
    if (line && line.status !== 'normal' && line.status !== 'unknown') {
      ctx.fillStyle = c.warn;
      ctx.fillText(board.railway + ': ' + line.statusLabel, 24, y + 30);
    } else {
      ctx.fillStyle = c.sub;
      ctx.fillText(board.railway, 24, y + 30);
    }
    if (!upcoming.length) {
      ctx.fillStyle = c.sub;
      ctx.font = '14px sans-serif';
      ctx.fillText('この先の電車は、まだありません', 24, y + 56);
    } else {
      var first = upcoming[0];
      ctx.fillStyle = c.accent;
      ctx.font = 'bold 40px sans-serif';
      ctx.fillText(countdown(first.time), 24, y + 48);
      ctx.fillStyle = c.fg;
      ctx.font = '14px sans-serif';
      ctx.textAlign = 'right';
      ctx.fillText(clock(first.time) + '発', W - 24, y + 52);
      ctx.fillText((first.type || '') + ' ' + (first.destination ? first.destination + '行' : ''), W - 24, y + 72);
      ctx.textAlign = 'left';
      ctx.fillStyle = c.sub;
      ctx.font = '13px sans-serif';
      var rest = upcoming.slice(1, 3).map(function (t) { return clock(t.time) + ' ' + (t.type || '') + (t.destination ? ' ' + t.destination : ''); });
      if (rest.length) ctx.fillText('次: ' + rest.join('  /  '), 24, y + 98);
    }
    y += cardHeight;
  }
}
