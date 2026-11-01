// Dependency-free CDP smoke test (Node 22+ has a built-in WebSocket client).
// usage: node raw.mjs <browser ws url> <fixtures dir>   -> prints one JSON object of results
const [, , wsUrl, fixtures] = process.argv;
const ws = new WebSocket(wsUrl);
let nextId = 0;
const pending = new Map();
const events = [];
ws.onmessage = (m) => {
  const msg = JSON.parse(m.data);
  if (msg.id !== undefined) { pending.get(msg.id)?.(msg); pending.delete(msg.id); } else events.push(msg);
};
await new Promise((r, j) => { ws.onopen = r; ws.onerror = () => j(new Error('ws error')); });
const send = (method, params = {}, sessionId) => new Promise((resolve) => {
  const id = ++nextId;
  pending.set(id, resolve);
  ws.send(JSON.stringify({ id, method, params, sessionId }));
});
const until = async (pred, ms = 8000) => {
  const t = Date.now();
  while (Date.now() - t < ms) { if (events.some(pred)) return true; await new Promise((r) => setTimeout(r, 20)); }
  return false;
};
const out = {};

out.version = (await send('Browser.getVersion')).result?.product;
const targets = (await send('Target.getTargets')).result.targetInfos;
out.pageTargets = targets.filter((t) => t.type === 'page').length;
const { sessionId } = (await send('Target.attachToTarget', { targetId: targets[0].targetId, flatten: true })).result;
out.attached = !!sessionId;
for (const d of ['Page', 'Runtime', 'DOM', 'Network']) await send(`${d}.enable`, {}, sessionId);
await send('Page.setLifecycleEventsEnabled', { enabled: true }, sessionId);

const nav = await send('Page.navigate', { url: `file://${fixtures}/login.html` }, sessionId);
out.navigateHasLoader = !!nav.result?.loaderId;
out.loadEvent = await until((e) => e.method === 'Page.loadEventFired');
out.lifecycle = events.filter((e) => e.method === 'Page.lifecycleEvent').map((e) => e.params.name);
out.frameNavigated = events.some((e) => e.method === 'Page.frameNavigated' && e.params.frame.url.endsWith('login.html'));

const ev = async (expression, extra = {}) => (await send('Runtime.evaluate', { expression, returnByValue: true, ...extra }, sessionId)).result;
out.sum = (await ev('1+2')).result.value;
out.title = (await ev('document.title')).result.value;
out.promise = (await ev('Promise.resolve(41).then(x => x + 1)', { awaitPromise: true })).result.value;
const thrown = await ev('(() => { throw new Error("boom") })()');
out.exception = thrown.exceptionDetails?.exception?.description?.split('\n')[0];
const h1 = (await send('Runtime.evaluate', { expression: 'document.querySelector("h1")' }, sessionId)).result.result;
out.h1Subtype = h1.subtype;
const called = (await send('Runtime.callFunctionOn', { objectId: h1.objectId, functionDeclaration: 'function () { return this.textContent }', returnByValue: true }, sessionId)).result;
out.callFunctionOn = called.result.value;

const doc = (await send('DOM.getDocument', { depth: 0 }, sessionId)).result.root;
const q = (await send('DOM.querySelector', { nodeId: doc.nodeId, selector: '#u' }, sessionId)).result.nodeId;
out.querySelector = q > 0;
const box = (await send('DOM.getBoxModel', { nodeId: q }, sessionId)).result.model;
out.boxHasSize = box.width > 10 && box.height > 5;
await send('DOM.focus', { nodeId: q }, sessionId);
await send('Input.insertText', { text: 'alice' }, sessionId);
out.typed = (await ev('document.getElementById("u").value')).result.value;
const cx = box.content[0] + box.width / 2, cy = box.content[1] + box.height / 2;
await send('Input.dispatchMouseEvent', { type: 'mousePressed', x: cx, y: cy, button: 'left', clickCount: 1 }, sessionId);
await send('Input.dispatchMouseEvent', { type: 'mouseReleased', x: cx, y: cy, button: 'left', clickCount: 1 }, sessionId);
out.focusedAfterClick = (await ev('document.activeElement.id')).result.value;

const shot = (await send('Page.captureScreenshot', { format: 'png' }, sessionId)).result;
out.screenshotBytes = Buffer.from(shot.data, 'base64').length;
out.axNodes = (await send('Accessibility.getFullAXTree', {}, sessionId)).result.nodes.length;

out.fetchEnable = (await send('Fetch.enable', {}, sessionId)).error?.message;
out.browserContext = (await send('Target.createBrowserContext')).error?.message;
out.unknown = (await send('Nope.nothing', {}, sessionId)).error?.code;
out.unknownSession = (await send('Page.enable', {}, 'does-not-exist')).error?.code;

const created = (await send('Target.createTarget', { url: 'about:blank' })).result.targetId;
out.createdListed = (await send('Target.getTargets')).result.targetInfos.some((t) => t.targetId === created);
out.closed = (await send('Target.closeTarget', { targetId: created })).result.success;
ws.close();
console.log(JSON.stringify(out));
process.exit(0);
