// What Chromium's own capture of a tab tells the page it captures (engine patch tab/102).
//
// The stock launcher of an engine out dir, headless, on a scratch profile, loopback only: no
// window, no input. One tab asks (getDisplayMedia, the tab chosen by its title), another tab in
// the background is shared. Printed: the shared page's state before, during and after.
//
//   node engine/tests/headless_tab_capture.mjs <out dir>/Chromium.app/Contents/MacOS/Chromium <scratch dir>
//
// The stock launcher is no bridge host: its tabs have Chrome's delegate, so this shows Chromium's
// behaviour with and without the patch alike (document.hidden true -> false -> true and two
// visibilitychange events on 156.0.8078.114). The bridge's own behaviour is checked by
// c_abi_display_capture_host.mm.
import http from 'node:http';
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

const [app, scratch, ...flags] = process.argv.slice(2);
const extra = flags.filter(f => f.startsWith('--'));

const PAGE = `<!doctype html><html><head><title>TITLE</title></head>
<body style="margin:0;background:#2a6"><div id="box" style="width:50px;height:50px;background:#fff"></div><script>
var changes = 0, raf = 0, ticks = 0, resizes = 0, log = [];
var share = {share: 'idle', frames: 0, audio: 0, surface: '', size: ''};
document.addEventListener('visibilitychange', function () { changes++; log.push(document.visibilityState); });
addEventListener('resize', function () { resizes++; });
(function frame() { raf++; requestAnimationFrame(frame); })();
setInterval(function () { ticks++; document.getElementById('box').style.marginLeft = (ticks % 20) * 5 + 'px'; }, 200);
function ask(audio) {
  share = {share: 'pending', frames: 0, audio: 0, surface: '', size: ''};
  // Chrome switches to the tab it shares unless the page says otherwise; the bridge has no such switch.
  var controller = new CaptureController(); controller.setFocusBehavior('no-focus-change');
  navigator.mediaDevices.getDisplayMedia({video: true, audio: audio, controller: controller}).then(function (stream) {
    window.stream = stream;
    var track = stream.getVideoTracks()[0], now = share;
    track.addEventListener('ended', function () { now.share = 'ended'; });
    now.audio = stream.getAudioTracks().length;
    now.surface = track.getSettings().displaySurface;
    var reader = new MediaStreamTrackProcessor({track: track}).readable.getReader();
    (function pump() {
      reader.read().then(function (result) {
        if (result.done) return;
        now.frames++; now.size = result.value.displayWidth + 'x' + result.value.displayHeight;
        result.value.close(); pump();
      }, function () {});
    })();
    now.share = 'live';
  }, function (error) { share.share = 'error:' + error.name + ':' + error.message; });
  return true;
}
function state() {
  return JSON.stringify(Object.assign({w: innerWidth, h: innerHeight, hidden: document.hidden, changes: changes, log: log.join(','),
                                        raf: raf, ticks: ticks, resizes: resizes}, share));
}
</script></body></html>`;

const server = http.createServer((req, res) => {
  res.writeHead(200, { 'Content-Type': 'text/html' });
  res.end(PAGE.replace('TITLE', req.url.includes('target') ? 'capture-target' : 'capture-asker'));
});
await new Promise(r => server.listen(0, '127.0.0.1', r));
const base = `http://127.0.0.1:${server.address().port}`;

fs.rmSync(scratch, { recursive: true, force: true });
fs.mkdirSync(scratch, { recursive: true });
const child = spawn(app, ['--headless=new', `--user-data-dir=${scratch}/profile`, '--no-first-run', '--use-mock-keychain',
  '--remote-debugging-port=0', '--disable-background-networking', '--disable-component-update',
  '--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1', '--auto-select-tab-capture-source-by-title=capture-target',
  '--enable-logging=stderr', ...extra, 'about:blank'],
  { env: { ...process.env, BREAKPAD_DUMP_LOCATION: `${scratch}/crashes` }, stdio: ['ignore', 'ignore', fs.openSync(`${scratch}/chromium.log`, 'w')] });
const sleep = ms => new Promise(r => setTimeout(r, ms));
let port;
for (let i = 0; i < 100 && !port; i++) {
  await sleep(200);
  try { port = fs.readFileSync(path.join(scratch, 'profile/DevToolsActivePort'), 'utf8').split('\n'); } catch {}
}
if (!port) { child.kill(); throw new Error('no DevTools port'); }
const ws = new WebSocket(`ws://127.0.0.1:${port[0]}${port[1]}`);
await new Promise((r, j) => { ws.onopen = r; ws.onerror = j; });
let id = 0; const waiting = new Map();
ws.onmessage = m => { const d = JSON.parse(m.data); if (d.id && waiting.has(d.id)) { waiting.get(d.id)(d); waiting.delete(d.id); } };
const send = (method, params = {}, sessionId) => new Promise((resolve, reject) => {
  const n = ++id; waiting.set(n, d => d.error ? reject(new Error(method + ': ' + JSON.stringify(d.error))) : resolve(d.result));
  ws.send(JSON.stringify({ id: n, method, params, sessionId }));
});
const open = async (url, options) => {
  const { targetId } = await send('Target.createTarget', { url, ...options });
  const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true });
  return { targetId, sessionId };
};
const evaluate = async (tab, expression) =>
  (await send('Runtime.evaluate', { expression, userGesture: true, returnByValue: true }, tab.sessionId)).result.value;

try {
  const asker = await open(base + '/asker', {});
  const target = await open(base + '/target', { background: true });
  await sleep(1500);
  console.log('version ', (await send('Browser.getVersion')).product);
  console.log('asker   ', await evaluate(asker, 'state()'));
  console.log('before  ', await evaluate(target, 'state()'));
  const started = Date.now();
  await evaluate(asker, 'ask(false)');
  let state;
  for (;;) {
    await sleep(250);
    state = JSON.parse(await evaluate(asker, 'state()'));
    if ((state.share === 'live' && state.frames >= 2) || state.share.startsWith('error') || Date.now() - started > 20000) break;
  }
  console.log(`outcome  after ${((Date.now() - started) / 1000).toFixed(1)} s`, JSON.stringify(state));
  await sleep(700);
  console.log('during  ', await evaluate(target, 'state()'));
  await evaluate(asker, "window.stream && window.stream.getTracks().forEach(function (t) { t.stop(); }), true");
  await sleep(1000);
  console.log('after   ', await evaluate(target, 'state()'));
} finally {
  await send('Browser.close').catch(() => {});
  await sleep(500);
  child.kill();
  server.close();
}
