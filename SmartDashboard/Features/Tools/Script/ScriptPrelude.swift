import Foundation

/// スクリプトの前に読み込む JavaScript。ctx(描画)・image・canvas・ui・sound・storage・random・haptic・screen・console・app を作る。
/// 描画の命令は Float64Array に数として貯め、1コマの終わりに1回だけアプリに渡す(命令ごとにアプリを呼ばない)。
/// 命令の番号は ScriptOpCode と同じ。アプリの機能は __native(アプリが渡す関数)だけを通す。
/// app.* は、アプリが __setData で入れたデータの写し(JSON の文字列)を、読むたびに新しいオブジェクトにして返す(読み取り専用)。
enum ScriptPrelude {
    static let source = #"""
    (function (global) {
      'use strict';
      var native = global.__native;
      delete global.__native;
      var MAX = 400000;
      var B = new Float64Array(8192), n = 0, overflow = false;
      var S = [], SM = new Map(), sent = 0, resetStrings = false;
      var gradientID = 0;

      function room(k) {
        if (n + k <= B.length) return true;
        if (B.length >= MAX) { overflow = true; return false; }
        var nb = new Float64Array(Math.min(MAX, B.length * 2));
        nb.set(B);
        B = nb;
        return n + k <= B.length;
      }
      function o1(c) { if (room(1)) { B[n++] = c; } }
      function o2(c, a) { if (room(2)) { B[n++] = c; B[n++] = +a; } }
      function o3(c, a, b) { if (room(3)) { B[n++] = c; B[n++] = +a; B[n++] = +b; } }
      function o5(c, a, b, d, e) { if (room(5)) { B[n++] = c; B[n++] = +a; B[n++] = +b; B[n++] = +d; B[n++] = +e; } }
      function str(s) {
        s = String(s);
        if (s.length > 200) s = s.slice(0, 200);
        var i = SM.get(s);
        if (i === undefined) { i = S.length; S.push(s); SM.set(s, i); }
        return i;
      }

      // アプリが呼ぶ: 1コマの始まりと終わり
      global.__begin = function () {
        n = 0; overflow = false; gradientID = 0;
        if (S.length > 2000) { S = []; SM = new Map(); sent = 0; resetStrings = true; }
      };
      global.__end = function () {
        var out = { count: n, buffer: B, strings: S.slice(sent), reset: resetStrings, overflow: overflow };
        sent = S.length; resetStrings = false;
        return out;
      };

      function Gradient(kind, args) { this.kind = kind; this.args = args; this.stops = []; }
      Gradient.prototype.addColorStop = function (offset, color) {
        if (this.stops.length < 32) this.stops.push([+offset, String(color)]);
      };
      function setPaint(paint, colorCode, gradientCode) {
        if (paint instanceof Gradient) {
          var id = gradientID++;
          var a = paint.args, head = paint.kind === 'linear' ? 70 : 71;
          var k = 2 + a.length + 1 + paint.stops.length * 2;
          if (!room(k)) return;
          B[n++] = head; B[n++] = id;
          for (var i = 0; i < a.length; i++) B[n++] = +a[i];
          B[n++] = paint.stops.length;
          for (var j = 0; j < paint.stops.length; j++) { B[n++] = paint.stops[j][0]; B[n++] = str(paint.stops[j][1]); }
          o2(gradientCode, id);
        } else {
          o2(colorCode, str(paint));
        }
      }

      var state = { fillStyle: '#000000', strokeStyle: '#000000', lineWidth: 1, globalAlpha: 1, font: '10px sans-serif',
                    textAlign: 'start', textBaseline: 'alphabetic', lineCap: 'butt', lineJoin: 'miter', imageSmoothingEnabled: true };
      var stack = [];
      var caps = { butt: 0, round: 1, square: 2 }, joins = { miter: 0, round: 1, bevel: 2 };
      var aligns = { start: 0, left: 0, center: 1, end: 2, right: 2 };
      var baselines = { alphabetic: 0, top: 1, hanging: 1, middle: 2, bottom: 3, ideographic: 3 };

      var ctx = {
        save: function () { stack.push(Object.assign({}, state)); o1(1); },
        restore: function () { if (stack.length) { state = stack.pop(); } o1(2); },
        translate: function (x, y) { o3(3, x, y); },
        rotate: function (a) { o2(4, a); },
        scale: function (x, y) { o3(5, x, y === undefined ? x : y); },
        transform: function (a, b, c, d, e, f) { if (room(7)) { B[n++] = 6; B[n++] = +a; B[n++] = +b; B[n++] = +c; B[n++] = +d; B[n++] = +e; B[n++] = +f; } },
        setTransform: function (a, b, c, d, e, f) { o1(7); if (a !== undefined) this.transform(a, b, c, d, e, f); },
        resetTransform: function () { o1(7); },
        beginPath: function () { o1(30); },
        moveTo: function (x, y) { o3(31, x, y); },
        lineTo: function (x, y) { o3(32, x, y); },
        quadraticCurveTo: function (cx, cy, x, y) { o5(33, cx, cy, x, y); },
        bezierCurveTo: function (a, b, c, d, x, y) { if (room(7)) { B[n++] = 34; B[n++] = +a; B[n++] = +b; B[n++] = +c; B[n++] = +d; B[n++] = +x; B[n++] = +y; } },
        arc: function (x, y, r, a0, a1, ccw) { if (room(7)) { B[n++] = 35; B[n++] = +x; B[n++] = +y; B[n++] = +r; B[n++] = +a0; B[n++] = +a1; B[n++] = ccw ? 1 : 0; } },
        ellipse: function (x, y, rx, ry, rot, a0, a1, ccw) {
          if (room(9)) { B[n++] = 38; B[n++] = +x; B[n++] = +y; B[n++] = +rx; B[n++] = +ry; B[n++] = +rot; B[n++] = +a0; B[n++] = +a1; B[n++] = ccw ? 1 : 0; }
        },
        rect: function (x, y, w, h) { o5(36, x, y, w, h); },
        closePath: function () { o1(37); },
        fill: function () { o1(40); },
        stroke: function () { o1(41); },
        clip: function () { o1(45); },
        fillRect: function (x, y, w, h) { o5(42, x, y, w, h); },
        strokeRect: function (x, y, w, h) { o5(43, x, y, w, h); },
        clearRect: function (x, y, w, h) { o5(44, x, y, w, h); },
        fillText: function (t, x, y) { if (room(4)) { B[n++] = 50; B[n++] = str(t); B[n++] = +x; B[n++] = +y; } },
        strokeText: function (t, x, y) { if (room(4)) { B[n++] = 51; B[n++] = str(t); B[n++] = +x; B[n++] = +y; } },
        measureText: function (t) { return { width: native.measureText(String(t), state.font) }; },
        setLineDash: function (list) {
          list = Array.isArray(list) ? list.slice(0, 16) : [];
          if (!room(2 + list.length)) return;
          B[n++] = 21; B[n++] = list.length;
          for (var i = 0; i < list.length; i++) B[n++] = +list[i];
        },
        drawImage: function (img, a, b, c, d, e, f, g, h) {
          if (!img || typeof img.id !== 'number') throw new Error('drawImage: image.create で作った画像を渡してください');
          if (arguments.length >= 9) {
            if (room(10)) { B[n++] = 61; B[n++] = img.id; B[n++] = +a; B[n++] = +b; B[n++] = +c; B[n++] = +d; B[n++] = +e; B[n++] = +f; B[n++] = +g; B[n++] = +h; }
          } else {
            var w = arguments.length >= 5 ? c : img.width, hh = arguments.length >= 5 ? d : img.height;
            if (room(6)) { B[n++] = 60; B[n++] = img.id; B[n++] = +a; B[n++] = +b; B[n++] = +w; B[n++] = +hh; }
          }
        },
        createLinearGradient: function (x0, y0, x1, y1) { return new Gradient('linear', [x0, y0, x1, y1]); },
        createRadialGradient: function (x0, y0, r0, x1, y1, r1) { return new Gradient('radial', [x0, y0, r0, x1, y1, r1]); }
      };
      function prop(name, apply) {
        Object.defineProperty(ctx, name, { get: function () { return state[name]; }, set: function (v) { state[name] = v; apply(v); } });
      }
      prop('fillStyle', function (v) { setPaint(v, 11, 13); });
      prop('strokeStyle', function (v) { setPaint(v, 12, 14); });
      prop('lineWidth', function (v) { o2(15, v); });
      prop('globalAlpha', function (v) { o2(10, v); });
      prop('font', function (v) { o2(18, str(v)); });
      prop('textAlign', function (v) { o2(19, aligns[v] || 0); });
      prop('textBaseline', function (v) { o2(20, baselines[v] || 0); });
      prop('lineCap', function (v) { o2(16, caps[v] || 0); });
      prop('lineJoin', function (v) { o2(17, joins[v] || 0); });
      prop('imageSmoothingEnabled', function (v) { o2(22, v ? 1 : 0); });
      global.ctx = ctx;

      global.screen = { width: 0, height: 0, dark: false, scale: 2 };
      Object.defineProperty(global.screen, 'keepAwake', { value: function (on) { native.keepAwake(!!on); }, enumerable: false });

      // 通知(端末のローカル通知。ツールごとに8件まで)
      function notifyCall(spec) { if (!native.notify(JSON.stringify(spec))) { var e = native.lastError(); if (e) throw new Error(e); return false; } return true; }
      global.notify = Object.freeze({
        schedule: function (id, seconds, o) {
          o = (typeof o === 'string') ? { title: o } : (o || {});
          return notifyCall({ op: 'schedule', id: String(id), seconds: +seconds, title: o.title === undefined ? '' : String(o.title), body: o.body === undefined ? '' : String(o.body) });
        },
        cancel: function (id) { return notifyCall({ op: 'cancel', id: String(id) }); },
        cancelAll: function () { return notifyCall({ op: 'cancelAll' }); }
      });
      // クリップボード(書くだけ)
      global.clipboard = Object.freeze({
        copy: function (text) {
          var ok = native.copy(String(text));
          if (!ok) { var e = native.lastError(); if (e && e.indexOf('clipboard') === 0) throw new Error(e); }
          return ok;
        }
      });

      global.image = {
        create: function (width, height, pixels) {
          width = width | 0; height = height | 0;
          if (!(pixels instanceof Uint8ClampedArray) && !(pixels instanceof Uint8Array)) throw new Error('image.create: ピクセルは Uint8ClampedArray で渡してください');
          if (pixels.length !== width * height * 4) throw new Error('image.create: ピクセルの数が 幅×高さ×4 と合いません');
          var id = native.createImage(width, height, pixels);
          if (id < 0) throw new Error(native.lastError());
          return { id: id, width: width, height: height };
        },
        update: function (img, pixels) {
          if (!img || pixels.length !== img.width * img.height * 4) throw new Error('image.update: 大きさが合いません');
          if (!native.updateImage(img.id, pixels)) throw new Error(native.lastError());
        },
        release: function (img) { if (img) native.releaseImage(img.id); },
        exportPNG: function (img, options) {
          var scale = options && options.scale ? +options.scale : 1;
          native.exportImage(img.id, scale, options && options.name ? String(options.name) : '');
        }
      };
      global.canvas = {
        exportPNG: function (options) {
          var width = options && options.width ? +options.width : 0;
          native.exportCanvas(width, options && options.name ? String(options.name) : '');
        }
      };

      global.ui = {
        slider: function (id, o) { o = o || {}; native.ui(JSON.stringify({ op: 'add', id: String(id), type: 'slider', label: o.label, min: o.min, max: o.max, step: o.step, value: o.value })); },
        button: function (id, o) { o = (typeof o === 'string') ? { label: o } : (o || {}); native.ui(JSON.stringify({ op: 'add', id: String(id), type: 'button', label: o.label })); },
        toggle: function (id, o) { o = o || {}; native.ui(JSON.stringify({ op: 'add', id: String(id), type: 'toggle', label: o.label, value: !!o.value })); },
        text: function (id, o) {
          o = o || {};
          native.ui(JSON.stringify({ op: 'add', id: String(id), type: 'text', label: o.label, value: o.value === undefined ? '' : String(o.value),
                                     multiline: !!o.multiline, keyboard: o.keyboard, placeholder: o.placeholder }));
        },
        choice: function (id, o) { o = o || {}; native.ui(JSON.stringify({ op: 'add', id: String(id), type: 'choice', label: o.label, options: o.options, value: o.value })); },
        set: function (id, value) { native.ui(JSON.stringify({ op: 'set', id: String(id), value: value })); },
        remove: function (id) { native.ui(JSON.stringify({ op: 'remove', id: String(id) })); }
      };

      global.sound = {
        play: function (name) { native.sound(String(name), 0, 0, 0); },
        tone: function (frequency, duration, volume) { native.sound('tone', +frequency, +(duration || 0.2), volume === undefined ? 0.5 : +volume); }
      };
      global.haptic = function (kind) { native.haptic(String(kind || 'light')); };

      global.storage = {
        get: function (key) {
          var raw = native.storageGet(String(key));
          return raw === null || raw === undefined ? undefined : JSON.parse(raw);
        },
        set: function (key, value) {
          var raw = JSON.stringify(value);
          if (raw === undefined) throw new Error('storage.set: JSON で表せる値にしてください');
          if (!native.storageSet(String(key), raw)) throw new Error(native.lastError());
        },
        remove: function (key) { native.storageSet(String(key), null); },
        keys: function () { return JSON.parse(native.storageKeys()); },
        clear: function () { native.storageClear(); }
      };

      // シードを指定できる乱数(mulberry32)
      var seed = (Date.now() >>> 0) || 1;
      global.random = {
        seed: function (s) { seed = (+s >>> 0) || 1; },
        next: function () {
          seed = (seed + 0x6D2B79F5) >>> 0;
          var t = seed;
          t = Math.imul(t ^ (t >>> 15), t | 1);
          t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
          return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
        },
        range: function (a, b) { return a + (b - a) * this.next(); },
        int: function (a, b) { return Math.floor(a + (b - a + 1) * this.next()); },
        pick: function (list) { return list[Math.floor(this.next() * list.length)]; },
        // 暗号に使える乱数(パスワードなど。シードの影響を受けない)
        secure: function () { return native.secureRandom(); },
        secureInt: function (a, b) { a = Math.ceil(a); b = Math.floor(b); return Math.min(b, a + Math.floor((b - a + 1) * native.secureRandom())); }
      };

      function text(args) {
        var parts = [];
        for (var i = 0; i < args.length; i++) {
          var v = args[i];
          if (typeof v === 'string') parts.push(v);
          else if (v instanceof Error) parts.push(v.message);
          else { try { parts.push(JSON.stringify(v)); } catch (e) { parts.push(String(v)); } }
        }
        return parts.join(' ');
      }
      global.console = {
        log: function () { native.log(0, text(arguments)); },
        info: function () { native.log(0, text(arguments)); },
        warn: function () { native.log(1, text(arguments)); },
        error: function () { native.log(2, text(arguments)); }
      };

      // アプリのデータ(許可した種類だけ。許可していない種類は null)
      var D = {};
      global.__setData = function (kind, raw) { D[String(kind)] = String(raw); };
      function read(kind) {
        var raw = D[kind];
        if (raw === undefined || raw === 'null') return null;
        try { return JSON.parse(raw); } catch (e) { return null; }
      }
      var app = {};
      ['weather', 'warnings', 'quakes', 'pressure', 'exchange', 'trains', 'places', 'location', 'calendar', 'permissions'].forEach(function (k) {
        Object.defineProperty(app, k, { get: function () { return read(k); }, enumerable: true });
      });
      var sensorKinds = ['steps', 'speed', 'heading', 'pressure', 'motion'];
      function sensorKind(kind, name) {
        kind = String(kind);
        if (sensorKinds.indexOf(kind) < 0) throw new Error('app.sensors.' + name + ': ' + sensorKinds.join(' / ') + ' のどれかにしてください');
        return kind;
      }
      var sensors = {
        start: function (kind) { return native.sensor(sensorKind(kind, 'start'), true); },
        stop: function (kind) { return native.sensor(sensorKind(kind, 'stop'), false); },
        read: function () { return read('sensors'); }
      };
      sensorKinds.forEach(function (k) {
        Object.defineProperty(sensors, k, { get: function () { var s = read('sensors'); return s && s[k] !== undefined ? s[k] : null; }, enumerable: true });
      });
      ['active', 'available', 'problems'].forEach(function (k) {
        Object.defineProperty(sensors, k, { get: function () { var s = read('sensors'); return s ? s[k] : null; }, enumerable: true });
      });
      app.sensors = Object.freeze(sensors);
      app.holidayName = function (y, m, d) {
        if (y instanceof Date) { d = y.getDate(); m = y.getMonth() + 1; y = y.getFullYear(); }
        var name = native.holidayName(y | 0, m | 0, d | 0);
        return name ? name : null;
      };
      global.app = Object.freeze(app);
    })(this);
    """#
}
