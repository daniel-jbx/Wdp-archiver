(function() {
  const canvas     = document.getElementById('canvas');
  const selCanvas  = document.getElementById('sel-canvas');
  const daySlider  = document.getElementById('slider-day');
  const snapSlider = document.getElementById('slider-snap');
  const tsLabel    = document.getElementById('timestamp-label-top');
  const datePick   = document.getElementById('date-picker');
  const timeSel    = document.getElementById('time-select');
  const dlSnap     = document.getElementById('dl-snapshot');
  const dlToggle   = document.getElementById('dl-select-toggle');
  const dlPng      = document.getElementById('dl-select-png');
  const dlOverlay  = document.getElementById('dl-select-overlay');
  const coordsDiv  = document.getElementById('coords-display');
  const selCtx     = selCanvas.getContext('2d');

  const _diffBtnEl = document.getElementById('diff-btn');
  if (_diffBtnEl) _diffBtnEl.style.display = 'none';

  const copyLinkBtn = document.createElement('button');
  copyLinkBtn.id = 'dl-copy-link';
  copyLinkBtn.className = 'dl-btn';
  copyLinkBtn.textContent = 'copy link';
  dlPng.parentNode.insertBefore(copyLinkBtn, dlOverlay);

  const urlParams = new URLSearchParams(window.location.search);
  const urlSnap   = urlParams.get('snap');
  const urlX      = parseFloat(urlParams.get('x'));
  const urlY      = parseFloat(urlParams.get('y'));
  const urlZoom   = parseFloat(urlParams.get('zoom'));
  const urlBase   = urlParams.get('base');
  const urlTimeline = urlParams.get('timeline') || 'timeline.json';

  const IS_IOS = /iPad|iPhone|iPod/.test(navigator.userAgent) ||
                 (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);

  const dataset  = location.pathname.includes('/antarktika/') ? 'antarktika' : 'wdp';
  const DEFAULT_BASE = `https://pub-e0766eb5f5114fc097a10215d5e6081b.r2.dev/${dataset === 'wdp' ? '' : 'antarktika/'}`;
  const BASE_URL = urlBase || DEFAULT_BASE;
  const ZOOM = 11, TILE = 1000, WORLD = Math.pow(2, ZOOM) * TILE;

  const ranges = {
    wdp:        { col:1224, row:513, cols:8, rows:7 },
    antarktika: { col:1279, row:1715, cols:6, rows:5 }
  }[dataset];

  const SIZE_TO_RANGES = {
    wdp: {
      '8000x7000': { col:1224, row:513, cols:8, rows:7 },
      '7000x6000': { col:1225, row:513, cols:7, rows:6 },
    },
    antarktika: {
      '6000x5000': { col:1279, row:1715, cols:6, rows:5 },
    }
  }[dataset] || {};

  function rangesForSize(w, h) {
    return SIZE_TO_RANGES[`${w}x${h}`] || ranges;
  }

  const current = {
    w: ranges.cols * TILE,
    h: ranges.rows * TILE,
    ranges: ranges,
  };

  let pendingSavedViewport = null;
  if (!isNaN(urlX) && !isNaN(urlY) && !isNaN(urlZoom)) {
    pendingSavedViewport = { x: urlX, y: urlY, zoom: urlZoom };
  }

  function parseTimestamp(name) {
    const m = name.match(/(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})(\d{2})/);
    if (!m) return null;
    return {
      epoch: Date.UTC(+m[1], +m[2]-1, +m[3], +m[4], +m[5], +m[6]) / 1000,
      date:  `${m[1]}-${m[2]}-${m[3]}`,
      time:  `${m[4]}:${m[5]}:${m[6]}`,
    };
  }
  function epochFromName(name) { return parseTimestamp(name)?.epoch ?? 0; }

  function loadImage(url) {
    return new Promise((resolve, reject) => {
      const img = new Image();
      img.crossOrigin = 'anonymous';
      img.onload = () => resolve(img);
      img.onerror = () => reject(new Error('image failed: ' + url));
      img.src = url;
    });
  }

  function pixelToLatLon(px, py) {
    const gx = current.ranges.col * TILE + px;
    const gy = current.ranges.row * TILE + py;
    const y = 1 - 2 * gy / WORLD, lon = (gx / WORLD) * 360 - 180;
    const lat = (2 * Math.atan(Math.exp(Math.PI * y)) - Math.PI / 2) * 180 / Math.PI;
    return { lat, lon };
  }
  function cropToBounds(x, y, w, h) {
    const nw = pixelToLatLon(x, y), se = pixelToLatLon(x + w, y + h);
    return { north: nw.lat, south: se.lat, west: nw.lon, east: se.lon };
  }

  function matMul(a, b, out) {
    for (let c = 0; c < 3; c++) {
      const b0 = b[c*3], b1 = b[c*3+1], b2 = b[c*3+2];
      for (let r = 0; r < 3; r++) out[c*3+r] = a[r]*b0 + a[3+r]*b1 + a[6+r]*b2;
    }
  }

  async function fetchJson(url) {
    const r = await fetch(url);
    if (!r.ok) throw new Error('fetch failed: ' + url + ' (' + r.status + ')');
    const buf = await r.arrayBuffer();
    const b = new Uint8Array(buf);
    const f = b.length > 0 ? b[0] : -1;
    const looksJson = f === 0x7B || f === 0x5B ||
                      f === 0x20 || f === 0x09 || f === 0x0A || f === 0x0D;
    if (looksJson) return JSON.parse(new TextDecoder().decode(buf));
    if (typeof DecompressionStream !== 'undefined') {
      for (const fmt of ['brotli', 'gzip', 'deflate']) {
        try {
          const ds = new DecompressionStream(fmt);
          const stream = new Blob([buf]).stream().pipeThrough(ds);
          return JSON.parse(await new Response(stream).text());
        } catch (_) { /* try next format */ }
      }
    }
    throw new Error('unrecognized response encoding: ' + url);
  }

  // Helper: always create a pixel-art context with smoothing off.
  function pixelCtx(canvasEl) {
    const ctx = canvasEl.getContext('2d');
    ctx.imageSmoothingEnabled = false;
    return ctx;
  }

  class Compositor {
    constructor(opts) {
      opts = opts || {};
      this.maxBases = opts.maxBases || 4;
      this.maxDiffs = opts.maxDiffs || 96;
      this.baseCache = new Map();
      this.diffCache = new Map();
      this.palette = null;
      this.composeCanvas = null;
      this.composeCtx = null;
    }
    setPalette(p) { this.palette = p; }

    registerBase(baseTime, imgPromise) {
      this.baseCache.delete(baseTime);
      this.baseCache.set(baseTime, imgPromise);
      while (this.baseCache.size > this.maxBases) {
        const k = this.baseCache.keys().next().value;
        this.baseCache.delete(k);
      }
    }
    hasBase(baseTime) { return this.baseCache.has(baseTime); }

    getDiff(src) {
      if (this.diffCache.has(src)) {
        const v = this.diffCache.get(src);
        this.diffCache.delete(src);
        this.diffCache.set(src, v);
        return v;
      }
      const p = fetchJson(BASE_URL + src);
      this.diffCache.set(src, p);
      while (this.diffCache.size > this.maxDiffs) {
        this.diffCache.delete(this.diffCache.keys().next().value);
      }
      p.catch(() => { this.diffCache.delete(src); });
      return p;
    }

    async compose(entry, opts) {
      opts = opts || {};
      const basePromise = this.baseCache.get(entry.base);
      if (!basePromise) throw new Error('base not loaded: ' + entry.base);
      const [baseImg, diff] = await Promise.all([basePromise, this.getDiff(entry.src)]);
      const w = baseImg.naturalWidth;
      const h = baseImg.naturalHeight;

      let target, ctx;
      if (opts.fresh) {
        target = document.createElement('canvas');
        target.width = w;
        target.height = h;
        ctx = pixelCtx(target);
        ctx.drawImage(baseImg, 0, 0);
      } else {
        if (!this.composeCanvas || this.composeCanvas.width !== w || this.composeCanvas.height !== h) {
          this.composeCanvas = document.createElement('canvas');
          this.composeCanvas.width = w;
          this.composeCanvas.height = h;
          this.composeCtx = pixelCtx(this.composeCanvas);
          this.composeCtx.drawImage(baseImg, 0, 0);
          ctx = this.composeCtx;
        } else {
          ctx = this.composeCtx;
          ctx.globalCompositeOperation = 'copy';
          ctx.drawImage(baseImg, 0, 0);
          ctx.globalCompositeOperation = 'source-over';
        }
        target = this.composeCanvas;
      }

      const fmt = diff.format || entry.format || 'v1';

      const TRANSPARENT_HEX = '#47704c';
      const trIdx = this.palette
        ? this.palette.findIndex(h => typeof h === 'string' && h.toLowerCase() === TRANSPARENT_HEX)
        : -1;

      if (fmt === 'v3-rle') {
        for (const [y, x0, runs] of diff.rows) {
          let x = x0;
          for (const [idx, len] of runs) {
            if (idx === trIdx) {
              ctx.clearRect(x, y, len, 1);
            } else {
              ctx.fillStyle = this.palette[idx];
              ctx.fillRect(x, y, len, 1);
            }
            x += len;
          }
        }
      } else if (fmt === 'v2-flat') {
        for (const [x, y, idx] of diff.changes) {
          if (idx === trIdx) {
            ctx.clearRect(x, y, 1, 1);
          } else {
            ctx.fillStyle = this.palette[idx];
            ctx.fillRect(x, y, 1, 1);
          }
        }
      } else {
        for (const [x, y, color] of diff.changes) {
          if (typeof color === 'string' && color.toLowerCase() === TRANSPARENT_HEX) {
            ctx.clearRect(x, y, 1, 1);
          } else {
            ctx.fillStyle = color;
            ctx.fillRect(x, y, 1, 1);
          }
        }
      }
      return target;
    }
  }

  class Renderer {
    constructor(canvas) {
      this.gl = canvas.getContext('webgl', { antialias: false }) ||
                canvas.getContext('experimental-webgl', { antialias: false });
      if (!this.gl) { document.body.innerHTML = 'WebGL not supported'; return; }
      const gl = this.gl;
      const vs = gl.createShader(gl.VERTEX_SHADER);
      gl.shaderSource(vs, 'attribute vec2 a_position;attribute vec2 a_texCoord;varying vec2 v_texCoord;uniform mat3 u_matrix;void main(){vec3 p=u_matrix*vec3(a_position,1.0);gl_Position=vec4(p.xy,0.0,1.0);v_texCoord=a_texCoord;}');
      gl.compileShader(vs);
      if (!gl.getShaderParameter(vs, gl.COMPILE_STATUS)) { document.body.innerHTML = 'Vertex shader failed'; return; }
      const fs = gl.createShader(gl.FRAGMENT_SHADER);
      gl.shaderSource(fs, 'precision mediump float;varying vec2 v_texCoord;uniform sampler2D u_texture;void main(){gl_FragColor=texture2D(u_texture,v_texCoord);}');
      gl.compileShader(fs);
      if (!gl.getShaderParameter(fs, gl.COMPILE_STATUS)) { document.body.innerHTML = 'Fragment shader failed'; return; }
      const program = gl.createProgram();
      gl.attachShader(program, vs);
      gl.attachShader(program, fs);
      gl.linkProgram(program);
      if (!gl.getProgramParameter(program, gl.LINK_STATUS)) { document.body.innerHTML = 'Shader link failed'; return; }
      this.program = program;
      gl.enable(gl.BLEND);
      gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
      this.aPos = gl.getAttribLocation(program, 'a_position');
      this.aTex = gl.getAttribLocation(program, 'a_texCoord');
      this.uMatrix = gl.getUniformLocation(program, 'u_matrix');
      this.uTex = gl.getUniformLocation(program, 'u_texture');
      this.quadBuf = gl.createBuffer();
      gl.bindBuffer(gl.ARRAY_BUFFER, this.quadBuf);
      gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([0,0,0,0, 1,0,1,0, 0,1,0,1, 1,0,1,0, 0,1,0,1, 1,1,1,1]), gl.STATIC_DRAW);
      gl.enableVertexAttribArray(this.aPos);
      gl.vertexAttribPointer(this.aPos, 2, gl.FLOAT, false, 16, 0);
      gl.enableVertexAttribArray(this.aTex);
      gl.vertexAttribPointer(this.aTex, 2, gl.FLOAT, false, 16, 8);
      this.maxTex = gl.getParameter(gl.MAX_TEXTURE_SIZE);
      this.tiles = [];
      this.single = null;
      this._contextLost = false;

      canvas.addEventListener('webglcontextlost', e => {
        e.preventDefault();
        this._contextLost = true;
        console.warn('[gl] context lost — dropping caches to free memory');
        try {
          compositor.baseCache.clear();
          compositor.diffCache.clear();
          compositor.composeCanvas = null;
          compositor.composeCtx = null;
        } catch (_) {}
      }, false);
      canvas.addEventListener('webglcontextrestored', () => {
        console.warn('[gl] context restored — reloading to rebuild textures');
        window.location.reload();
      }, false);
    }
    setImage(img) {
      const gl = this.gl;
      this._cleanup();
      const w = img.width || img.naturalWidth;
      const h = img.height || img.naturalHeight;
      if (w <= this.maxTex && h <= this.maxTex) {
        const tex = gl.createTexture();
        gl.bindTexture(gl.TEXTURE_2D, tex);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, img);
        if (gl.getError() === gl.NO_ERROR) { this.single = { tex, w, h }; return; }
        gl.deleteTexture(tex);
      }
      const tileSize = Math.min(this.maxTex, 2048);
      const off = document.createElement('canvas');
      const ctx = pixelCtx(off);
      for (let y=0; y<h; y+=tileSize) {
        for (let x=0; x<w; x+=tileSize) {
          const tw = Math.min(tileSize, w-x), th = Math.min(tileSize, h-y);
          off.width = tw; off.height = th;
          ctx.imageSmoothingEnabled = false;
          ctx.drawImage(img, x, y, tw, th, 0, 0, tw, th);
          const tex = gl.createTexture();
          gl.bindTexture(gl.TEXTURE_2D, tex);
          gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
          gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
          gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
          gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
          gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, off);
          if (gl.getError() === gl.NO_ERROR) this.tiles.push({ tex, x, y, w: tw, h: th });
        }
      }
    }
    _cleanup() {
      this.tiles.forEach(t => this.gl.deleteTexture(t.tex));
      if (this.single) this.gl.deleteTexture(this.single.tex);
      this.tiles = []; this.single = null;
    }
    draw(offX, offY, scale, cssW, cssH) {
      if (this._contextLost) return;
      const gl = this.gl;
      gl.useProgram(this.program);
      gl.viewport(0, 0, gl.canvas.width, gl.canvas.height);
      const proj = new Float32Array([2/cssW, 0, 0, 0, -2/cssH, 0, -1, 1, 1]);
      const pan  = new Float32Array([1, 0, 0, 0, 1, 0, offX, offY, 1]);
      const zoom = new Float32Array([scale, 0, 0, 0, scale, 0, 0, 0, 1]);
      const tmp1 = new Float32Array(9), tmp2 = new Float32Array(9);
      matMul(pan, zoom, tmp1);
      matMul(proj, tmp1, tmp2);
      if (this.single) {
        gl.bindTexture(gl.TEXTURE_2D, this.single.tex);
        const imgScale = new Float32Array([this.single.w, 0, 0, 0, this.single.h, 0, 0, 0, 1]);
        const final = new Float32Array(9);
        matMul(tmp2, imgScale, final);
        gl.uniformMatrix3fv(this.uMatrix, false, final);
        gl.uniform1i(this.uTex, 0);
        gl.bindBuffer(gl.ARRAY_BUFFER, this.quadBuf);
        gl.drawArrays(gl.TRIANGLES, 0, 6);
      } else {
        gl.bindBuffer(gl.ARRAY_BUFFER, this.quadBuf);
        for (const t of this.tiles) {
          gl.bindTexture(gl.TEXTURE_2D, t.tex);
          const tileScale = new Float32Array([t.w, 0, 0, 0, t.h, 0, t.x, t.y, 1]);
          const final = new Float32Array(9);
          matMul(tmp2, tileScale, final);
          gl.uniformMatrix3fv(this.uMatrix, false, final);
          gl.uniform1i(this.uTex, 0);
          gl.drawArrays(gl.TRIANGLES, 0, 6);
        }
      }
    }
  }

  class Viewport {
    constructor(w, h) {
      this.w = w; this.h = h;
      this.scale = 1; this.offX = 0; this.offY = 0;
      this.minScale = 0.1; this.maxScale = 1000;
      this.dragging = false; this.dragStartX = 0; this.dragStartY = 0;
      this.dragOffX = 0; this.dragOffY = 0;
      this.pinching = false; this.pinchDist = 0; this.pinchScale = 1;
      this.pinchCx = 0; this.pinchCy = 0;
      this.onTapLeft = null; this.onTapRight = null;
    }
    reset(img) {
      const w = img.width || img.naturalWidth;
      const h = img.height || img.naturalHeight;
      this.scale = Math.min(this.w / w, this.h / h);
      this.offX = (this.w - w * this.scale) / 2;
      this.offY = (this.h - h * this.scale) / 2;
    }
    clientToImg(cx, cy) {
      return { x: Math.round((cx - this.offX) / this.scale), y: Math.round((cy - this.offY) / this.scale) };
    }
    imgToClient(ix, iy) {
      return { x: ix * this.scale + this.offX, y: iy * this.scale + this.offY };
    }
    updateSize(w, h) { this.w = w; this.h = h; }
    onPointerDown(e, clientX, clientY) {
      if (e.touches && e.touches.length === 2) {
        this.dragging = false; this.pinching = true;
        const dx = e.touches[1].clientX - clientX, dy = e.touches[1].clientY - clientY;
        this.pinchDist = Math.hypot(dx, dy);
        this.pinchScale = this.scale;
        this.pinchCx = (clientX + e.touches[1].clientX)/2;
        this.pinchCy = (clientY + e.touches[1].clientY)/2;
        return;
      }
      if (e.touches && e.touches.length === 1 || e.type === 'mousedown') {
        this.dragging = true;
        this.dragStartX = clientX; this.dragStartY = clientY;
        this.dragOffX = this.offX; this.dragOffY = this.offY;
      }
    }
    onPointerMove(e, clientX, clientY) {
      if (this.pinching && e.touches && e.touches.length === 2) {
        const t0 = e.touches[0], t1 = e.touches[1];
        const dx = t1.clientX - t0.clientX, dy = t1.clientY - t0.clientY;
        const nd = Math.hypot(dx, dy);
        if (this.pinchDist > 0) {
          const newScale = this.pinchScale * (nd / this.pinchDist);
          this.scale = Math.max(this.minScale, Math.min(this.maxScale, newScale));
          const cx = (t0.clientX + t1.clientX)/2, cy = (t0.clientY + t1.clientY)/2;
          const sc = this.scale / this.pinchScale;
          this.offX = cx - sc * (this.pinchCx - this.offX);
          this.offY = cy - sc * (this.pinchCy - this.offY);
          this.pinchCx = cx; this.pinchCy = cy;
          this.pinchScale = this.scale; this.pinchDist = nd;
        }
        return;
      }
      if (this.dragging) {
        this.offX = this.dragOffX + (clientX - this.dragStartX);
        this.offY = this.dragOffY + (clientY - this.dragStartY);
      }
    }
    onPointerUp(e) {
      if (this.pinching && e.touches && e.touches.length < 2) this.pinching = false;
      if (this.dragging) {
        this.dragging = false;
        if (e.changedTouches && e.changedTouches.length === 1 && !this.pinching) {
          const tx = e.changedTouches[0].clientX;
          const ty = e.changedTouches[0].clientY;
          if (Math.hypot(tx - this.dragStartX, ty - this.dragStartY) <= 5) {
            if (tx < window.innerWidth / 2) { if (this.onTapLeft) this.onTapLeft(); }
            else                            { if (this.onTapRight) this.onTapRight(); }
          }
        }
      }
    }
    onWheel(dy, x, y) {
      const old = this.scale;
      this.scale = dy < 0 ? this.scale * 1.1 : this.scale / 1.1;
      this.scale = Math.max(this.minScale, Math.min(this.maxScale, this.scale));
      const sc = this.scale / old;
      this.offX = x - sc * (x - this.offX);
      this.offY = y - sc * (y - this.offY);
    }
  }

  class SelectionManager {
    constructor(selCtx, viewport) {
      this.ctx = selCtx;
      this.vp = viewport;
      this.mode = false;
      this.start = null; this.end = null;
      this.dragging = false; this.handle = null;
      this.HANDLE = 8;
      selCanvas.style.pointerEvents = 'none';
    }
    getRect() {
      if (!this.start || !this.end) return null;
      return {
        x1: Math.min(this.start.x, this.end.x),
        y1: Math.min(this.start.y, this.end.y),
        x2: Math.max(this.start.x, this.end.x),
        y2: Math.max(this.start.y, this.end.y)
      };
    }
    toggle(on) {
      this.mode = on;
      selCanvas.style.pointerEvents = on ? 'auto' : 'none';
      if (!on) {
        this.start = this.end = null;
        this.handle = null;
        this.clear();
        dlPng.style.display = dlOverlay.style.display = 'none';
        coordsDiv.style.display = 'none';
      }
    }
    clear() { this.ctx.clearRect(0, 0, this.ctx.canvas.width, this.ctx.canvas.height); }
    draw() {
      this.clear();
      const r = this.getRect();
      if (!r) return;
      const s = this.vp.imgToClient(r.x1, r.y1);
      const e = this.vp.imgToClient(r.x2, r.y2);
      let x = Math.round(Math.min(s.x, e.x)), y = Math.round(Math.min(s.y, e.y));
      let w = Math.round(Math.abs(e.x - s.x)), h = Math.round(Math.abs(e.y - s.y));
      if (w < 1) w = 1; if (h < 1) h = 1;
      const ctx = this.ctx;
      ctx.fillStyle = 'rgba(255,255,0,0.1)'; ctx.fillRect(x, y, w, h);
      ctx.strokeStyle = '#FF0'; ctx.lineWidth = 1; ctx.strokeRect(x, y, w, h);
      const handles = [
        {x,y},{x:x+w,y},{x,y:y+h},{x:x+w,y:y+h},
        {x:x+w/2,y},{x:x+w/2,y:y+h},{x,y:y+h/2},{x:x+w,y:y+h/2}
      ];
      ctx.fillStyle = '#FFF'; ctx.strokeStyle = '#000';
      handles.forEach(h => {
        ctx.fillRect(h.x - this.HANDLE/2, h.y - this.HANDLE/2, this.HANDLE, this.HANDLE);
        ctx.strokeRect(h.x - this.HANDLE/2, h.y - this.HANDLE/2, this.HANDLE, this.HANDLE);
      });
      coordsDiv.style.display = 'inline-block';
      coordsDiv.textContent = `x: [${r.x1}, ${r.x2}]  y: [${r.y1}, ${r.y2}]`;
    }
    _clamp(p) {
      return {
        x: Math.max(0, Math.min(p.x, current.w)),
        y: Math.max(0, Math.min(p.y, current.h))
      };
    }
    hitHandle(clientX, clientY) {
      const r = this.getRect();
      if (!r) return null;
      const img = this.vp.clientToImg(clientX, clientY);
      const thresh = this.HANDLE / this.vp.scale;
      const {x1,y1,x2,y2} = r;
      const near = (a,b) => Math.abs(img.x - a) <= thresh && Math.abs(img.y - b) <= thresh;
      if (near(x1,y1)) return 'tl'; if (near(x2,y1)) return 'tr';
      if (near(x1,y2)) return 'bl'; if (near(x2,y2)) return 'br';
      if (Math.abs(img.x-x1)<=thresh && img.y>y1 && img.y<y2) return 'left';
      if (Math.abs(img.x-x2)<=thresh && img.y>y1 && img.y<y2) return 'right';
      if (Math.abs(img.y-y1)<=thresh && img.x>x1 && img.x<x2) return 'top';
      if (Math.abs(img.y-y2)<=thresh && img.x>x1 && img.x<x2) return 'bottom';
      if (img.x>x1 && img.x<x2 && img.y>y1 && img.y<y2) return 'move';
      return null;
    }
    dragStart(clientX, clientY) {
      const img = this._clamp(this.vp.clientToImg(clientX, clientY));
      if (this.start && this.end && this.getRect()) {
        this.handle = this.hitHandle(clientX, clientY);
        if (this.handle) return;
      }
      dlPng.style.display = dlOverlay.style.display = 'none';
      this.dragging = true;
      this.start = img; this.end = null; this.handle = null;
    }
    dragMove(clientX, clientY) {
      const img = this._clamp(this.vp.clientToImg(clientX, clientY));
      if (this.handle) this._dragHandle(img);
      else if (this.dragging) this.end = img;
      this.draw();
    }
    dragEnd() {
      this.dragging = false;
      if (this.start && this.end) {
        const r = this.getRect();
        if (r) {
          if (r.x2 - r.x1 < 1 && r.y2 - r.y1 < 1) {
            this.start = this.end = null;
            dlPng.style.display = dlOverlay.style.display = 'none';
          } else {
            dlPng.style.display = dlOverlay.style.display = 'inline-block';
          }
        }
      }
      this.handle = null;
      this.draw();
    }
    _dragHandle(img) {
      const r = this.getRect();
      if (!r) return;
      const {x1,y1,x2,y2} = r;
      switch(this.handle) {
        case 'tl': this.start={x:img.x,y:img.y}; this.end={x:x2,y:y2}; break;
        case 'tr': this.start={x:x1,y:img.y}; this.end={x:img.x,y:y2}; break;
        case 'bl': this.start={x:img.x,y:y1}; this.end={x:x2,y:img.y}; break;
        case 'br': this.start={x:x1,y:y1}; this.end={x:img.x,y:img.y}; break;
        case 'top': this.start={x:x1,y:img.y}; this.end={x:x2,y:y2}; break;
        case 'bottom': this.start={x:x1,y:y1}; this.end={x:x2,y:img.y}; break;
        case 'left': this.start={x:img.x,y:y1}; this.end={x:x2,y:y2}; break;
        case 'right': this.start={x:x1,y:y1}; this.end={x:img.x,y:y2}; break;
        case 'move': {
          const dx = img.x - (x1+x2)/2, dy = img.y - (y1+y2)/2;
          const w = x2-x1, h = y2-y1;
          const nx1 = Math.max(0, Math.min(x1+dx, current.w - w));
          const ny1 = Math.max(0, Math.min(y1+dy, current.h - h));
          this.start = {x:nx1, y:ny1}; this.end = {x:nx1+w, y:ny1+h};
          break;
        }
      }
    }
    getCroppedData(img) {
      const r = this.getRect();
      if (!r || r.x2-r.x1 < 1 || r.y2-r.y1 < 1) return null;
      const w = r.x2 - r.x1, h = r.y2 - r.y1;
      const off = document.createElement('canvas');
      off.width = w; off.height = h;
      const offCtx = off.getContext('2d');
      offCtx.imageSmoothingEnabled = false;
      offCtx.drawImage(img, r.x1, r.y1, w, h, 0, 0, w, h);
      return { dataUrl: off.toDataURL(), w, h, x: r.x1, y: r.y1 };
    }
  }

  class Navigator {
    constructor(entries) {
      this.all = entries.slice().sort((a, b) => epochFromName(a.name) - epochFromName(b.name));
      this.dayGroups = [];
      this.dayIdx = 0;
      this.withinIdx = 0;
      this.onLoadSnapshot = null;
      this.buildDayGroups();
      if (this.dayGroups.length) {
        this.dayIdx = this.dayGroups.length - 1;
        const g = this.dayGroups[this.dayIdx];
        this.withinIdx = g.entries.length - 1;
      }
    }
    buildDayGroups() {
      const map = new Map();
      for (const entry of this.all) {
        const ts = parseTimestamp(entry.name);
        const date = ts ? ts.date : 'unknown';
        if (!map.has(date)) map.set(date, []);
        map.get(date).push(entry);
      }
      this.dayGroups = Array.from(map.entries())
        .sort((a, b) => a[0].localeCompare(b[0]))
        .map(([date, entries]) => ({ date, entries }));
    }
    entryAt(d, w) {
      const group = this.dayGroups[d];
      if (!group) return null;
      return group.entries[w] || null;
    }
    currentEntry() { return this.entryAt(this.dayIdx, this.withinIdx); }
    currentName()  { return this.currentEntry()?.name ?? null; }
    fireLoad() {
      const entry = this.currentEntry();
      if (entry && this.onLoadSnapshot) this.onLoadSnapshot(entry);
    }
    setPosition(d, w) {
      if (d < 0 || d >= this.dayGroups.length) return;
      const group = this.dayGroups[d];
      if (!group) return;
      if (w < 0) w = 0;
      if (w >= group.entries.length) w = group.entries.length - 1;
      this.dayIdx = d;
      this.withinIdx = w;
      this.syncUI();
      this.fireLoad();
    }
    goToName(name) {
      for (let d = 0; d < this.dayGroups.length; d++) {
        const g = this.dayGroups[d];
        const w = g.entries.findIndex(e => e.name === name);
        if (w !== -1) {
          this.dayIdx = d;
          this.withinIdx = w;
          this.syncUI();
          this.fireLoad();
          return true;
        }
      }
      return false;
    }
    syncUI() {
      if (!this.dayGroups.length) return;
      const group = this.dayGroups[this.dayIdx];
      daySlider.max = Math.max(0, this.dayGroups.length - 1);
      daySlider.value = this.dayIdx;
      snapSlider.max = Math.max(0, group.entries.length - 1);
      snapSlider.value = this.withinIdx;

      const entry = this.currentEntry();
      if (entry) {
        const ts = parseTimestamp(entry.name);
        tsLabel.textContent = ts ? `${ts.date} ${ts.time}` : entry.name;
      }

      datePick.min = this.dayGroups[0].date;
      datePick.max = this.dayGroups[this.dayGroups.length - 1].date;
      datePick.value = group.date;

      if (timeSel.dataset.date !== group.date) {
        timeSel.dataset.date = group.date;
        timeSel.innerHTML = '<option value="">Select time...</option>';
        for (const e of group.entries) {
          const ts = parseTimestamp(e.name);
          const o = document.createElement('option');
          o.value = e.name;
          o.text = ts ? ts.time : e.name;
          timeSel.appendChild(o);
        }
      }
      timeSel.style.display = 'inline-block';
      if (entry) timeSel.value = entry.name;
    }
  }

  const renderer = new Renderer(canvas);
  const viewport = new Viewport(window.innerWidth, window.innerHeight);
  const selection = new SelectionManager(selCtx, viewport);
  const compositor = new Compositor(IS_IOS
    ? { maxBases: 1, maxDiffs: 24 }
    : { maxBases: 4, maxDiffs: 128 });
  let nav = null;
  let currentSource = null;
  let initialLoadDone = false;

  viewport.onTapLeft = () => {
    if (!nav) return;
    if (nav.withinIdx > 0) nav.setPosition(nav.dayIdx, nav.withinIdx - 1);
    else if (nav.dayIdx > 0) {
      const prev = nav.dayGroups[nav.dayIdx - 1];
      nav.setPosition(nav.dayIdx - 1, prev.entries.length - 1);
    }
  };
  viewport.onTapRight = () => {
    if (!nav) return;
    const g = nav.dayGroups[nav.dayIdx];
    if (g && nav.withinIdx < g.entries.length - 1) nav.setPosition(nav.dayIdx, nav.withinIdx + 1);
    else if (nav.dayIdx < nav.dayGroups.length - 1) nav.setPosition(nav.dayIdx + 1, 0);
  };

  let inFlight = false;
  let pendingEntry = null;

  async function loadSourceFor(entry) {
    let source;
    if (entry.kind === 'png') {
      const p = loadImage(BASE_URL + entry.src);
      compositor.registerBase(entry.time, p);
      source = await p;
    } else if (entry.kind === 'diff') {
      if (!compositor.hasBase(entry.base)) {
        const baseEntry = nav.all.find(e => e.kind === 'png' && e.time === entry.base);
        if (!baseEntry) throw new Error('base entry missing from manifest: ' + entry.base);
        const p = loadImage(BASE_URL + baseEntry.src);
        compositor.registerBase(baseEntry.time, p);
      }
      source = await compositor.compose(entry);
    } else {
      source = await loadImage(BASE_URL + entry.name);
    }
    return source;
  }

  function prefetchNeighbors(entry) {
    if (IS_IOS) return;
    const g = nav.dayGroups[nav.dayIdx];
    if (!g) return;
    const idx = g.entries.indexOf(entry);
    if (idx === -1) return;
    const targets = [];
    if (idx > 0) targets.push(g.entries[idx - 1]);
    if (idx < g.entries.length - 1) targets.push(g.entries[idx + 1]);
    if (idx === 0 && nav.dayIdx > 0) {
      const prev = nav.dayGroups[nav.dayIdx - 1].entries;
      if (prev.length) targets.push(prev[prev.length - 1]);
    }
    if (idx === g.entries.length - 1 && nav.dayIdx < nav.dayGroups.length - 1) {
      const next = nav.dayGroups[nav.dayIdx + 1].entries;
      if (next.length) targets.push(next[0]);
    }
    for (const t of targets) {
      if (t.kind === 'diff') {
        compositor.getDiff(t.src).catch(() => {});
      }
    }
  }

  async function onLoadSnapshot(entry) {
    pendingEntry = entry;
    if (inFlight) return;
    inFlight = true;
    try {
      while (pendingEntry) {
        const target = pendingEntry;
        pendingEntry = null;
        try {
          const source = await loadSourceFor(target);
          if (!pendingEntry) {
            applySource(source);
            prefetchNeighbors(target);
          }
        } catch (e) {
          console.error('load failed:', target, e);
          if (!pendingEntry) tsLabel.textContent = 'load failed';
        }
      }
    } finally {
      inFlight = false;
    }
  }

  function applySource(source) {
    const prevRanges = current.ranges;
    const hadImage = initialLoadDone;
    currentSource = source;
    current.w = source.width || source.naturalWidth;
    current.h = source.height || source.naturalHeight;
    current.ranges = rangesForSize(current.w, current.h);
    if (hadImage && (prevRanges.col !== current.ranges.col || prevRanges.row !== current.ranges.row)) {
      const dx = (current.ranges.col - prevRanges.col) * TILE;
      const dy = (current.ranges.row - prevRanges.row) * TILE;
      viewport.offX += dx * viewport.scale;
      viewport.offY += dy * viewport.scale;
    }
    renderer.setImage(source);
    if (!initialLoadDone) {
      if (pendingSavedViewport) {
        viewport.offX = pendingSavedViewport.x;
        viewport.offY = pendingSavedViewport.y;
        viewport.scale = pendingSavedViewport.zoom;
        pendingSavedViewport = null;
      } else {
        viewport.reset(source);
      }
      initialLoadDone = true;
    }
    draw();
  }

  function draw() {
    if (renderer._contextLost) return;
    const bg = dataset === 'antarktika' ? [0.9725,0.9569,0.9412,1] : [0.627,0.741,1.0,1];
    renderer.gl.clearColor(...bg);
    renderer.gl.clear(renderer.gl.COLOR_BUFFER_BIT);
    renderer.draw(viewport.offX, viewport.offY, viewport.scale, window.innerWidth, window.innerHeight);
    if (!selection.mode) selCtx.clearRect(0, 0, selCanvas.width, selCanvas.height);
  }

  function addEvents() {
    const el = canvas;
    el.addEventListener('mousedown', e => {
      if (selection.mode) return;
      e.preventDefault();
      viewport.onPointerDown(e, e.clientX, e.clientY);
      el.style.cursor = 'grabbing';
    });
    window.addEventListener('mousemove', e => {
      if (selection.mode) return;
      if (viewport.dragging) { viewport.onPointerMove(e, e.clientX, e.clientY); draw(); }
    });
    window.addEventListener('mouseup', e => {
      if (selection.mode) return;
      viewport.onPointerUp(e);
      el.style.cursor = 'grab';
      draw();
    });
    el.addEventListener('touchstart', e => {
      if (selection.mode) return;
      e.preventDefault();
      viewport.onPointerDown(e, e.touches[0]?.clientX, e.touches[0]?.clientY);
    }, {passive:false});
    el.addEventListener('touchmove', e => {
      if (selection.mode) return;
      e.preventDefault();
      viewport.onPointerMove(e, e.touches[0]?.clientX, e.touches[0]?.clientY);
      draw();
    }, {passive:false});
    el.addEventListener('touchend', e => {
      if (selection.mode) return;
      viewport.onPointerUp(e);
      draw();
    });
    el.addEventListener('wheel', e => {
      if (selection.mode) return;
      e.preventDefault();
      viewport.onWheel(e.deltaY, e.clientX, e.clientY);
      draw();
    }, {passive:false});
    selCanvas.addEventListener('mousedown', e => { e.preventDefault(); selection.dragStart(e.clientX, e.clientY); selection.draw(); });
    selCanvas.addEventListener('mousemove', e => selection.dragMove(e.clientX, e.clientY));
    selCanvas.addEventListener('mouseup', () => selection.dragEnd());
    selCanvas.addEventListener('touchstart', e => {
      e.preventDefault();
      const t = e.touches[0];
      selection.dragStart(t.clientX, t.clientY);
      selection.draw();
    }, {passive:false});
    selCanvas.addEventListener('touchmove', e => {
      e.preventDefault();
      const t = e.touches[0];
      selection.dragMove(t.clientX, t.clientY);
    }, {passive:false});
    selCanvas.addEventListener('touchend', () => selection.dragEnd());
  }
  addEvents();

  dlSnap.addEventListener('click', async () => {
    const entry = nav.currentEntry();
    if (!entry) return;
    if (entry.kind === 'png' && entry.src) {
      const a = document.createElement('a');
      a.href = BASE_URL + entry.src; a.download = entry.src;
      document.body.appendChild(a); a.click(); document.body.removeChild(a);
    } else if (entry.kind === 'diff') {
      try {
        const c = await compositor.compose(entry, { fresh: true });
        c.toBlob(blob => {
          const url = URL.createObjectURL(blob);
          const a = document.createElement('a');
          a.href = url; a.download = `wdpsnapshot_${entry.name}.png`;
          document.body.appendChild(a); a.click(); document.body.removeChild(a);
          URL.revokeObjectURL(url);
        });
      } catch (e) { alert('compose failed: ' + e.message); }
    } else {
      const a = document.createElement('a');
      a.href = BASE_URL + entry.name; a.download = entry.name;
      document.body.appendChild(a); a.click(); document.body.removeChild(a);
    }
  });

  copyLinkBtn.addEventListener('click', () => {
    const name = nav.currentName();
    if (!name) return;
    const url = new URL(window.location);
    url.searchParams.set('snap', name);
    url.searchParams.set('x', viewport.offX.toFixed(1));
    url.searchParams.set('y', viewport.offY.toFixed(1));
    url.searchParams.set('zoom', viewport.scale.toFixed(4));
    navigator.clipboard.writeText(url.href).then(() => {
      copyLinkBtn.textContent = 'copied!';
      setTimeout(() => { copyLinkBtn.textContent = 'copy link'; }, 1500);
    }).catch(err => alert('Failed to copy link: ' + err));
  });

  dlToggle.addEventListener('click', () => {
    selection.toggle(!selection.mode);
    dlToggle.textContent = selection.mode ? 'done' : 'select area';
  });

  dlPng.addEventListener('click', () => {
    if (!currentSource) return;
    const data = selection.getCroppedData(currentSource);
    if (!data) return;
    const a = document.createElement('a');
    a.href = data.dataUrl; a.download = 'selection.png';
    document.body.appendChild(a); a.click(); document.body.removeChild(a);
  });

  dlOverlay.addEventListener('click', () => {
    if (!currentSource) return;
    const data = selection.getCroppedData(currentSource);
    if (!data) return;
    const bounds = cropToBounds(data.x, data.y, data.w, data.h);
    const ts = parseTimestamp(nav.currentName() || '')?.epoch ?? Date.now();
    const overlay = {
      id: `${dataset}_custom_${ts}`, schemaVersion:"1", name:`custom_${ts}.png`,
      opacity:1, image:{dataUrl:data.dataUrl, width:data.w, height:data.h},
      bounds, colorMetric:"lab", dithering:false, order:0, locked:false,
      hasPlaced:true, visible:true
    };
    const blob = new Blob([JSON.stringify(overlay)], {type:'application/json'});
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url; a.download = `${dataset}_custom_${ts}.wplace`;
    document.body.appendChild(a); a.click(); document.body.removeChild(a);
    URL.revokeObjectURL(url);
  });

  window.addEventListener('keydown', e => {
    if (!nav) return;
    if (e.key === 'ArrowLeft') {
      e.preventDefault();
      if (nav.withinIdx > 0) nav.setPosition(nav.dayIdx, nav.withinIdx - 1);
      else if (nav.dayIdx > 0) {
        const prev = nav.dayGroups[nav.dayIdx - 1];
        nav.setPosition(nav.dayIdx - 1, prev.entries.length - 1);
      }
    } else if (e.key === 'ArrowRight') {
      e.preventDefault();
      const g = nav.dayGroups[nav.dayIdx];
      if (g && nav.withinIdx < g.entries.length - 1) nav.setPosition(nav.dayIdx, nav.withinIdx + 1);
      else if (nav.dayIdx < nav.dayGroups.length - 1) nav.setPosition(nav.dayIdx + 1, 0);
    } else if (e.key === 'r' || e.key === 'R') {
      e.preventDefault();
      if (currentSource) { viewport.reset(currentSource); draw(); }
    }
  });

  let debounceTimer = null;
  function debouncedFire() {
    clearTimeout(debounceTimer);
    debounceTimer = setTimeout(() => { if (nav) nav.fireLoad(); }, 150);
  }

  daySlider.addEventListener('input', () => {
    if (!nav) return;
    const idx = parseInt(daySlider.value, 10);
    if (isNaN(idx) || idx === nav.dayIdx) return;
    nav.dayIdx = idx;
    nav.withinIdx = 0;
    nav.syncUI();
    debouncedFire();
  });
  snapSlider.addEventListener('input', () => {
    if (!nav) return;
    const idx = parseInt(snapSlider.value, 10);
    const g = nav.dayGroups[nav.dayIdx];
    if (!g || isNaN(idx) || idx < 0 || idx >= g.entries.length) return;
    if (idx === nav.withinIdx) return;
    nav.withinIdx = idx;
    nav.syncUI();
    debouncedFire();
  });

  datePick.addEventListener('change', () => {
    if (!nav) return;
    const d = nav.dayGroups.findIndex(g => g.date === datePick.value);
    if (d !== -1) nav.setPosition(d, 0);
  });
  timeSel.addEventListener('change', () => {
    if (!nav) return;
    const name = timeSel.value;
    if (name) nav.goToName(name);
  });

  function onResize() {
    const dpr = window.devicePixelRatio || 1;
    const w = window.innerWidth, h = window.innerHeight;
    canvas.width = w * dpr; canvas.height = h * dpr;
    canvas.style.width = w+'px'; canvas.style.height = h+'px';
    selCanvas.width = w; selCanvas.height = h;
    selCanvas.style.width = w+'px'; selCanvas.style.height = h+'px';
    viewport.updateSize(w, h);
    draw();
  }
  window.addEventListener('resize', onResize);
  onResize();

  function loadManifest() {
    return fetchJson(BASE_URL + urlTimeline)
      .then(entries => {
        if (!Array.isArray(entries)) throw new Error('bad timeline');
        console.log(`[manifest] timeline.json: ${entries.length} entries`);
        return entries;
      });
  }

  loadManifest()
    .then(entries => Promise.all([
      Promise.resolve(entries),
      fetchJson(BASE_URL + 'palette.json').catch(() => null),
    ]))
    .then(([entries, palette]) => {
      if (palette) {
        compositor.setPalette(palette);
        console.log(`[palette] ${palette.length} colors loaded`);
      } else {
        console.log('[palette] not found; v2/v3 diffs will fail to render');
      }
      if (!entries.length) { tsLabel.textContent = 'No snapshots.'; return; }

      nav = new Navigator(entries);
      nav.onLoadSnapshot = onLoadSnapshot;
      console.log(`[nav] ${nav.dayGroups.length} days, latest ${nav.dayGroups[nav.dayGroups.length-1].date}`);

      const urlEntry = urlSnap ? nav.all.find(e => e.name === urlSnap) : null;
      if (urlEntry && nav.goToName(urlEntry.name)) {
        // navigated
      } else {
        nav.syncUI();
        nav.fireLoad();
      }
    })
    .catch(e => { tsLabel.textContent = 'Failed to load data'; console.error(e); });

})();