(function() {
  const canvas = document.getElementById('canvas');
  const slider = document.getElementById('slider');
  const timestampLabelTop = document.getElementById('timestamp-label-top');
  const intervalSelect = document.getElementById('interval-select');
  const snapshotSelect = document.getElementById('snapshot-select');

  // ---- WebGL context ----
  const gl = canvas.getContext('webgl', { antialias: false }) ||
             canvas.getContext('experimental-webgl', { antialias: false });
  if (!gl) {
    document.body.innerHTML = 'WebGL not supported – please use a modern browser.';
    return;
  }

  // ---- Shaders ----
  const vertexSrc = `
    attribute vec2 a_position;
    attribute vec2 a_texCoord;
    varying vec2 v_texCoord;
    uniform mat3 u_matrix;
    void main() {
      vec3 pos = u_matrix * vec3(a_position, 1.0);
      gl_Position = vec4(pos.xy, 0.0, 1.0);
      v_texCoord = a_texCoord;
    }
  `;
  const fragmentSrc = `
    precision mediump float;
    varying vec2 v_texCoord;
    uniform sampler2D u_texture;
    void main() {
      gl_FragColor = texture2D(u_texture, v_texCoord);
    }
  `;

  function compileShader(type, src) {
    const shader = gl.createShader(type);
    gl.shaderSource(shader, src);
    gl.compileShader(shader);
    if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
      console.error('Shader compile error:', gl.getShaderInfoLog(shader));
      gl.deleteShader(shader);
      return null;
    }
    return shader;
  }

  const program = gl.createProgram();
  gl.attachShader(program, compileShader(gl.VERTEX_SHADER, vertexSrc));
  gl.attachShader(program, compileShader(gl.FRAGMENT_SHADER, fragmentSrc));
  gl.linkProgram(program);
  if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
    console.error('Program link error:', gl.getProgramInfoLog(program));
    return;
  }
  gl.useProgram(program);

  // ---- Alpha blending for transparency ----
  gl.enable(gl.BLEND);
  gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);

  const aPosLoc = gl.getAttribLocation(program, 'a_position');
  const aTexLoc = gl.getAttribLocation(program, 'a_texCoord');
  const uMatrixLoc = gl.getUniformLocation(program, 'u_matrix');
  const uTextureLoc = gl.getUniformLocation(program, 'u_texture');

  // ---- Quad geometry with flipped texture Y ----
  const quadVertices = new Float32Array([
    0, 0, 0, 0,
    1, 0, 1, 0,
    0, 1, 0, 1,
    1, 0, 1, 0,
    0, 1, 0, 1,
    1, 1, 1, 1
  ]);
  const quadBuffer = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, quadBuffer);
  gl.bufferData(gl.ARRAY_BUFFER, quadVertices, gl.STATIC_DRAW);
  gl.enableVertexAttribArray(aPosLoc);
  gl.vertexAttribPointer(aPosLoc, 2, gl.FLOAT, false, 16, 0);
  gl.enableVertexAttribArray(aTexLoc);
  gl.vertexAttribPointer(aTexLoc, 2, gl.FLOAT, false, 16, 8);

  // ---- Map constants ----
  const ZOOM = 11, TILE_SIZE = 1000;
  const TOTAL_TILES = Math.pow(2, ZOOM), WORLD_SIZE = TOTAL_TILES * TILE_SIZE;
  const START_COL = 1225, START_ROW = 513;

  function worldYToLat(yPx) {
    const mcY = 1 - 2 * yPx / WORLD_SIZE;
    return (2 * Math.atan(Math.exp(Math.PI * mcY)) - Math.PI / 2) * 180 / Math.PI;
  }
  function worldXToLon(xPx) { return (xPx / WORLD_SIZE) * 360 - 180; }
  function pixelToLatLon(px, py) {
    const gx = START_COL * TILE_SIZE + px, gy = START_ROW * TILE_SIZE + py;
    return { lat: worldYToLat(gy), lon: worldXToLon(gx) };
  }
  function cropToBounds(x, y, w, h) {
    const nw = pixelToLatLon(x, y), se = pixelToLatLon(x + w, y + h);
    return { north: nw.lat, south: se.lat, west: nw.lon, east: se.lon };
  }

  // ---- State ----
  let allSnapshots = [];
  let filteredSnapshots = [];
  let sliderValueToName = {};
  let currentImage = new Image();
  currentImage.crossOrigin = 'anonymous';
  let currentFilteredIndex = -1;
  let requestedFilteredIndex = -1;
  let offsetX = 0, offsetY = 0, scale = 1.0;
  const MIN_SCALE = 0.1, MAX_SCALE = 10.0;

  let dragging = false, dragStartX = 0, dragStartY = 0, dragOffsetX = 0, dragOffsetY = 0;
  let initialPinchDistance = 0, initialScale = 1.0, initialPinchCenter = { x: 0, y: 0 };
  let touchStartTapX = 0, touchStartTapY = 0;
  let wasDragged = false;
  let isPinching = false;

  // ---- Texture management ----
  const MAX_TEX = gl.getParameter(gl.MAX_TEXTURE_SIZE);
  console.log('Max texture size:', MAX_TEX);
  const IMG_WIDTH = 7000, IMG_HEIGHT = 6000;
  let SINGLE_TEXTURE = MAX_TEX >= IMG_WIDTH && MAX_TEX >= IMG_HEIGHT;

  let tileTextures = [];
  let singleTextureInfo = null;

  function mat3mul(a, b, out) {
    for (let col = 0; col < 3; col++) {
      const b0 = b[col*3], b1 = b[col*3+1], b2 = b[col*3+2];
      for (let row = 0; row < 3; row++) {
        out[col*3 + row] = a[row]*b0 + a[3+row]*b1 + a[6+row]*b2;
      }
    }
  }

  function createTextures(image) {
    tileTextures.forEach(t => gl.deleteTexture(t.tex));
    tileTextures = [];
    if (singleTextureInfo) {
      gl.deleteTexture(singleTextureInfo.tex);
      singleTextureInfo = null;
    }

    if (SINGLE_TEXTURE) {
      const tex = gl.createTexture();
      gl.bindTexture(gl.TEXTURE_2D, tex);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, image);
      if (gl.getError() !== gl.NO_ERROR) {
        console.error('Failed to upload single texture, falling back to tiling.');
        gl.deleteTexture(tex);
        SINGLE_TEXTURE = false;
      } else {
        singleTextureInfo = { tex, w: IMG_WIDTH, h: IMG_HEIGHT };
        console.log('Using single texture');
        return;
      }
    }

    const tileSize = Math.min(MAX_TEX, 2048);
    console.log('Tiling with size', tileSize);
    const offCanvas = document.createElement('canvas');
    const offCtx = offCanvas.getContext('2d');

    for (let y = 0; y < IMG_HEIGHT; y += tileSize) {
      for (let x = 0; x < IMG_WIDTH; x += tileSize) {
        const w = Math.min(tileSize, IMG_WIDTH - x);
        const h = Math.min(tileSize, IMG_HEIGHT - y);
        offCanvas.width = w; offCanvas.height = h;
        offCtx.clearRect(0, 0, w, h);
        offCtx.drawImage(image, x, y, w, h, 0, 0, w, h);

        const tex = gl.createTexture();
        gl.bindTexture(gl.TEXTURE_2D, tex);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, offCanvas);
        if (gl.getError() !== gl.NO_ERROR) {
          console.error('WebGL error uploading tile at', x, y);
          gl.deleteTexture(tex);
          continue;
        }
        tileTextures.push({ tex, x, y, w, h });
      }
    }
    console.log('Created', tileTextures.length, 'tiles.');
  }

  // ---- Drawing ----
  function drawScene() {
    gl.clearColor(0.627, 0.741, 1.0, 1.0);
    gl.clear(gl.COLOR_BUFFER_BIT);

    const cssW = window.innerWidth, cssH = window.innerHeight;
    if (SINGLE_TEXTURE && singleTextureInfo) {
      gl.bindTexture(gl.TEXTURE_2D, singleTextureInfo.tex);
      const proj = new Float32Array([2/cssW,0,0, 0,-2/cssH,0, -1,1,1]);
      const pan = new Float32Array([1,0,0, 0,1,0, offsetX,offsetY,1]);
      const zoom = new Float32Array([scale,0,0, 0,scale,0, 0,0,1]);
      const imgScale = new Float32Array([IMG_WIDTH,0,0, 0,IMG_HEIGHT,0, 0,0,1]);
      const tmp1 = new Float32Array(9), tmp2 = new Float32Array(9), combined = new Float32Array(9);
      mat3mul(pan, zoom, tmp1);
      mat3mul(proj, tmp1, tmp2);
      mat3mul(tmp2, imgScale, combined);
      gl.uniformMatrix3fv(uMatrixLoc, false, combined);
      gl.uniform1i(uTextureLoc, 0);
      gl.bindBuffer(gl.ARRAY_BUFFER, quadBuffer);
      gl.drawArrays(gl.TRIANGLES, 0, 6);
    } else if (tileTextures.length > 0) {
      const proj = new Float32Array([2/cssW,0,0, 0,-2/cssH,0, -1,1,1]);
      const pan = new Float32Array([1,0,0, 0,1,0, offsetX,offsetY,1]);
      const zoom = new Float32Array([scale,0,0, 0,scale,0, 0,0,1]);
      const tmp1 = new Float32Array(9), tmp2 = new Float32Array(9), combined = new Float32Array(9);
      mat3mul(pan, zoom, tmp1);
      mat3mul(proj, tmp1, tmp2);

      gl.bindBuffer(gl.ARRAY_BUFFER, quadBuffer);
      for (const tile of tileTextures) {
        gl.bindTexture(gl.TEXTURE_2D, tile.tex);
        const tileScale = new Float32Array([tile.w,0,0, 0,tile.h,0, tile.x,tile.y,1]);
        mat3mul(tmp2, tileScale, combined);
        gl.uniformMatrix3fv(uMatrixLoc, false, combined);
        gl.uniform1i(uTextureLoc, 0);
        gl.drawArrays(gl.TRIANGLES, 0, 6);
      }
    }
  }

  // ---- Resize ----
  function resize() {
    const dpr = window.devicePixelRatio || 1;
    canvas.width = window.innerWidth * dpr;
    canvas.height = window.innerHeight * dpr;
    canvas.style.width = window.innerWidth + 'px';
    canvas.style.height = window.innerHeight + 'px';
    gl.viewport(0, 0, canvas.width, canvas.height);
    drawScene();
  }

  function resetView() {
    if (!currentImage.complete || currentImage.naturalWidth === 0) return;
    const w = currentImage.width, h = currentImage.height;
    const ww = window.innerWidth, wh = window.innerHeight;
    scale = Math.min(ww / w, wh / h);
    offsetX = (ww - w * scale) / 2;
    offsetY = (wh - h * scale) / 2;
    drawScene();
  }

  // ---- Parse timestamp ----
  function getEpoch(filename) {
    const m = filename.match(/(\d{8})_(\d{6})/);
    if (!m) return 0;
    const ds = m[1], ts = m[2];
    return Date.UTC(
      parseInt(ds.slice(0,4)), parseInt(ds.slice(4,6))-1, parseInt(ds.slice(6,8)),
      parseInt(ts.slice(0,2)), parseInt(ts.slice(2,4)), parseInt(ts.slice(4,6))
    ) / 1000;
  }

  function timeAgo(epochSec) {
    const now = Date.now() / 1000;
    let diff = Math.max(0, Math.round(now - epochSec));
    const d = Math.floor(diff / 86400); diff -= d*86400;
    const h = Math.floor(diff / 3600); diff -= h*3600;
    const m = Math.floor(diff / 60);
    if (d > 0) return `${d}d ${h}h ${m}m ago`;
    if (h > 0) return `${h}h ${m}m ago`;
    return `${m}m ago`;
  }

  // ---- Filtering ----
  let currentInterval = 180;

  function buildFilteredList(anchorName = null) {
    const intervalSec = currentInterval * 60;
    const candidates = allSnapshots.map(name => ({ name, epoch: getEpoch(name) }));
    candidates.sort((a, b) => a.epoch - b.epoch);

    let selected = [];
    if (anchorName !== null) {
      const anchorIdx = candidates.findIndex(c => c.name === anchorName);
      if (anchorIdx === -1) {
        anchorName = null;
      } else {
        const anchor = candidates[anchorIdx];
        const anchorEpoch = anchor.epoch;

        const forward = [];
        let lastEpoch = anchorEpoch;
        for (let i = anchorIdx + 1; i < candidates.length; i++) {
          if (candidates[i].epoch - lastEpoch >= intervalSec) {
            forward.push(candidates[i]);
            lastEpoch = candidates[i].epoch;
          }
        }

        const backward = [];
        lastEpoch = anchorEpoch;
        for (let i = anchorIdx - 1; i >= 0; i--) {
          if (lastEpoch - candidates[i].epoch >= intervalSec) {
            backward.unshift(candidates[i]);
            lastEpoch = candidates[i].epoch;
          }
        }

        selected = backward.concat(anchor).concat(forward);
      }
    }

    if (!anchorName) {
      for (let i = candidates.length - 1; i >= 0; i--) {
        if (selected.length === 0) {
          selected.unshift(candidates[i]);
        } else {
          const lastEpoch = selected[0].epoch;
          if (lastEpoch - candidates[i].epoch >= intervalSec) {
            selected.unshift(candidates[i]);
          }
        }
      }
    }

    filteredSnapshots = selected.map(c => c.name);
    sliderValueToName = {};
    filteredSnapshots.forEach((name, idx) => { sliderValueToName[idx] = name; });
    slider.max = filteredSnapshots.length - 1;

    if (filteredSnapshots.length === 0) {
      timestampLabelTop.textContent = 'No snapshots match interval.';
      return;
    }

    let targetIdx = filteredSnapshots.length - 1;
    if (anchorName) {
      const idx = filteredSnapshots.indexOf(anchorName);
      if (idx !== -1) targetIdx = idx;
    }
    loadFilteredSnapshot(targetIdx);
  }

  function loadFilteredSnapshot(idx) {
    if (idx < 0 || idx >= filteredSnapshots.length) return;
    const filename = sliderValueToName[idx];
    if (!filename) return;
    requestedFilteredIndex = idx;
    slider.value = idx;
    const m = filename.match(/(\d{8})_(\d{6})/);
    timestampLabelTop.textContent = m
      ? `${m[1].slice(0,4)}-${m[1].slice(4,6)}-${m[1].slice(6,8)} ${m[2].slice(0,2)}:${m[2].slice(2,4)}:${m[2].slice(4,6)}`
      : filename;
    currentImage.src = 'https://raw.githubusercontent.com/daniel-jbx/Wdp-archiver/assets/' + filename;
  }

  currentImage.onload = () => {
    if (currentFilteredIndex !== requestedFilteredIndex) {
      createTextures(currentImage);
      if (currentFilteredIndex === -1) {
        currentFilteredIndex = requestedFilteredIndex;
        resetView();
      } else {
        currentFilteredIndex = requestedFilteredIndex;
        drawScene();
      }
    }
  };
  currentImage.onerror = () => console.error('Image failed:', currentImage.src);

  // ---- Load overlay definitions from overlays.txt ----
  let CROPS = {};
  const downloadGroup = document.getElementById('download-group');

  fetch('https://raw.githubusercontent.com/daniel-jbx/Wdp-archiver/assets/overlays.txt')
    .then(r => r.text())
    .then(txt => {
      const lines = txt.split('\n');
      lines.forEach(line => {
        line = line.trim();
        if (line === '' || line.startsWith('#')) return;
        const parts = line.split('\t');
        if (parts.length !== 5) return;
        const [name, x1, y1, x2, y2] = parts.map(s => s.trim());
        const crop = {
          x: parseInt(x1),
          y: parseInt(y1),
          w: parseInt(x2) - parseInt(x1),
          h: parseInt(y2) - parseInt(y1)
        };
        CROPS[name] = crop;

        const btn = document.createElement('button');
        btn.className = 'dl-btn';
        btn.textContent = name;
        btn.addEventListener('click', () => downloadOverlay(name));
        downloadGroup.appendChild(btn);
      });
      console.log('Overlays loaded:', Object.keys(CROPS));
    })
    .catch(e => console.error('Failed to load overlays.txt', e));

  // ---- Initial snapshot loading ----
  fetch('https://raw.githubusercontent.com/daniel-jbx/Wdp-archiver/assets/snapshots.json')
    .then(r => r.json())
    .then(files => {
      if (!files.length) { timestampLabelTop.textContent = 'No snapshots found.'; return; }
      allSnapshots = files;
      snapshotSelect.innerHTML = '<option value="">Jump to…</option>';
      for (let i = allSnapshots.length - 1; i >= 0; i--) {
        const ts = getEpoch(allSnapshots[i]);
        const opt = document.createElement('option');
        opt.value = allSnapshots[i];
        opt.textContent = timeAgo(ts);
        snapshotSelect.appendChild(opt);
      }
      buildFilteredList(null);
    })
    .catch(e => { timestampLabelTop.textContent = 'Failed to load snapshots.json'; console.error(e); });

  // ---- Interval dropdown ----
  intervalSelect.addEventListener('change', () => {
    currentInterval = parseInt(intervalSelect.value);
    buildFilteredList(null);
  });

  // ---- Snapshot jump dropdown ----
  snapshotSelect.addEventListener('change', () => {
    const selectedFilename = snapshotSelect.value;
    if (!selectedFilename) return;
    buildFilteredList(selectedFilename);
  });

  // ---- Slider ----
  slider.addEventListener('input', () => {
    loadFilteredSnapshot(parseInt(slider.value, 10));
  });

  // ---- Keyboard shortcuts ----
  window.addEventListener('keydown', e => {
    if(e.key==='ArrowLeft'){
      e.preventDefault();
      if(currentFilteredIndex > 0) loadFilteredSnapshot(currentFilteredIndex - 1);
    }
    else if(e.key==='ArrowRight'){
      e.preventDefault();
      if(currentFilteredIndex < filteredSnapshots.length - 1) loadFilteredSnapshot(currentFilteredIndex + 1);
    }
    else if(e.key==='r'||e.key==='R') resetView();
  });

  // ---- Pan & Zoom events (unchanged) ----
  canvas.addEventListener('mousedown', e => { if (selectionMode) return; e.preventDefault(); dragging = true; dragStartX = e.clientX; dragStartY = e.clientY; dragOffsetX = offsetX; dragOffsetY = offsetY; canvas.style.cursor = 'grabbing'; });
  window.addEventListener('mousemove', e => { if (selectionMode) return; if (!dragging) return; offsetX = dragOffsetX + (e.clientX - dragStartX); offsetY = dragOffsetY + (e.clientY - dragStartY); drawScene(); });
  window.addEventListener('mouseup', () => { if (selectionMode) return; dragging = false; canvas.style.cursor = 'grab'; });

  // ---- Touch events (unchanged) ----
  canvas.addEventListener('touchstart', e => {
    if (selectionMode) return;
    e.preventDefault();
    const t = e.touches;
    if (t.length === 1) {
      dragging = true;
      dragStartX = t[0].clientX;
      dragStartY = t[0].clientY;
      dragOffsetX = offsetX;
      dragOffsetY = offsetY;
      wasDragged = false;
      touchStartTapX = t[0].clientX;
      touchStartTapY = t[0].clientY;
    } else if (t.length === 2) {
      dragging = false;
      isPinching = true;
      const dx = t[1].clientX - t[0].clientX;
      const dy = t[1].clientY - t[0].clientY;
      initialPinchDistance = Math.hypot(dx, dy);
      initialScale = scale;
      initialPinchCenter = {
        x: (t[0].clientX + t[1].clientX) / 2,
        y: (t[0].clientY + t[1].clientY) / 2
      };
    }
  }, { passive: false });

  canvas.addEventListener('touchmove', e => {
    if (selectionMode) return;
    e.preventDefault();
    const t = e.touches;
    if (t.length === 1 && dragging) {
      offsetX = dragOffsetX + (t[0].clientX - dragStartX);
      offsetY = dragOffsetY + (t[0].clientY - dragStartY);
      if (Math.hypot(t[0].clientX - touchStartTapX, t[0].clientY - touchStartTapY) > 5) {
        wasDragged = true;
      }
      drawScene();
    } else if (t.length === 2) {
      const dx = t[1].clientX - t[0].clientX;
      const dy = t[1].clientY - t[0].clientY;
      const nd = Math.hypot(dx, dy);
      if (initialPinchDistance > 0) {
        const ns = initialScale * (nd / initialPinchDistance);
        scale = Math.max(MIN_SCALE, Math.min(MAX_SCALE, ns));
        const cx = (t[0].clientX + t[1].clientX) / 2;
        const cy = (t[0].clientY + t[1].clientY) / 2;
        const sc = scale / initialScale;
        offsetX = cx - sc * (initialPinchCenter.x - offsetX);
        offsetY = cy - sc * (initialPinchCenter.y - offsetY);
        initialPinchCenter = { x: cx, y: cy };
        initialScale = scale;
        initialPinchDistance = nd;
        drawScene();
      }
    }
  }, { passive: false });

  canvas.addEventListener('touchend', e => {
    if (selectionMode) return;
    dragging = false;
    initialPinchDistance = 0;

    if (!wasDragged && !isPinching && e.changedTouches.length === 1) {
      const x = e.changedTouches[0].clientX;
      if (x < window.innerWidth / 2) {
        if (currentFilteredIndex > 0) loadFilteredSnapshot(currentFilteredIndex - 1);
      } else {
        if (currentFilteredIndex < filteredSnapshots.length - 1) loadFilteredSnapshot(currentFilteredIndex + 1);
      }
    }

    if (e.touches.length === 0) {
      isPinching = false;
      wasDragged = false;
    }
  });

  canvas.addEventListener('wheel', e => {
    if (selectionMode) return;
    e.preventDefault();
    const zf=1.1, old=scale;
    if(e.deltaY<0) scale*=zf; else scale/=zf;
    scale=Math.max(MIN_SCALE,Math.min(MAX_SCALE,scale));
    const sc=scale/old;
    offsetX=e.clientX-sc*(e.clientX-offsetX);
    offsetY=e.clientY-sc*(e.clientY-offsetY);
    drawScene();
  }, {passive:false});

  // ---- Overlay download (transparent) ----
  let exportCanvas = null;

  function downloadOverlay(cropKey) {
    if (!currentImage.complete || currentImage.naturalWidth === 0) return;
    const crop = CROPS[cropKey];
    if (!crop) return;

    if (!exportCanvas) exportCanvas = document.createElement('canvas');
    exportCanvas.width = crop.w;
    exportCanvas.height = crop.h;
    const tctx = exportCanvas.getContext('2d');
    tctx.clearRect(0, 0, crop.w, crop.h);
    tctx.drawImage(currentImage, crop.x, crop.y, crop.w, crop.h, 0, 0, crop.w, crop.h);

    const dataUrl = exportCanvas.toDataURL('image/png');
    const bounds = cropToBounds(crop.x, crop.y, crop.w, crop.h);
    const currentFilename = filteredSnapshots[currentFilteredIndex];
    const m = currentFilename ? currentFilename.match(/(\d{8}_\d{6})/) : null;
    const ts = m ? m[0] : 'unknown';
    const overlay = {
      id: `wdp_${cropKey}_${ts}`,
      schemaVersion: "1",
      name: `${cropKey}_${ts}.png`,
      opacity: 1,
      image: { dataUrl, width: crop.w, height: crop.h },
      bounds,
      colorMetric: "lab",
      dithering: false,
      order: 0,
      locked: false,
      hasPlaced: true,
      visible: true
    };
    const blob = new Blob([JSON.stringify(overlay)], { type: 'application/json' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `wdp_${cropKey}_${ts}.wplace`;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
  }

  const dlSnapshot = document.getElementById('dl-snapshot');
  dlSnapshot.addEventListener('click', () => {
    if (currentFilteredIndex < 0 || currentFilteredIndex >= filteredSnapshots.length) return;
    const filename = filteredSnapshots[currentFilteredIndex];
    const a = document.createElement('a');
    a.href = 'https://raw.githubusercontent.com/daniel-jbx/Wdp-archiver/assets/' + filename;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
  });

  // ---- Selection mode ----
  const selCanvas = document.getElementById('sel-canvas');
  const selCtx = selCanvas.getContext('2d');

  let selectionMode = false;
  let selecting = false;
  let selStartImg = null;
  let selEndImg = null;
  let dragHandle = null;

  const HANDLE_SIZE = 8;

  function resizeSelCanvas() {
    selCanvas.width = window.innerWidth;
    selCanvas.height = window.innerHeight;
    selCanvas.style.width = window.innerWidth + 'px';
    selCanvas.style.height = window.innerHeight + 'px';
  }

  function getSelectionRect() {
    if (!selStartImg || !selEndImg) return null;
    return {
      x1: Math.min(selStartImg.x, selEndImg.x),
      y1: Math.min(selStartImg.y, selEndImg.y),
      x2: Math.max(selStartImg.x, selEndImg.x),
      y2: Math.max(selStartImg.y, selEndImg.y)
    };
  }

  function drawSelection() {
    selCtx.clearRect(0, 0, selCanvas.width, selCanvas.height);
    const rect = getSelectionRect();
    if (!rect) return;

    const start = imgToClient(rect.x1, rect.y1);
    const end = imgToClient(rect.x2, rect.y2);
    const x = Math.min(start.x, end.x);
    const y = Math.min(start.y, end.y);
    const w = Math.abs(end.x - start.x);
    const h = Math.abs(end.y - start.y);

    selCtx.fillStyle = 'rgba(255, 255, 0, 0.1)';
    selCtx.fillRect(x, y, w, h);
    selCtx.strokeStyle = '#FF0';
    selCtx.lineWidth = 1;
    selCtx.strokeRect(x, y, w, h);

    const handles = [
      { x: x, y: y },
      { x: x + w, y: y },
      { x: x, y: y + h },
      { x: x + w, y: y + h },
      { x: x + w/2, y: y },
      { x: x + w/2, y: y + h },
      { x: x, y: y + h/2 },
      { x: x + w, y: y + h/2 }
    ];
    selCtx.fillStyle = '#FFF';
    selCtx.strokeStyle = '#000';
    handles.forEach(h => {
      selCtx.fillRect(h.x - HANDLE_SIZE/2, h.y - HANDLE_SIZE/2, HANDLE_SIZE, HANDLE_SIZE);
      selCtx.strokeRect(h.x - HANDLE_SIZE/2, h.y - HANDLE_SIZE/2, HANDLE_SIZE, HANDLE_SIZE);
    });
  }

  function hitTestHandle(clientX, clientY) {
    const rect = getSelectionRect();
    if (!rect) return null;
    const img = clientToImg(clientX, clientY);
    const x1 = rect.x1, x2 = rect.x2, y1 = rect.y1, y2 = rect.y2;
    const threshold = HANDLE_SIZE / scale;

    if (Math.abs(img.x - x1) <= threshold && Math.abs(img.y - y1) <= threshold) return 'tl';
    if (Math.abs(img.x - x2) <= threshold && Math.abs(img.y - y1) <= threshold) return 'tr';
    if (Math.abs(img.x - x1) <= threshold && Math.abs(img.y - y2) <= threshold) return 'bl';
    if (Math.abs(img.x - x2) <= threshold && Math.abs(img.y - y2) <= threshold) return 'br';
    if (Math.abs(img.x - x1) <= threshold && img.y > y1 && img.y < y2) return 'left';
    if (Math.abs(img.x - x2) <= threshold && img.y > y1 && img.y < y2) return 'right';
    if (Math.abs(img.y - y1) <= threshold && img.x > x1 && img.x < x2) return 'top';
    if (Math.abs(img.y - y2) <= threshold && img.x > x1 && img.x < x2) return 'bottom';
    if (img.x > x1 && img.x < x2 && img.y > y1 && img.y < y2) return 'move';
    return null;
  }

  function clientToImg(clientX, clientY) {
    const imgX = (clientX - offsetX) / scale;
    const imgY = (clientY - offsetY) / scale;
    return { x: imgX, y: imgY };
  }

  function imgToClient(imgX, imgY) {
    const clientX = imgX * scale + offsetX;
    const clientY = imgY * scale + offsetY;
    return { x: clientX, y: clientY };
  }

  function constrainToImage(imgPt) {
    return {
      x: Math.max(0, Math.min(imgPt.x, IMG_WIDTH)),
      y: Math.max(0, Math.min(imgPt.y, IMG_HEIGHT))
    };
  }

  function dragSelection(clientX, clientY) {
    const img = constrainToImage(clientToImg(clientX, clientY));
    const rect = getSelectionRect();
    if (!rect) return;

    const start = selStartImg, end = selEndImg;
    const x1 = Math.min(start.x, end.x);
    const y1 = Math.min(start.y, end.y);
    const x2 = Math.max(start.x, end.x);
    const y2 = Math.max(start.y, end.y);

    switch (dragHandle) {
      case 'tl': selStartImg = { x: img.x, y: img.y }; selEndImg = { x: x2, y: y2 }; break;
      case 'tr': selStartImg = { x: x1, y: img.y }; selEndImg = { x: img.x, y: y2 }; break;
      case 'bl': selStartImg = { x: img.x, y: y1 }; selEndImg = { x: x2, y: img.y }; break;
      case 'br': selStartImg = { x: x1, y: y1 }; selEndImg = { x: img.x, y: img.y }; break;
      case 'top': selStartImg = { x: x1, y: img.y }; selEndImg = { x: x2, y: y2 }; break;
      case 'bottom': selStartImg = { x: x1, y: y1 }; selEndImg = { x: x2, y: img.y }; break;
      case 'left': selStartImg = { x: img.x, y: y1 }; selEndImg = { x: x2, y: y2 }; break;
      case 'right': selStartImg = { x: x1, y: y1 }; selEndImg = { x: img.x, y: y2 }; break;
      case 'move': {
        const dx = img.x - (x1 + x2) / 2;
        const dy = img.y - (y1 + y2) / 2;
        const w = x2 - x1, h = y2 - y1;
        let newX1 = x1 + dx, newY1 = y1 + dy;
        newX1 = Math.max(0, Math.min(newX1, IMG_WIDTH - w));
        newY1 = Math.max(0, Math.min(newY1, IMG_HEIGHT - h));
        selStartImg = { x: newX1, y: newY1 };
        selEndImg = { x: newX1 + w, y: newY1 + h };
        break;
      }
    }
    drawSelection();
  }

  // Toggle selection mode
  const dlSelectToggle = document.getElementById('dl-select-toggle');
  const dlSelectCancel = document.getElementById('dl-select-cancel');
  const dlSelectPng = document.getElementById('dl-select-png');
  const dlSelectOverlay = document.getElementById('dl-select-overlay');

  function setSelectionButtonsVisible(visible) {
    const disp = visible ? 'inline-block' : 'none';
    dlSelectCancel.style.display = disp;
    dlSelectPng.style.display = disp;
    dlSelectOverlay.style.display = disp;
  }

  dlSelectToggle.addEventListener('click', () => {
    selectionMode = !selectionMode;
    dlSelectToggle.textContent = selectionMode ? 'selecting...' : 'select area';
    selCanvas.style.pointerEvents = selectionMode ? 'auto' : 'none';
    if (!selectionMode) {
      selStartImg = selEndImg = null;
      dragHandle = null;
      selCtx.clearRect(0, 0, selCanvas.width, selCanvas.height);
      setSelectionButtonsVisible(false);
    }
  });

dlSelectCancel.addEventListener('click', () => {
  if (!selectionMode) return;
  selectionMode = false;
  dlSelectToggle.textContent = 'select area';
  selCanvas.style.pointerEvents = 'none';
  selStartImg = selEndImg = null;
  dragHandle = null;
  selCtx.clearRect(0, 0, selCanvas.width, selCanvas.height);
  setSelectionButtonsVisible(false);
});

  // ---- Override mouse events for selection mode ----
  selCanvas.addEventListener('mousedown', e => {
    if (!selectionMode) return;
    e.preventDefault();
    const clientX = e.clientX, clientY = e.clientY;
    const img = constrainToImage(clientToImg(clientX, clientY));

    if (selStartImg && selEndImg && getSelectionRect()) {
      const handle = hitTestHandle(clientX, clientY);
      if (handle) {
        dragHandle = handle;
        selecting = false;
        return;
      }
    }

    selecting = true;
    selStartImg = img;
    selEndImg = null;
    dragHandle = null;
    selCtx.clearRect(0, 0, selCanvas.width, selCanvas.height);
  });

  selCanvas.addEventListener('mousemove', e => {
    if (!selectionMode) return;
    if (selecting) {
      const img = constrainToImage(clientToImg(e.clientX, e.clientY));
      selEndImg = img;
      drawSelection();
    } else if (dragHandle) {
      dragSelection(e.clientX, e.clientY);
    }
  });

  selCanvas.addEventListener('mouseup', e => {
    if (!selectionMode) return;
    if (selecting) {
      selecting = false;
      if (selStartImg && selEndImg) {
        if (Math.abs(selEndImg.x - selStartImg.x) < 1 || Math.abs(selEndImg.y - selStartImg.y) < 1) {
          selStartImg = selEndImg = null;
          setSelectionButtonsVisible(false);
        } else {
          setSelectionButtonsVisible(true);
        }
      }
      drawSelection();
    } else if (dragHandle) {
      dragHandle = null;
      drawSelection();
    }
  });

  // Touch events for selection
  selCanvas.addEventListener('touchstart', e => {
    if (!selectionMode) return;
    e.preventDefault();
    const t = e.touches[0];
    const clientX = t.clientX, clientY = t.clientY;
    const img = constrainToImage(clientToImg(clientX, clientY));

    if (selStartImg && selEndImg && getSelectionRect()) {
      const handle = hitTestHandle(clientX, clientY);
      if (handle) {
        dragHandle = handle;
        selecting = false;
        return;
      }
    }

    selecting = true;
    selStartImg = img;
    selEndImg = null;
    dragHandle = null;
    selCtx.clearRect(0, 0, selCanvas.width, selCanvas.height);
  }, { passive: false });

  selCanvas.addEventListener('touchmove', e => {
    if (!selectionMode) return;
    e.preventDefault();
    const t = e.touches[0];
    if (selecting) {
      selEndImg = constrainToImage(clientToImg(t.clientX, t.clientY));
      drawSelection();
    } else if (dragHandle) {
      dragSelection(t.clientX, t.clientY);
    }
  }, { passive: false });

  selCanvas.addEventListener('touchend', e => {
    if (!selectionMode) return;
    if (selecting) {
      selecting = false;
      if (selStartImg && selEndImg) {
        if (Math.abs(selEndImg.x - selStartImg.x) < 1 || Math.abs(selEndImg.y - selStartImg.y) < 1) {
          selStartImg = selEndImg = null;
          setSelectionButtonsVisible(false);
        } else {
          setSelectionButtonsVisible(true);
        }
      }
      drawSelection();
    } else if (dragHandle) {
      dragHandle = null;
      drawSelection();
    }
  });

  // ---- Download custom selection ----
  function getCroppedImageData() {
    if (!selStartImg || !selEndImg) return null;
    const rect = getSelectionRect();
    if (!rect || rect.x2 - rect.x1 < 1 || rect.y2 - rect.y1 < 1) return null;
    const tmp = document.createElement('canvas');
    tmp.width = rect.x2 - rect.x1;
    tmp.height = rect.y2 - rect.y1;
    const tctx = tmp.getContext('2d');
    tctx.clearRect(0, 0, tmp.width, tmp.height);
    tctx.drawImage(currentImage, rect.x1, rect.y1, tmp.width, tmp.height, 0, 0, tmp.width, tmp.height);
    return {
      dataUrl: tmp.toDataURL('image/png'),
      width: tmp.width,
      height: tmp.height,
      x: rect.x1,
      y: rect.y1
    };
  }

  dlSelectPng.addEventListener('click', () => {
    const cropData = getCroppedImageData();
    if (!cropData) return;
    const a = document.createElement('a');
    a.href = cropData.dataUrl;
    a.download = 'selection.png';
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
  });

  dlSelectOverlay.addEventListener('click', () => {
    const cropData = getCroppedImageData();
    if (!cropData) return;
    const bounds = cropToBounds(cropData.x, cropData.y, cropData.width, cropData.height);
    const m = (filteredSnapshots[currentFilteredIndex] || '').match(/(\d{8}_\d{6})/);
    const ts = m ? m[0] : Date.now();

    const overlay = {
      id: `wdp_custom_${ts}`,
      schemaVersion: "1",
      name: `custom_${ts}.png`,
      opacity: 1,
      image: { dataUrl: cropData.dataUrl, width: cropData.width, height: cropData.height },
      bounds,
      colorMetric: "lab",
      dithering: false,
      order: 0,
      locked: false,
      hasPlaced: true,
      visible: true
    };

    const blob = new Blob([JSON.stringify(overlay)], { type: 'application/json' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `wdp_custom_${ts}.wplace`;
    document.body.appendChild(a); a.click(); document.body.removeChild(a);
    URL.revokeObjectURL(url);
  });

  // Ensure the selection canvas resizes with the window
  const origResize = resize;
  resize = function() {
    origResize();
    resizeSelCanvas();
  };
  window.addEventListener('resize', resize);

  // Initial resize
  resize();
  gl.clearColor(0.627, 0.741, 1.0, 1.0);
  gl.clear(gl.COLOR_BUFFER_BIT);
})();
