// ドット絵のアニメーション: 文字で描いた絵からピクセルの配列を作り(image.create)、補間しないで拡大して描く。
var palette = {
  '.': [0, 0, 0, 0], 'k': [30, 30, 40, 255], 's': [255, 205, 160, 255],
  'r': [220, 50, 60, 255], 'b': [50, 90, 200, 255], 'w': [255, 255, 255, 255]
};
var body = [
  '................',
  '.....kkkkkk.....',
  '....krrrrrrk....',
  '...krrrrrrrrk...',
  '...kssssssssk...',
  '...kskssssksk...',
  '...kssssssssk...',
  '....kssrrssk....',
  '.....kkkkkk.....',
  '....kbbbbbbk....',
  '...kbbwbbwbbk...',
  '...kbbbbbbbbk...',
  '....kbbbbbbk....'
];
var legsA = ['....kk....kk....', '...kkk....kkk...', '................'];
var legsB = ['.....kk..kk.....', '....kkk..kkk....', '................'];
var sprites = [];
var x = -100;
var scale = 6;

function build(rows) {
  var w = 16, h = 16, px = new Uint8ClampedArray(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var i = 0; i < w; i++) {
      var c = palette[rows[y].charAt(i)] || palette['.'];
      var o = (y * w + i) * 4;
      px[o] = c[0]; px[o + 1] = c[1]; px[o + 2] = c[2]; px[o + 3] = c[3];
    }
  }
  return image.create(w, h, px);
}

function setup() {
  sprites = [build(body.concat(legsA)), build(body.concat(legsB))];
}

function onInput(name, value) {
  if (name === 'size') scale = value;
}

function frame(t, dt) {
  var w = screen.width, h = screen.height, size = 16 * scale, groundY = Math.round(h * 0.7);
  ctx.fillStyle = screen.dark ? '#1b2a3a' : '#bfe3ff';
  ctx.fillRect(0, 0, w, groundY);
  ctx.fillStyle = '#5a9e3c';
  ctx.fillRect(0, groundY, w, h - groundY);
  x += 10 * scale * dt;
  if (x > w + size) x = -size;
  var f = Math.floor(t * 6) % 2;
  var bob = f === 0 ? 0 : -scale;
  ctx.imageSmoothingEnabled = false;
  ctx.drawImage(sprites[f], Math.round(x), groundY - size + scale + bob, size, size);
  ctx.imageSmoothingEnabled = true;
}
