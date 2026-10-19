// スコアボード(JavaScript 版)。2〜4チーム。チームの枠の上半分をタップで+1、下半分で−1。「セットを終える」で、1位のチームにセットを1つ(同点なら付けない)。
var board = null;

var Score = {
  make: function (count) {
    var teams = [];
    for (var i = 0; i < count; i++) teams.push({ name: 'チーム' + String.fromCharCode(65 + i), points: 0, sets: 0 });
    return { teams: teams, history: [] };
  },
  add: function (b, i, delta) { var t = b.teams[i]; t.points = Math.max(0, Math.min(999, t.points + delta)); return t.points; },
  // セットを終える。1位が1チームだけなら、そのチームにセットを足して番号を返す(同点なら -1)。点は0に戻す
  finishSet: function (b) {
    var best = Math.max.apply(null, b.teams.map(function (t) { return t.points; }));
    var tops = b.teams.filter(function (t) { return t.points === best; });
    var winner = tops.length === 1 && best > 0 ? b.teams.indexOf(tops[0]) : -1;
    b.history.push(b.teams.map(function (t) { return t.points; }));
    if (winner >= 0) b.teams[winner].sets += 1;
    b.teams.forEach(function (t) { t.points = 0; });
    return winner;
  }
};

function setup() {
  board = storage.get('scoreboard') || Score.make(2);
  ui.choice('count', { label: 'チームの数', options: ['2', '3', '4'], value: String(board.teams.length) });
  ui.text('names', { label: 'チームの名前(カンマ区切り)', value: board.teams.map(function (t) { return t.name; }).join(', ') });
  ui.button('finish', 'セットを終える');
  ui.button('reset', 'すべて0に戻す');
  ui.toggle('awake', { label: '画面を消さない', value: true });
  screen.keepAwake(true);
}
function save() { storage.set('scoreboard', board); }

function onInput(name, value) {
  if (name === 'count') {
    var n = +value;
    if (n !== board.teams.length) {
      var next = Score.make(n);
      for (var i = 0; i < Math.min(n, board.teams.length); i++) next.teams[i].name = board.teams[i].name;
      board = next;
      ui.set('names', board.teams.map(function (t) { return t.name; }).join(', '));
    }
  } else if (name === 'names') {
    var list = String(value).split(/[,、，]/).map(function (s) { return s.trim(); });
    board.teams.forEach(function (t, i) { if (list[i]) t.name = list[i].slice(0, 12); });
  } else if (name === 'finish') {
    var winner = Score.finishSet(board);
    board.history = board.history.slice(-50);
    sound.play(winner >= 0 ? 'success' : 'beep');
  } else if (name === 'reset') {
    board.teams.forEach(function (t) { t.points = 0; t.sets = 0; });
    board.history = [];
  } else if (name === 'awake') { screen.keepAwake(value); return; }
  save();
  K.invalidate();
}

function onTouch(e) {
  var p = K.touch(e), b = K.hit(p);
  if (!b || b.id !== 'team') return;
  var up = p.y < b.y + b.h / 2;
  Score.add(board, b.data, up ? 1 : -1);
  sound.play(up ? 'click' : 'pop');
  haptic('light');
  save();
  K.invalidate();
}
function frame() { K.frame(draw); }

function draw(w, h, th) {
  var n = board.teams.length, gap = 8, pad = 8;
  var cols = n === 3 && w < 500 ? 1 : (n === 4 && w < 500 ? 2 : n), rowsN = Math.ceil(n / cols);
  var hist = board.history.length ? 30 : 0;
  var cellW = (w - pad * 2 - gap * (cols - 1)) / cols, cellH = Math.max(110, (h - pad * 2 - gap * (rowsN - 1) - hist) / rowsN);
  board.teams.forEach(function (t, i) {
    var x = pad + (i % cols) * (cellW + gap), y = pad + Math.floor(i / cols) * (cellH + gap);
    ctx.fillStyle = K.palette[[0, 4, 3, 1][i]];
    K.roundRect(x, y, cellW, cellH, 14);
    ctx.fill();
    ctx.fillStyle = '#ffffff';
    ctx.textAlign = 'center';
    ctx.textBaseline = 'top';
    K.fitText(t.name + '  セット ' + t.sets, x + cellW / 2, y + 10, cellW - 16, 16, true);
    ctx.textBaseline = 'middle';
    K.fitText(String(t.points), x + cellW / 2, y + cellH / 2 + 8, cellW - 16, Math.min(cellH * 0.55, 120), true);
    ctx.globalAlpha = 0.6;
    K.fitText('+', x + cellW - 20, y + 30, 20, 18, true);
    K.fitText('−', x + cellW - 20, y + cellH - 18, 20, 18, true);
    ctx.globalAlpha = 1;
    K.area('team', x, y, cellW, cellH, i);
  });
  var bottom = pad + rowsN * (cellH + gap);
  if (hist) {
    ctx.fillStyle = th.sub;
    ctx.textAlign = 'left';
    ctx.textBaseline = 'middle';
    K.fitText('これまでのセット: ' + board.history.slice(-10).map(function (s) { return s.join('-'); }).join('  '), pad, bottom + 8, w - pad * 2, 13, false);
  }
  return Math.max(h, bottom + hist);
}
