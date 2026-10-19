// あみだくじ(JavaScript 版)。横線は、同じ段で隣り合わず、どの間にも1本以上。上の名前をタップすると、道を少しずつ描く。
// 下の結果は、たどり着くまで隠しておく。
var ROWS = 12;
var DEFAULT_NAMES = 'A\nB\nC\nD';
var DEFAULT_PRIZES = '当たり\nはずれ\nはずれ\nはずれ';
var namesText = DEFAULT_NAMES, prizesText = DEFAULT_PRIZES;
var game = null;
var traced = [];
var anim = null;

var Amida = {
  // rungs[段][間] が true なら、その段の 間 と 間+1 の縦線をつなぐ
  make: function (n, rows, rnd) {
    var rungs = [];
    for (var r = 0; r < rows; r++) {
      var row = [];
      for (var g = 0; g < n - 1; g++) row.push(!(g > 0 && row[g - 1]) && rnd() < 0.4);
      rungs.push(row);
    }
    // どの間にも1本以上(置ける段がなければ段を足す)
    for (var gap = 0; gap < n - 1; gap++) {
      var has = rungs.some(function (row) { return row[gap]; });
      if (has) continue;
      var free = [];
      rungs.forEach(function (row, i) { if (!(gap > 0 && row[gap - 1]) && !row[gap + 1]) free.push(i); });
      if (free.length) rungs[free[Math.floor(rnd() * free.length)]][gap] = true;
      else { var extra = []; for (var k = 0; k < n - 1; k++) extra.push(k === gap); rungs.push(extra); }
    }
    return rungs;
  },
  // start の列からたどった、通る列の一覧(段ごと)と、たどり着く列
  trace: function (rungs, start) {
    var col = start, cols = [col];
    rungs.forEach(function (row) {
      if (row[col]) col += 1;
      else if (col > 0 && row[col - 1]) col -= 1;
      cols.push(col);
    });
    return { end: col, cols: cols };
  },
  // 同じ行き先がないか(テスト用)
  isPermutation: function (rungs, n) {
    var seen = {};
    for (var i = 0; i < n; i++) { var e = Amida.trace(rungs, i).end; if (seen[e]) return false; seen[e] = true; }
    return true;
  }
};

function setup() {
  var saved = storage.get('amida') || {};
  namesText = typeof saved.namesText === 'string' ? saved.namesText : DEFAULT_NAMES;
  prizesText = typeof saved.prizesText === 'string' ? saved.prizesText : DEFAULT_PRIZES;
  game = saved.game || null;
  traced = saved.traced || [];
  ui.text('names', { label: '名前(上。1行に1人、2〜10人)', value: namesText, multiline: true });
  ui.text('prizes', { label: '結果(下。足りない分は「はずれ」)', value: prizesText, multiline: true });
  ui.button('make', 'くじを作る');
  ui.button('all', 'すべての結果を見る');
  if (!game) newGame();
}
function save() { storage.set('amida', { namesText: namesText, prizesText: prizesText, game: game, traced: traced }); }

function newGame() {
  var names = K.splitNames(namesText).slice(0, 10);
  if (names.length < 2) { game = null; return; }
  var prizes = K.splitNames(prizesText);
  while (prizes.length < names.length) prizes.push('はずれ');
  prizes = prizes.slice(0, names.length);
  game = { names: names, prizes: prizes, rungs: Amida.make(names.length, ROWS, function () { return random.next(); }) };
  traced = [];
  anim = null;
}

function onInput(name, value) {
  if (name === 'names') namesText = value;
  else if (name === 'prizes') prizesText = value;
  else if (name === 'make') { newGame(); sound.play('pop'); }
  else if (name === 'all' && game) { traced = game.names.map(function (s, i) { return i; }); anim = null; }
  save();
  K.invalidate();
}

function onTouch(e) {
  var b = K.hit(K.touch(e));
  if (!b || b.id !== 'name' || !game || anim) return;
  if (traced.indexOf(b.data) >= 0) return;
  anim = { col: b.data, p: 0 };
  sound.play('click');
}

function frame(t, dt) {
  if (anim) {
    anim.p += dt / 2.0;
    if (anim.p >= 1) { traced.push(anim.col); anim = null; save(); sound.play('success'); haptic('success'); }
    K.invalidate();
  }
  K.frame(draw);
}

function points(colsList, left, gapW, top, rowH) {
  var pts = [[left + colsList[0] * gapW, top]];
  for (var r = 0; r < colsList.length - 1; r++) {
    var y = top + (r + 0.5) * rowH;
    pts.push([left + colsList[r] * gapW, y]);
    if (colsList[r + 1] !== colsList[r]) pts.push([left + colsList[r + 1] * gapW, y]);
  }
  pts.push([left + colsList[colsList.length - 1] * gapW, top + (colsList.length - 1) * rowH]);
  return pts;
}

function strokePartial(pts, p) {
  var total = 0, i;
  for (i = 1; i < pts.length; i++) total += Math.abs(pts[i][0] - pts[i - 1][0]) + Math.abs(pts[i][1] - pts[i - 1][1]);
  var left = total * p;
  ctx.beginPath();
  ctx.moveTo(pts[0][0], pts[0][1]);
  for (i = 1; i < pts.length && left > 0; i++) {
    var len = Math.abs(pts[i][0] - pts[i - 1][0]) + Math.abs(pts[i][1] - pts[i - 1][1]), f = Math.min(1, left / len);
    ctx.lineTo(pts[i - 1][0] + (pts[i][0] - pts[i - 1][0]) * f, pts[i - 1][1] + (pts[i][1] - pts[i - 1][1]) * f);
    left -= len;
  }
  ctx.stroke();
}

function draw(w, h, th) {
  if (!game) { K.paragraph('名前を2人以上入れて「くじを作る」を押してください。', 12, 16, w - 24, 15, th.sub); return 80; }
  var n = game.names.length, gapW = (w - 40) / Math.max(1, n - 1), left = 20;
  if (n === 1) left = w / 2;
  var top = 60, rows = game.rungs.length, rowH = Math.max(22, Math.min(36, (h - 150) / rows)), bottom = top + rows * rowH;
  ctx.strokeStyle = th.line;
  ctx.lineWidth = 3;
  ctx.beginPath();
  for (var c = 0; c < n; c++) { ctx.moveTo(left + c * gapW, top); ctx.lineTo(left + c * gapW, bottom); }
  game.rungs.forEach(function (row, r) {
    row.forEach(function (on, g) { if (on) { var y = top + (r + 0.5) * rowH; ctx.moveTo(left + g * gapW, y); ctx.lineTo(left + (g + 1) * gapW, y); } });
  });
  ctx.stroke();
  var ends = {};
  ctx.lineWidth = 5;
  ctx.lineJoin = 'round';
  traced.concat(anim ? [anim.col] : []).forEach(function (col) {
    var tr = Amida.trace(game.rungs, col);
    ctx.strokeStyle = K.palette[col % K.palette.length];
    strokePartial(points(tr.cols, left, gapW, top, rowH), anim && anim.col === col ? anim.p : 1);
    if (!(anim && anim.col === col)) ends[tr.end] = col;
  });
  ctx.lineWidth = 1;
  var labelW = Math.min(gapW - 4, 90);
  for (var i = 0; i < n; i++) {
    var x = left + i * gapW;
    ctx.fillStyle = traced.indexOf(i) >= 0 ? K.palette[i % K.palette.length] : th.card2;
    K.roundRect(x - labelW / 2, 12, labelW, 40, 8);
    ctx.fill();
    ctx.fillStyle = traced.indexOf(i) >= 0 ? '#ffffff' : th.fg;
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    K.fitText(game.names[i], x, 32, labelW - 6, 15, true);
    K.area('name', x - labelW / 2, 12, labelW, 40, i);
    var shown = ends[i] !== undefined;
    ctx.fillStyle = shown ? K.palette[ends[i] % K.palette.length] : th.card2;
    K.roundRect(x - labelW / 2, bottom + 8, labelW, 40, 8);
    ctx.fill();
    ctx.fillStyle = shown ? '#ffffff' : th.sub;
    K.fitText(shown ? game.prizes[i] : '?', x, bottom + 28, labelW - 6, 15, true);
  }
  return bottom + 70;
}
