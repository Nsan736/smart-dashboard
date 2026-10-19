// チーム分け(JavaScript 版)。名前は1行に1つ(カンマ・読点でも区切れる)。並べ替えてから、順にチームへ配る(人数の差は1人まで)。
var DEFAULT_NAMES = 'Aさん\nBさん\nCさん\nDさん\nEさん\nFさん\nGさん';
var namesText = DEFAULT_NAMES;
var teamCount = 2;
var teams = [];

var Teams = {
  // shuffled の順に、チーム 0,1,2,… と配る
  split: function (names, count, rnd) {
    count = Math.max(1, Math.min(count, names.length));
    var shuffled = K.shuffle(names, rnd), out = [];
    for (var i = 0; i < count; i++) out.push([]);
    shuffled.forEach(function (name, i) { out[i % count].push(name); });
    return out;
  }
};

function setup() {
  var saved = storage.get('teams') || {};
  namesText = typeof saved.namesText === 'string' ? saved.namesText : DEFAULT_NAMES;
  teamCount = saved.teamCount || 2;
  teams = saved.teams || [];
  ui.text('names', { label: 'メンバー(1行に1人)', value: namesText, multiline: true });
  ui.slider('count', { label: 'チームの数', min: 2, max: 10, step: 1, value: teamCount });
  ui.button('split', 'チームに分ける');
}
function save() { storage.set('teams', { namesText: namesText, teamCount: teamCount, teams: teams }); }

function onInput(name, value) {
  if (name === 'names') namesText = value;
  else if (name === 'count') teamCount = Math.round(value);
  else if (name === 'split') {
    var names = K.splitNames(namesText);
    teams = names.length ? Teams.split(names, teamCount, function () { return random.next(); }) : [];
    sound.play('pop');
    haptic('light');
    K.scrollTo(0);
  }
  save();
  K.invalidate();
}
function onTouch(e) { K.touch(e); }
function frame() { K.frame(draw); }

function draw(w, h, th) {
  var pad = 12, cw = w - pad * 2, y = 12;
  var n = K.splitNames(namesText).length;
  ctx.fillStyle = th.sub;
  ctx.textAlign = 'left';
  ctx.textBaseline = 'top';
  K.fitText(n + '人を' + Math.min(teamCount, Math.max(n, 1)) + 'チームに', pad, y, cw, 14, false);
  y += 24;
  if (!teams.length) { y += K.paragraph('「チームに分ける」を押してください。', pad, y, cw, 15, th.sub); return y + 20; }
  var cols = w >= 500 ? 3 : 2, gap = 8, colW = (cw - gap * (cols - 1)) / cols, colY = [];
  for (var c = 0; c < cols; c++) colY.push(y);
  teams.forEach(function (team, i) {
    var col = colY.indexOf(Math.min.apply(null, colY)), x = pad + col * (colW + gap), ty = colY[col];
    var boxH = 34 + team.length * 24;
    K.card(x, ty, colW, boxH, th);
    ctx.fillStyle = K.palette[i % K.palette.length];
    ctx.fillRect(x, ty + 8, 4, boxH - 16);
    ctx.fillStyle = th.fg;
    ctx.textAlign = 'left';
    ctx.textBaseline = 'top';
    K.fitText('チーム' + (i + 1) + '(' + team.length + '人)', x + 12, ty + 8, colW - 20, 15, true);
    team.forEach(function (name, j) { ctx.fillStyle = th.fg; K.fitText(name, x + 12, ty + 32 + j * 24, colW - 20, 15, false); });
    colY[col] = ty + boxH + gap;
  });
  return Math.max.apply(null, colY) + 20;
}
