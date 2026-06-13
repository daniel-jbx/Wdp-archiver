(function() {
  // ── DOM refs ───────────────────────────────────────────────
  const canvas    = document.getElementById('canvas');
  const selCanvas = document.getElementById('sel-canvas');
  const slider    = document.getElementById('slider');
  const tsLabel   = document.getElementById('timestamp-label-top');
  const interval  = document.getElementById('interval-select');
  const datePick  = document.getElementById('date-picker');
  const timeSel   = document.getElementById('time-select');
  const dlSnap    = document.getElementById('dl-snapshot');
  const dlToggle  = document.getElementById('dl-select-toggle');
  const dlPng     = document.getElementById('dl-select-png');
  const dlOverlay = document.getElementById('dl-select-overlay');
  const diffBtn   = document.getElementById('diff-btn');
  const coordsDiv = document.getElementById('coords-display');
  const selCtx    = selCanvas.getContext('2d');

  // ── Dataset & constants ────────────────────────────────────
  const dataset  = location.pathname.includes('/antarktika/') ? 'antarktika' : 'wdp';
  const BASE_URL = `https://pub-e0766eb5f5114fc097a10215d5e6081b.r2.dev/${dataset === 'wdp' ? '' : 'antarktika/'}`;
  const ZOOM = 11, TILE = 1000, WORLD = Math.pow(2, ZOOM) * TILE;
  const ranges = {
    wdp:        { col:1225, row:513, cols:7, rows:6 },
    antarktika: { col:1279, row:1715, cols:6, rows:5 }
  }[dataset];
  const IMG_W = ranges.cols * TILE, IMG_H = ranges.rows * TILE;

  function pixelToLatLon(px, py) {
    const gx = ranges.col * TILE + px, gy = ranges.row * TILE + py;
    const y = 1 - 2 * gy / WORLD, lon = (gx / WORLD) * 360 - 180;
    const lat = (2 * Math.atan(Math.exp(Math.PI * y)) - Math.PI / 2) * 180 / Math.PI;
    return { lat, lon };
  }
  function cropToBounds(x, y, w, h) {
    const nw = pixelToLatLon(x, y), se = pixelToLatLon(x + w, y + h);
    return { north: nw.lat, south: se.lat, west: nw.lon, east: se.lon };
  }
  function epochFromName(name) {
    const m = name.match(/(\d{8})_(\d{6})/);
    if (!m) return 0;
    const d = m[1], t = m[2];
    return Date.UTC(d.slice(0,4), d.slice(4,6)-1, d.slice(6,8),
                    t.slice(0,2), t.slice(2,4), t.slice(4,6)) / 1000;
  }

  // ── Renderer (WebGL) ───────────────────────────────────────
  class Renderer {
    constructor(canvas) {
      this.gl = canvas.getContext('webgl', { antialias: false }) ||
                canvas.getContext('experimental-webgl', { antialias: false });
      if (!this.gl) { document.body.innerHTML = 'WebGL not supported'; return; }
      const gl = this.gl;

      // Compile vertex shader
      const vs = gl.createShader(gl.VERTEX_SHADER);
      gl.shaderSource(vs,
        'attribute vec2 a_position;attribute vec2 a_texCoord;varying vec2 v_texCoord;uniform mat3 u_matrix;void main(){vec3 p=u_matrix*vec3(a_position,1.0);gl_Position=vec4(p.xy,0.0,1.0);v_texCoord=a_texCoord;}');
      gl.compileShader(vs);
      if (!gl.getShaderParameter(vs, gl.COMPILE_STATUS)) {
        console.error('Vertex shader error:', gl.getShaderInfoLog(vs));
        document.body.innerHTML = 'Vertex shader failed';
        return;
      }

      // Compile fragment shader
      const fs = gl.createShader(gl.FRAGMENT_SHADER);
      gl.shaderSource(fs,
        'precision mediump float;varying vec2 v_texCoord;uniform sampler2D u_texture;void main(){gl_FragColor=texture2D(u_texture,v_texCoord);}');
      gl.compileShader(fs);
      if (!gl.getShaderParameter(fs, gl.COMPILE_STATUS)) {
        console.error('Fragment shader error:', gl.getShaderInfoLog(fs));
        document.body.innerHTML = 'Fragment shader failed';
        return;
      }

      // Link program
      const program = gl.createProgram();
      gl.attachShader(program, vs);
      gl.attachShader(program, fs);
      gl.linkProgram(program);
      if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
        console.error('Program link error:', gl.getProgramInfoLog(program));
        document.body.innerHTML = 'Shader link failed';
        return;
      }

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
    }

    setImage(img) {
      const gl = this.gl;
      this._cleanup();
      if (img.width <= this.maxTex && img.height <= this.maxTex) {
        const tex = gl.createTexture();
        gl.bindTexture(gl.TEXTURE_2D, tex);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, img);
        if (gl.getError() === gl.NO_ERROR) {
          this.single = { tex, w:img.width, h:img.height };
          return;
        }
        gl.deleteTexture(tex);
      }
      const tileSize = Math.min(this.maxTex, 2048);
      const off = document.createElement('canvas');
      const ctx = off.getContext('2d');
      for (let y=0; y<img.height; y+=tileSize) {
        for (let x=0; x<img.width; x+=tileSize) {
          const w = Math.min(tileSize, img.width-x), h = Math.min(tileSize, img.height-y);
          off.width = w; off.height = h;
          ctx.drawImage(img, x, y, w, h, 0, 0, w, h);
          const tex = gl.createTexture();
          gl.bindTexture(gl.TEXTURE_2D, tex);
          gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
          gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
          gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
          gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
          gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, off);
          if (gl.getError() === gl.NO_ERROR) this.tiles.push({ tex, x, y, w, h });
        }
      }
    }

    _cleanup() {
      this.tiles.forEach(t => this.gl.deleteTexture(t.tex));
      if (this.single) this.gl.deleteTexture(this.single.tex);
      this.tiles = []; this.single = null;
    }

    draw(offX, offY, scale, cssW, cssH) {
      const gl = this.gl;
      gl.useProgram(this.program);
      gl.viewport(0, 0, gl.canvas.width, gl.canvas.height);
      const proj = new Float32Array([2/cssW, 0, 0, 0, -2/cssH, 0, -1, 1, 1]);
      const pan  = new Float32Array([1, 0, 0, 0, 1, 0, offX, offY, 1]);
      const zoom = new Float32Array([scale, 0, 0, 0, scale, 0, 0, 0, 1]);
      const matMul = (a, b, out) => {
        for (let c=0; c<3; c++) {
          let b0 = b[c*3], b1 = b[c*3+1], b2 = b[c*3+2];
          for (let r=0; r<3; r++) out[c*3+r] = a[r]*b0 + a[3+r]*b1 + a[6+r]*b2;
        }
      };
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

  // ── Viewport (pan/zoom) ────────────────────────────────────
  class Viewport {
    constructor(renderer, w, h) {
      this.renderer = renderer;
      this.w = w; this.h = h;
      this.scale = 1; this.offX = 0; this.offY = 0;
      this.minScale = 0.1; this.maxScale = 100;
      this.dragging = false; this.dragStartX = 0; this.dragStartY = 0;
      this.dragOffX = 0; this.dragOffY = 0; this.dragOccurred = false;
      this.pinching = false; this.pinchDist = 0; this.pinchScale = 1;
      this.pinchCx = 0; this.pinchCy = 0;
      this.tapStartX = 0; this.tapStartY = 0; this.wasDragged = false;
      this.onTapLeft  = null;
      this.onTapRight = null;
      this.onClick    = null;
    }

    reset(img) {
      this.scale = Math.min(this.w / img.width, this.h / img.height);
      this.offX = (this.w - img.width * this.scale) / 2;
      this.offY = (this.h - img.height * this.scale) / 2;
    }

    clientToImg(cx, cy) {
      return {
        x: Math.round((cx - this.offX) / this.scale),
        y: Math.round((cy - this.offY) / this.scale)
      };
    }
    imgToClient(ix, iy) {
      return { x: ix * this.scale + this.offX, y: iy * this.scale + this.offY };
    }

    updateSize(w, h) { this.w = w; this.h = h; }

    onPointerDown(e, clientX, clientY) {
      if (e.touches && e.touches.length === 2) {
        this.dragging = false;
        this.pinching = true;
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
        this.dragOccurred = false;
        if (e.touches) {
          this.tapStartX = clientX; this.tapStartY = clientY;
          this.wasDragged = false;
        }
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
        const dx = clientX - this.dragStartX, dy = clientY - this.dragStartY;
        if (Math.hypot(dx, dy) > 5) this.dragOccurred = true;
        this.offX = this.dragOffX + dx;
        this.offY = this.dragOffY + dy;
      }
    }

    onPointerUp(e, clientX, clientY) {
      if (this.pinching && e.touches && e.touches.length < 2) {
        this.pinching = false;
      }
      if (this.dragging) {
        this.dragging = false;
        if (e.changedTouches && e.changedTouches.length === 1 && !this.pinching) {
          const tx = e.changedTouches[0].clientX;
          if (!this.wasDragged && Math.hypot(tx - this.tapStartX, e.changedTouches[0].clientY - this.tapStartY) <= 5) {
            if (tx < window.innerWidth/2) { if (this.onTapLeft) this.onTapLeft(); }
            else { if (this.onTapRight) this.onTapRight(); }
          }
          this.wasDragged = false;
        }
        if (e.type === 'mouseup' && !this.dragOccurred) {
          if (this.onClick) this.onClick(clientX, clientY);
        }
      }
    }

    onWheel(dy, x, y) {
      const factor = 1.1;
      const old = this.scale;
      this.scale = dy < 0 ? this.scale * factor : this.scale / factor;
      this.scale = Math.max(this.minScale, Math.min(this.maxScale, this.scale));
      const sc = this.scale / old;
      this.offX = x - sc * (x - this.offX);
      this.offY = y - sc * (y - this.offY);
    }
  }

  // ── Selection Manager ──────────────────────────────────────
class SelectionManager {
  constructor(selCtx, viewport) {
    this.ctx = selCtx;
    this.vp = viewport;
    this.mode = false;
    this.start = null; this.end = null;
    this.dragging = false; this.handle = null;
    this.HANDLE = 8;
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
    if (!on) {
      this.start = this.end = null;
      this.handle = null;
      this.clear();
      dlPng.style.display = dlOverlay.style.display = 'none';
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

  _clamp(p) { return { x: Math.max(0, Math.min(p.x, IMG_W)), y: Math.max(0, Math.min(p.y, IMG_H)) }; }

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
      if (this.handle) return; // resizing an existing selection – keep buttons visible
    }
    // Starting a new selection – hide any previous download buttons
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
          // selection is just a single point – hide buttons
          this.start = this.end = null;
          dlPng.style.display = dlOverlay.style.display = 'none';
        } else {
          // valid selection – show download buttons
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
        let nx1 = Math.max(0, Math.min(x1+dx, IMG_W-w)), ny1 = Math.max(0, Math.min(y1+dy, IMG_H-h));
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
    off.getContext('2d').drawImage(img, r.x1, r.y1, w, h, 0, 0, w, h);
    return { dataUrl: off.toDataURL(), w, h, x: r.x1, y: r.y1 };
  }
}

  // ── Filter / Timeline controller ──────────────────────────
  class FilterController {
    constructor(allSnapshots) {
      this.all = allSnapshots;
      this.filtered = [];
      this.currentIndex = -1;
      this.intervalSec = 3600;
      this.customList = null;
      this._sliderMap = {};
    }

    setCustomList(list) {
      this.customList = list;
      this._rebuild();
    }

    setInterval(minutes) {
      this.intervalSec = minutes * 60;
      if (!this.customList) this._rebuild();
    }

    rebuildWithAnchor(anchorName) { this._buildFiltered(anchorName); }

    _rebuild() { this._buildFiltered(null); }

    _buildFiltered(anchorName) {
      if (this.customList) {
        this.filtered = this.customList;
        this._updateSlider();
        const idx = anchorName ? this.filtered.indexOf(anchorName) : -1;
        this.load(idx >= 0 ? idx : this.filtered.length - 1);
        return;
      }
      const interval = this.intervalSec;
      if (!interval || this.all.length === 0) {
        this.filtered = this.all.sort((a,b) => epochFromName(a) - epochFromName(b));
        this._updateSlider();
        let idx = anchorName ? this.filtered.indexOf(anchorName) : -1;
        if (idx === -1) idx = this.filtered.length - 1;
        this.load(idx);
        return;
      }
      const cands = this.all.map(n => ({name:n, ep:epochFromName(n)})).sort((a,b)=>a.ep-b.ep);
      const anchorIdx = anchorName ? cands.findIndex(c=>c.name===anchorName) : cands.length-1;
      if (anchorIdx === -1) { this.load(0); return; }
      const anchorEp = cands[anchorIdx].ep;
      const selected = new Map();
      selected.set(anchorEp, cands[anchorIdx].name);
      const minEp = cands[0].ep, maxEp = cands[cands.length-1].ep;
      for (let k = Math.ceil((minEp-anchorEp)/interval); k <= Math.floor((maxEp-anchorEp)/interval); k++) {
        if (k === 0) continue;
        const target = anchorEp + k * interval;
        let l=0, r=cands.length-1;
        while(l<=r){ let m=(l+r)>>1; if(cands[m].ep<target) l=m+1; else r=m-1; }
        let best = null, bestDiff=Infinity;
        if(l<cands.length){ let d=Math.abs(cands[l].ep-target); if(d<bestDiff){ bestDiff=d; best=cands[l]; } }
        if(l-1>=0){ let d=Math.abs(cands[l-1].ep-target); if(d<bestDiff){ bestDiff=d; best=cands[l-1]; } }
        if(best && !selected.has(best.ep)) selected.set(best.ep, best.name);
      }
      this.filtered = Array.from(selected.keys()).sort((a,b)=>a-b).map(ep=>selected.get(ep));
      this._updateSlider();
      let targetIdx = this.filtered.indexOf(cands[anchorIdx].name);
      if (targetIdx === -1) targetIdx = this.filtered.length-1;
      this.load(targetIdx);
    }

    _updateSlider() {
      this._sliderMap = {};
      this.filtered.forEach((name,i) => this._sliderMap[i] = name);
      slider.max = Math.max(0, this.filtered.length - 1);
    }

    load(idx) {
      if (idx < 0 || idx >= this.filtered.length) return;
      this.currentIndex = idx;
      slider.value = idx;
      const name = this._sliderMap[idx];
      if (!name) return;
      const m = name.match(/(\d{8})_(\d{6})/);
      tsLabel.textContent = m ? `${m[1].slice(0,4)}-${m[1].slice(4,6)}-${m[1].slice(6,8)} ${m[2].slice(0,2)}:${m[2].slice(2,4)}:${m[2].slice(4,6)}` : name;
      if (this.onLoadSnapshot) this.onLoadSnapshot(name);
    }

    currentName() { return this._sliderMap[this.currentIndex]; }
  }

  // ── Diff Manager ──────────────────────────────────────────
  class DiffManager {
    constructor(diffs, filterCtrl, viewport) {
      this.diffs = diffs;
      this.fc = filterCtrl;
      this.vp = viewport;
      this.active = false;
      this.locked = false;
      this.pixel = null;
    }

    toggle(on) {
      this.active = on;
      if (on) {
        diffBtn.textContent = 'done';
        canvas.classList.add('diff-mode');
        interval.disabled = true; interval.style.display = 'none';
        if (datePick) { datePick.disabled = true; datePick.style.display = 'none'; }
        if (timeSel) { timeSel.disabled = true; timeSel.style.display = 'none'; }
        selCtx.clearRect(0, 0, selCanvas.width, selCanvas.height);
        tsLabel.style.background = 'rgba(76,175,80,0.8)';
        tsLabel.style.padding = '2px 6px';
        tsLabel.style.borderRadius = '4px';
        this.pixel = null;
        this.locked = false;
        dlToggle.style.display = 'none';                // hide select area
      } else {
        diffBtn.textContent = 'diff';
        canvas.classList.remove('diff-mode');
        interval.disabled = false; interval.style.display = '';
        if (datePick) { datePick.disabled = false; datePick.style.display = ''; }
        if (timeSel) { timeSel.disabled = false; timeSel.style.display = ''; }
        tsLabel.style.background = '';
        tsLabel.style.padding = '';
        this.fc.setCustomList(null);
        dlToggle.style.display = '';                    // show select area
      }
    }

    selectPixel(clientX, clientY) {
      if (!this.active || this.locked) return false;
      const p = this.vp.clientToImg(clientX, clientY);
      if (p.x < 0 || p.x >= IMG_W || p.y < 0 || p.y >= IMG_H) return false;

      this.pixel = p;
      draw();

      const key = `${p.x},${p.y}`;
      const idxs = this.diffs[key] || [];
      if (idxs.length === 0) {
        alert('This pixel never changed across snapshots.');
        return false;
      }

      this.locked = true;
      const changedSnaps = [0, ...idxs].map(i => this.fc.all[i]).filter(Boolean);
      this.fc.setCustomList(changedSnaps);
      return true;
    }

    drawMarker(ctx) {
      if (!this.pixel || !this.active) return;
      ctx.save();
      const sc = this.vp.scale;
      const s = this.vp.imgToClient(this.pixel.x, this.pixel.y);
      const w = Math.max(1, sc), h = Math.max(1, sc);
      ctx.imageSmoothingEnabled = false;
      ctx.strokeStyle = 'red'; ctx.lineWidth = 1;
      ctx.strokeRect(s.x, s.y, w, h);
      ctx.fillStyle = 'rgba(255,0,0,0.3)';
      ctx.fillRect(s.x, s.y, w, h);
      ctx.restore();
    }
  }

  // ── Application setup ────────────────────────────────────
  const renderer = new Renderer(canvas);
  const viewport = new Viewport(renderer, window.innerWidth, window.innerHeight);
  const selection = new SelectionManager(selCtx, viewport);
  const filterCtrl = new FilterController([]);
  let diffMgr = null;
  const currentImage = new Image();
  currentImage.crossOrigin = 'anonymous';
  let initialLoadDone = false;

  // Wire viewport callbacks
  viewport.onTapLeft = () => {
    if (filterCtrl.currentIndex > 0) filterCtrl.load(filterCtrl.currentIndex - 1);
  };
  viewport.onTapRight = () => {
    if (filterCtrl.currentIndex < filterCtrl.filtered.length - 1) filterCtrl.load(filterCtrl.currentIndex + 1);
  };
  viewport.onClick = (x, y) => {
    if (diffMgr && diffMgr.active) {
      if (diffMgr.selectPixel(x, y)) draw();
    }
  };

  filterCtrl.onLoadSnapshot = (name) => {
    currentImage.src = BASE_URL + name;
  };

  currentImage.onload = () => {
    renderer.setImage(currentImage);
    if (!initialLoadDone) {
      viewport.reset(currentImage);
      initialLoadDone = true;
    }
    draw();
  };
  currentImage.onerror = () => console.error('Image failed:', currentImage.src);

  function draw() {
    const bg = dataset === 'antarktika' ? [0.9725,0.9569,0.9412,1] : [0.627,0.741,1.0,1];
    renderer.gl.clearColor(...bg);
    renderer.gl.clear(renderer.gl.COLOR_BUFFER_BIT);
    renderer.draw(viewport.offX, viewport.offY, viewport.scale, window.innerWidth, window.innerHeight);
    if (!selection.mode && diffMgr && diffMgr.active) {
      diffMgr.drawMarker(selCtx);
    } else if (!selection.mode && !(diffMgr && diffMgr.active)) {
      selCtx.clearRect(0, 0, selCanvas.width, selCanvas.height);
    }
  }

  // ── Event wiring (immediate) ─────────────────────────────
  function addEvents() {
    const el = canvas;
    el.addEventListener('mousedown', e => {
      if (selection.mode) return;
      e.preventDefault();
      viewport.onPointerDown(e, e.clientX, e.clientY);
      if (!diffMgr || !diffMgr.active) el.style.cursor = 'grabbing';
    });
    window.addEventListener('mousemove', e => {
      if (selection.mode) return;
      if (viewport.dragging) {
        viewport.onPointerMove(e, e.clientX, e.clientY);
        draw();
      }
    });
    window.addEventListener('mouseup', e => {
      if (selection.mode) return;
      viewport.onPointerUp(e, e.clientX, e.clientY);
      el.style.cursor = (diffMgr && diffMgr.active) ? 'crosshair' : 'grab';
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
      viewport.onPointerUp(e, e.changedTouches[0]?.clientX, e.changedTouches[0]?.clientY);
      draw();
    });
    el.addEventListener('wheel', e => {
      if (selection.mode) return;
      e.preventDefault();
      viewport.onWheel(e.deltaY, e.clientX, e.clientY);
      draw();
    }, {passive:false});

    // Selection canvas events
    selCanvas.addEventListener('mousedown', e => {
      if (!selection.mode) return;
      e.preventDefault();
      selection.dragStart(e.clientX, e.clientY);
      selection.draw();
    });
    selCanvas.addEventListener('mousemove', e => {
      if (!selection.mode) return;
      selection.dragMove(e.clientX, e.clientY);
    });
    selCanvas.addEventListener('mouseup', () => { if (selection.mode) selection.dragEnd(); });
    selCanvas.addEventListener('touchstart', e => {
      if (!selection.mode) return;
      e.preventDefault();
      const t = e.touches[0];
      selection.dragStart(t.clientX, t.clientY);
      selection.draw();
    }, {passive:false});
    selCanvas.addEventListener('touchmove', e => {
      if (!selection.mode) return;
      e.preventDefault();
      const t = e.touches[0];
      selection.dragMove(t.clientX, t.clientY);
    }, {passive:false});
    selCanvas.addEventListener('touchend', () => { if (selection.mode) selection.dragEnd(); });
  }

  // Attach events immediately (does not depend on data)
  addEvents();

  // Download / UI buttons (also immediate)
  dlSnap.addEventListener('click', () => {
    const name = filterCtrl.currentName();
    if (!name) return;
    const a = document.createElement('a');
    a.href = BASE_URL + name; a.download = name;
    document.body.appendChild(a); a.click(); document.body.removeChild(a);
  });

  dlToggle.addEventListener('click', () => {
    selection.toggle(!selection.mode);
    if (selection.mode) {
      dlToggle.textContent = 'done';
      selCanvas.style.pointerEvents = 'auto';
      diffBtn.style.display = 'none';
    } else {
      dlToggle.textContent = 'select area';
      selCanvas.style.pointerEvents = 'none';
      selection.clear();
      dlPng.style.display = dlOverlay.style.display = 'none';
      coordsDiv.style.display = 'none';
      diffBtn.style.display = '';
    }
  });

  dlPng.addEventListener('click', () => {
    const data = selection.getCroppedData(currentImage);
    if (!data) return;
    const a = document.createElement('a');
    a.href = data.dataUrl; a.download = 'selection.png';
    document.body.appendChild(a); a.click(); document.body.removeChild(a);
  });

  dlOverlay.addEventListener('click', () => {
    const data = selection.getCroppedData(currentImage);
    if (!data) return;
    const bounds = cropToBounds(data.x, data.y, data.w, data.h);
    const m = (filterCtrl.currentName()||'').match(/(\d{8}_\d{6})/);
    const ts = m ? m[0] : Date.now();
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

  // Keyboard
  window.addEventListener('keydown', e => {
    if (e.key === 'ArrowLeft') { e.preventDefault(); if (filterCtrl.currentIndex>0) filterCtrl.load(filterCtrl.currentIndex-1); }
    else if (e.key === 'ArrowRight') { e.preventDefault(); if (filterCtrl.currentIndex<filterCtrl.filtered.length-1) filterCtrl.load(filterCtrl.currentIndex+1); }
    else if (e.key === 'r' || e.key === 'R') { e.preventDefault(); viewport.reset(currentImage); draw(); }
  });

  interval.addEventListener('change', () => {
    if (diffMgr && diffMgr.active) return;
    filterCtrl.setInterval(parseInt(interval.value));
  });

  // Date/time pickers (will be populated after fetch)
  function setupDateTimePickers(snaps) {
    const byDate = new Map();
    for (const f of snaps) {
      const m = f.match(/(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})(\d{2})/);
      if (!m) continue;
      const dateKey = `${m[1]}-${m[2]}-${m[3]}`;
      const timeStr = `${m[4]}:${m[5]}:${m[6]}`;
      if (!byDate.has(dateKey)) byDate.set(dateKey, []);
      byDate.get(dateKey).push({name:f, time:timeStr});
    }
    for (const arr of byDate.values()) arr.sort((a,b)=>a.time.localeCompare(b.time));
    const dates = Array.from(byDate.keys()).sort();
    if (dates.length) {
      datePick.min = dates[0]; datePick.max = dates[dates.length-1];
      datePick.value = dates[dates.length-1];
    }
    function populateTime(dateVal) {
      const snaps = byDate.get(dateVal);
      if (!snaps || snaps.length===0) { timeSel.style.display='none'; return; }
      timeSel.style.display = 'inline-block';
      timeSel.innerHTML = '<option value="">Select time...</option>';
      snaps.forEach(s => { const o = document.createElement('option'); o.value=s.name; o.text=s.time; timeSel.appendChild(o); });
    }
    if (datePick.value) {
      populateTime(datePick.value);
      const snaps = byDate.get(datePick.value);
      if (snaps && snaps.length) {
        timeSel.value = snaps[snaps.length-1].name;
        filterCtrl.rebuildWithAnchor(snaps[snaps.length-1].name);
      }
    }
    datePick.addEventListener('change', () => {
      if (diffMgr && diffMgr.active) return;
      populateTime(datePick.value);
      timeSel.value = '';
    });
    timeSel.addEventListener('change', () => {
      if (diffMgr && diffMgr.active) return;
      const name = timeSel.value;
      if (name) filterCtrl.rebuildWithAnchor(name);
    });
  }

  slider.addEventListener('input', () => filterCtrl.load(parseInt(slider.value)));

  // Initial canvas size
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

  // Fetch data
  fetch(BASE_URL + 'snapshots.json')
    .then(r => r.json())
    .then(files => {
      if (!files.length) { tsLabel.textContent = 'No snapshots.'; return; }
      filterCtrl.all = files;
      filterCtrl.setInterval(parseInt(interval.value)); // default 60 min
      setupDateTimePickers(files);
      if (filterCtrl.currentIndex === -1) {
        filterCtrl._rebuild(); // fallback load
      }
      return fetch(BASE_URL + 'diffs.json').then(r => r.json()).catch(() => ({}));
    })
    .then(diffs => {
      diffMgr = new DiffManager(diffs, filterCtrl, viewport);
      diffBtn.addEventListener('click', () => diffMgr.toggle(!diffMgr.active));
    })
    .catch(e => { tsLabel.textContent = 'Failed to load data'; console.error(e); });
})();
