// 模様のテクスチャ: 64×64 のピクセルを作って並べて表示し、PNG(8倍の 512×512)で書き出す。
var N = 64;
var kind = 'チェック';
var hue = 200;
var img = null;

function rgb(h, s, l) {
  var q = l < 0.5 ? l * (1 + s) : l + s - l * s, p = 2 * l - q;
  function f(t) {
    t = (t + 1) % 1;
    if (t < 1 / 6) return p + (q - p) * 6 * t;
    if (t < 1 / 2) return q;
    if (t < 2 / 3) return p + (q - p) * (2 / 3 - t) * 6;
    return p;
  }
  var hh = h / 360;
  return [Math.round(f(hh + 1 / 3) * 255), Math.round(f(hh) * 255), Math.round(f(hh - 1 / 3) * 255)];
}

function pixels() {
  var px = new Uint8ClampedArray(N * N * 4);
  var c1 = rgb(hue, 0.7, 0.55), c2 = rgb((hue + 40) % 360, 0.6, 0.85);
  random.seed(7);
  for (var y = 0; y < N; y++) {
    for (var x = 0; x < N; x++) {
      var on;
      if (kind === 'チェック') on = ((x >> 3) + (y >> 3)) % 2 === 0;
      else if (kind === 'しま') on = ((x + y) >> 2) % 2 === 0;
      else if (kind === '水玉') { var dx = (x % 16) - 8, dy = (y % 16) - 8; on = dx * dx + dy * dy < 20; }
      else on = random.next() < 0.5;
      var c = on ? c1 : c2, o = (y * N + x) * 4;
      px[o] = c[0]; px[o + 1] = c[1]; px[o + 2] = c[2]; px[o + 3] = 255;
    }
  }
  return px;
}

function rebuild() {
  if (img) image.update(img, pixels());
  else img = image.create(N, N, pixels());
}

function setup() {
  rebuild();
}

function onInput(name, value) {
  if (name === 'kind') { kind = value; rebuild(); }
  if (name === 'hue') { hue = value; rebuild(); }
  if (name === 'export') image.exportPNG(img, { scale: 8, name: 'pattern' });
}

function frame() {
  var w = screen.width, h = screen.height;
  ctx.imageSmoothingEnabled = false;
  for (var y = 0; y < h; y += 128) {
    for (var x = 0; x < w; x += 128) ctx.drawImage(img, x, y, 128, 128);
  }
  ctx.imageSmoothingEnabled = true;
  ctx.fillStyle = 'rgba(0, 0, 0, 0.5)';
  ctx.fillRect(0, h - 28, w, 28);
  ctx.fillStyle = '#ffffff';
  ctx.font = '13px sans-serif';
  ctx.textAlign = 'left';
  ctx.textBaseline = 'middle';
  ctx.fillText('64×64 の模様を並べて表示。書き出すと 512×512', 8, h - 14);
}
