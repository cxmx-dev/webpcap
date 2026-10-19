/**
 * webpcap canvas helper — records the largest HTML <canvas> (WebGL/demo surface only).
 * No browser chrome. Requires video-host on 127.0.0.1 (from .\build.ps1).
 *
 * Load on the demo page (while host is running):
 *   <script src="http://127.0.0.1:19787/webpcap-canvas.js"></script>
 * Or open canvas-test.html / .\open-canvas-test.ps1
 *
 * STATUS: parked — no main-map hotkey. Prefer display / window / region REC:
 *   Ctrl+Shift+PrtSc | Ctrl+Win+PrtSc | Ctrl+Alt+PrtSc | End
 * Do not use Alt+Shift+PrtSc (Windows High Contrast; old toggle removed).
 *
 * Console: [webpcap] canvas helper ready
 */
(function () {
  if (window.__webpcapCanvas) return;
  window.__webpcapCanvas = true;

  var PORT = 19787;
  try {
    var m = document.currentScript && document.currentScript.src.match(/:(\d+)\//);
    if (m) PORT = parseInt(m[1], 10) || PORT;
  } catch (e) {}

  var BASE = 'http://127.0.0.1:' + PORT;
  var lastSeq = -1;
  var recorder = null;
  var chunks = [];
  var mediaStream = null;
  var pumpRunning = false;
  var proxy = null;
  var srcCanvas = null;

  function pickCanvas() {
    var list = Array.prototype.slice.call(document.querySelectorAll('canvas'));
    if (!list.length) return null;
    list.sort(function (a, b) {
      var aw = (a.width || a.clientWidth || 0) * (a.height || a.clientHeight || 0);
      var bw = (b.width || b.clientWidth || 0) * (b.height || b.clientHeight || 0);
      return bw - aw;
    });
    return list[0];
  }

  function pickMime() {
    var types = [
      'video/webm;codecs=vp9',
      'video/webm;codecs=vp8',
      'video/webm',
      'video/mp4'
    ];
    for (var i = 0; i < types.length; i++) {
      if (window.MediaRecorder && MediaRecorder.isTypeSupported(types[i])) return types[i];
    }
    return '';
  }

  function extFromMime(mime) {
    if (!mime) return 'webm';
    if (mime.indexOf('mp4') !== -1) return 'mp4';
    return 'webm';
  }

  /** Copy source canvas → 2D proxy each frame (WebGL often blanks captureStream otherwise). */
  function pump() {
    if (!pumpRunning || !proxy || !srcCanvas) return;
    try {
      var w = srcCanvas.width || srcCanvas.clientWidth || 1;
      var h = srcCanvas.height || srcCanvas.clientHeight || 1;
      if (proxy.width !== w || proxy.height !== h) {
        proxy.width = w;
        proxy.height = h;
      }
      var ctx = proxy.getContext('2d');
      ctx.drawImage(srcCanvas, 0, 0, w, h);
    } catch (e) {
      /* tainted / lost context */
    }
    requestAnimationFrame(pump);
  }

  function startRec() {
    if (recorder && recorder.state !== 'inactive') return;
    srcCanvas = pickCanvas();
    if (!srcCanvas) {
      console.warn('[webpcap] no <canvas> on this page — open a demo with a canvas');
      return;
    }
    if (!srcCanvas.captureStream && !(document.createElement('canvas').captureStream)) {
      console.warn('[webpcap] captureStream not supported in this browser');
      return;
    }

    proxy = document.createElement('canvas');
    proxy.width = srcCanvas.width || srcCanvas.clientWidth || 640;
    proxy.height = srcCanvas.height || srcCanvas.clientHeight || 360;
    pumpRunning = true;
    requestAnimationFrame(pump);
    // seed first frame
    try {
      proxy.getContext('2d').drawImage(srcCanvas, 0, 0, proxy.width, proxy.height);
    } catch (e) {}

    try {
      mediaStream = proxy.captureStream(30);
    } catch (e) {
      console.warn('[webpcap] captureStream failed', e);
      pumpRunning = false;
      return;
    }

    chunks = [];
    var mime = pickMime();
    var opts = { videoBitsPerSecond: 8000000 };
    if (mime) opts.mimeType = mime;
    try {
      recorder = new MediaRecorder(mediaStream, opts);
    } catch (e) {
      try {
        recorder = new MediaRecorder(mediaStream);
      } catch (e2) {
        console.warn('[webpcap] MediaRecorder failed', e2);
        pumpRunning = false;
        return;
      }
    }

    recorder.ondataavailable = function (ev) {
      if (ev.data && ev.data.size > 0) chunks.push(ev.data);
    };
    recorder.onstop = function () {
      pumpRunning = false;
      var type = (recorder && recorder.mimeType) || mime || 'video/webm';
      var blob = new Blob(chunks, { type: type });
      chunks = [];
      if (mediaStream) {
        mediaStream.getTracks().forEach(function (t) {
          try {
            t.stop();
          } catch (e) {}
        });
        mediaStream = null;
      }
      proxy = null;
      srcCanvas = null;
      if (!blob.size) {
        console.warn('[webpcap] empty recording — try 2D canvas page or enable preserveDrawingBuffer for WebGL');
        recorder = null;
        return;
      }
      var ext = extFromMime(type);
      blob.arrayBuffer()
        .then(function (buf) {
          return fetch(BASE + '/canvas/upload?ext=' + encodeURIComponent(ext), {
            method: 'POST',
            headers: { 'Content-Type': 'application/octet-stream' },
            body: buf,
            mode: 'cors'
          });
        })
        .then(function (r) {
          return r.json().catch(function () {
            return {};
          });
        })
        .then(function (j) {
          if (j && j.ok) console.info('[webpcap] canvas saved', j.path || '');
          else console.warn('[webpcap] canvas upload failed', j);
        })
        .catch(function (err) {
          console.warn('[webpcap] upload failed — is video-host running? (build.ps1)', err);
        });
      recorder = null;
    };

    try {
      recorder.start(250);
      console.info(
        '[webpcap] canvas recording…',
        (srcCanvas.width || '?') + 'x' + (srcCanvas.height || '?'),
        '→ proxy MediaRecorder'
      );
    } catch (e) {
      console.warn('[webpcap] start failed', e);
      pumpRunning = false;
      recorder = null;
    }
  }

  function stopRec() {
    if (!recorder || recorder.state === 'inactive') {
      pumpRunning = false;
      return;
    }
    try {
      recorder.stop();
    } catch (e) {
      console.warn('[webpcap] stop failed', e);
      pumpRunning = false;
    }
  }

  function tick() {
    fetch(BASE + '/canvas/state', { cache: 'no-store', mode: 'cors' })
      .then(function (r) {
        if (!r.ok) throw new Error('state ' + r.status);
        return r.json();
      })
      .then(function (s) {
        if (typeof s.seq !== 'number') return;
        if (s.seq === lastSeq) return;
        var want = !!s.record;
        lastSeq = s.seq;
        if (want) startRec();
        else stopRec();
      })
      .catch(function () {
        /* host offline */
      });
  }

  setInterval(tick, 350);
  console.info('[webpcap] canvas helper ready → ' + BASE + '  (parked; use Ctrl+Shift/Win/Alt+PrtSc for main REC)');
})();
