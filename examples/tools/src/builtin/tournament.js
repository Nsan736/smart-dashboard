// トーナメント表(JavaScript 版)。2〜64人。並び順がシード順(先頭が第1シード)で、第1と第2シードは決勝まで当たらない。
// 不戦勝は最初から勝ち上がる。名前をタップで勝者にし、もう一度のタップで取り消す(その先の結果も取り消す)。
// 参加者は番号で持つので、同じ名前がいても区別できる。表はドラッグで動かし、右上のボタンで拡大・縮小。
var DEFAULT_NAMES = 'A\nB\nC\nD\nE\nF';
var namesText = DEFAULT_NAMES;
var shuffle = false;
var bracket = null;
var view = { x: 0, y: 0, scale: 1, fitted: false };
var drag = null;
var message = '';

var Tournament = {
  // 1回戦の枠に入るシードの番号。size=8 なら [1,8,4,5,2,7,3,6]
  seedOrder: function (size) {
    var order = [1];
    while (order.length < size) {
      var total = order.length * 2 + 1, next = [];
      order.forEach(function (x) { next.push(x, total - x); });
      order = next;
    }
    return order;
  },
  // names の並びをシード順として表を作る。{ names, rounds: [[{ a, b, winner }]] }(a・b・winner は参加者の番号か null)
  make: function (names) {
    if (names.length < 2 || names.length > 64) return null;
    var size = 2;
    while (size < names.length) size *= 2;
    var slots = Tournament.seedOrder(size).map(function (s) { return s <= names.length ? s - 1 : null; });
    var rounds = [[]];
    for (var i = 0; i < size / 2; i++) rounds[0].push({ a: slots[i * 2], b: slots[i * 2 + 1], winner: null });
    for (var count = size / 4; count >= 1; count /= 2) {
      var list = [];
      for (var j = 0; j < count; j++) list.push({ a: null, b: null, winner: null });
      rounds.push(list);
    }
    var t = { names: names.slice(), rounds: rounds };
    rounds[0].forEach(function (m, index) {
      if (Tournament.isBye(m)) Tournament.setWinner(t, 0, index, m.a !== null ? m.a : m.b);
    });
    return t;
  },
  isBye: function (m) { return (m.a === null) !== (m.b === null); },
  // 勝者を決めて次の試合に進める。勝者が変わったら、その先の結果を取り消す
  setWinner: function (t, round, index, player) {
    var m = t.rounds[round] && t.rounds[round][index];
    if (!m) return false;
    if (player !== null && player !== m.a && player !== m.b) return false;
    m.winner = player;
    var next = t.rounds[round + 1];
    if (!next) return true;
    var nm = next[Math.floor(index / 2)], key = index % 2 === 0 ? 'a' : 'b', old = nm[key];
    nm[key] = player;
    if (old !== player && nm.winner !== null) Tournament.setWinner(t, round + 1, Math.floor(index / 2), null);
    return true;
  },
  champion: function (t) { var last = t.rounds[t.rounds.length - 1]; return last[0].winner; },
  // 2回戦の枠のうち、1回戦が不戦勝だった所(シードの印)
  seeded: function (t, slot) { var m = t.rounds[0][slot]; return !!m && Tournament.isBye(m); }
};

function setup() {
  var saved = storage.get('tournament') || {};
  namesText = typeof saved.namesText === 'string' ? saved.namesText : DEFAULT_NAMES;
  shuffle = !!saved.shuffle;
  bracket = saved.bracket || null;
  ui.text('names', { label: '参加者(1行に1人。上からシード順。2〜64人)', value: namesText, multiline: true });
  ui.toggle('shuffle', { label: '組み合わせをランダムにする', value: shuffle });
  ui.button('make', '表を作る(結果は消えます)');
}
function save() { storage.set('tournament', { namesText: namesText, shuffle: shuffle, bracket: bracket }); }

function onInput(name, value) {
  if (name === 'names') namesText = value;
  else if (name === 'shuffle') shuffle = value;
  else if (name === 'make') {
    var names = K.splitNames(namesText);
    if (names.length < 2 || names.length > 64) { message = '参加者は2〜64人にしてください(今は' + names.length + '人)'; }
    else {
      if (shuffle) names = K.shuffle(names, function () { return random.next(); });
      bracket = Tournament.make(names);
      message = '';
      view.fitted = false;
      sound.play('pop');
    }
  }
  save();
  K.invalidate();
}

// ---- 配置(内容の座標) ----
var SLOT = 30, COL = 118, BOX = 104, TOP = 16, LEFT = 12;
function layoutSize(t) {
  var size = t.rounds[0].length * 2;
  return { w: LEFT * 2 + COL * t.rounds.length + BOX, h: TOP * 2 + size * SLOT };
}
function slotY(round, k) { return TOP + (k + 0.5) * SLOT * Math.pow(2, round); }
function fit(w, h) {
  var s = layoutSize(bracket);
  view.scale = Math.max(0.3, Math.min(1.5, Math.min(w / s.w, (h - 50) / s.h)));
  view.x = Math.max(0, (w - s.w * view.scale) / 2);
  view.y = 44;
  view.fitted = true;
}

function onTouch(e) {
  if (e.type === 'down') { drag = { x: e.x, y: e.y, vx: view.x, vy: view.y, moved: false }; return; }
  if (!drag) return;
  if (e.type === 'move') {
    if (Math.abs(e.x - drag.x) + Math.abs(e.y - drag.y) > 8) drag.moved = true;
    if (drag.moved) { view.x = drag.vx + e.x - drag.x; view.y = drag.vy + e.y - drag.y; K.invalidate(); }
    return;
  }
  var start = drag;
  drag = null;
  if (e.type !== 'up' || start.moved) return;
  var b = K.hit({ x: e.x, y: e.y });
  if (!b) return;
  if (b.id === 'zoomIn' || b.id === 'zoomOut') {
    var factor = b.id === 'zoomIn' ? 1.25 : 0.8, cx = screen.width / 2, cy = screen.height / 2;
    var next = Math.max(0.3, Math.min(2.5, view.scale * factor));
    view.x = cx - (cx - view.x) * next / view.scale;
    view.y = cy - (cy - view.y) * next / view.scale;
    view.scale = next;
  } else if (b.id === 'fit') {
    view.fitted = false;
  } else if (b.id === 'entrant' && bracket) {
    var d = b.data, m = bracket.rounds[d.round][d.index];
    if (m.a === null || m.b === null) return;
    Tournament.setWinner(bracket, d.round, d.index, m.winner === d.player ? null : d.player);
    if (Tournament.champion(bracket) !== null && d.round === bracket.rounds.length - 1) { sound.play('success'); haptic('success'); }
    else haptic('light');
    save();
  }
  K.invalidate();
}

function frame() { K.frame(draw); }

function draw(w, h, th) {
  if (!bracket) {
    K.paragraph(message || '下の欄に参加者を入れて「表を作る」を押してください。', 12, 16, w - 24, 15, message ? th.danger : th.sub);
    return h;
  }
  if (!view.fitted) fit(w, h);
  var s = view.scale;
  function sx(x) { return view.x + x * s; }
  function sy(y) { return view.y + y * s; }
  var rounds = bracket.rounds, names = bracket.names;
  ctx.lineWidth = Math.max(1, 2 * s);
  for (var r = 0; r < rounds.length; r++) {
    var x0 = LEFT + r * COL;
    for (var i = 0; i < rounds[r].length; i++) {
      var m = rounds[r][i];
      if (r === 0 && Tournament.isBye(m)) continue;
      var ya = slotY(r, i * 2), yb = slotY(r, i * 2 + 1), yn = slotY(r + 1, i);
      // 勝ち上がりの線
      ctx.strokeStyle = th.line;
      ctx.beginPath();
      ctx.moveTo(sx(x0 + BOX), sy(ya)); ctx.lineTo(sx(x0 + COL - 6), sy(ya));
      ctx.lineTo(sx(x0 + COL - 6), sy(yb)); ctx.lineTo(sx(x0 + BOX), sy(yb));
      ctx.moveTo(sx(x0 + COL - 6), sy(yn)); ctx.lineTo(sx(x0 + COL), sy(yn));
      ctx.stroke();
      if (m.winner !== null) {
        var yw = m.winner === m.a ? ya : yb;
        ctx.strokeStyle = th.accent;
        ctx.beginPath();
        ctx.moveTo(sx(x0 + BOX), sy(yw)); ctx.lineTo(sx(x0 + COL - 6), sy(yw)); ctx.lineTo(sx(x0 + COL - 6), sy(yn)); ctx.lineTo(sx(x0 + COL), sy(yn));
        ctx.stroke();
      }
      entrant(m.a, r, i, ya, x0, m, th, sx, sy);
      entrant(m.b, r, i, yb, x0, m, th, sx, sy);
    }
  }
  // 優勝者の枠
  var champ = Tournament.champion(bracket), cx = LEFT + rounds.length * COL, cy = slotY(rounds.length, 0);
  ctx.fillStyle = champ !== null ? th.warn : th.card;
  K.roundRect(sx(cx), sy(cy - SLOT / 2 + 2), BOX * s, (SLOT - 4) * s, 6 * s);
  ctx.fill();
  ctx.fillStyle = champ !== null ? '#1c1c1e' : th.sub;
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  K.fitText(champ !== null ? '優勝 ' + names[champ] : '優勝', sx(cx + BOX / 2), sy(cy), (BOX - 8) * s, 14 * s, true);
  // 操作のボタン(画面に固定)
  ctx.fillStyle = th.bg;
  ctx.fillRect(0, 0, w, 40);
  ctx.fillStyle = th.sub;
  ctx.textAlign = 'left';
  K.fitText(names.length + '人・' + rounds.length + '回戦', 12, 20, w - 190, 13, false);
  K.button('zoomOut', w - 172, 4, 48, 32, '−', { size: 20 });
  K.button('zoomIn', w - 120, 4, 48, 32, '+', { size: 20 });
  K.button('fit', w - 68, 4, 56, 32, '全体', { size: 14 });
  return h;
}

function entrant(player, round, index, y, x0, m, th, sx, sy) {
  var s = view.scale, x = sx(x0), top = sy(y - SLOT / 2 + 3), bw = BOX * s, bh = (SLOT - 6) * s;
  var isWinner = player !== null && m.winner === player, lost = player !== null && m.winner !== null && !isWinner;
  ctx.fillStyle = isWinner ? th.accent : th.card;
  K.roundRect(x, top, bw, bh, 5 * s);
  ctx.fill();
  ctx.globalAlpha = lost ? 0.45 : 1;
  ctx.fillStyle = isWinner ? th.accentFg : (player === null ? th.sub : th.fg);
  ctx.textAlign = 'left';
  ctx.textBaseline = 'middle';
  var label = player === null ? '' : bracket.names[player];
  var seedMark = round === 1 && Tournament.seeded(bracket, index * 2 + (y === slotY(1, index * 2) ? 0 : 1));
  K.fitText(label, x + 6 * s, top + bh / 2, bw - (seedMark ? 34 : 12) * s, 13 * s, isWinner);
  if (seedMark && player !== null) {
    ctx.fillStyle = th.warn;
    ctx.textAlign = 'right';
    K.fitText('シード', x + bw - 4 * s, top + bh / 2, 30 * s, 9 * s, true);
  }
  ctx.globalAlpha = 1;
  if (player !== null) K.area('entrant', x, top, bw, bh, { round: round, index: index, player: player });
}
