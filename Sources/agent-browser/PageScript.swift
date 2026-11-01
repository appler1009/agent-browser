// JS injected at document start in the main frame. Exposes window.__abApi.

let pageScript = #"""
(function () {
  if (window.__abApi) return;
  const post = (o) => { try { window.webkit.messageHandlers.ab.postMessage(o); } catch (e) {} };
  const short = (s, n) => {
    s = String(s == null ? '' : s).replace(/\s+/g, ' ').trim();
    return s.length > n ? s.slice(0, n - 1) + '…' : s;
  };
  const API = { snap: 0, map: new Map(), pending: 0, mut: 0 };
  Object.defineProperty(window, '__abApi', { value: API, enumerable: false });

  // ---- event hooks -------------------------------------------------------
  try {
    const isHl = (r) => API.hl && (r.target === API.hl ||
      Array.prototype.some.call(r.addedNodes, (x) => x === API.hl) ||
      Array.prototype.some.call(r.removedNodes, (x) => x === API.hl));
    new MutationObserver((m) => { API.mut += m.filter((r) => !isHl(r)).length; })
      .observe(document, { subtree: true, childList: true, attributes: true, characterData: true });
  } catch (e) {}

  const of = window.fetch;
  if (of) {
    window.fetch = function () {
      API.pending++;
      const a = arguments;
      return of.apply(this, a).then(
        (r) => { API.pending--; post({ type: 'cdp:net', kind: 'Fetch', url: String(r.url), method: String((a[1] && a[1].method) || (a[0] && a[0].method) || 'GET').toUpperCase(), status: r.status }); if (!r.ok) post({ type: 'request-failed', url: String(r.url), status: r.status }); return r; },
        (e) => { API.pending--; post({ type: 'request-failed', url: String((a[0] && a[0].url) || a[0]), error: String(e) }); throw e; });
    };
  }
  const xo = XMLHttpRequest.prototype.open, xs = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function (m, u) { this.__abUrl = u; this.__abMethod = m; return xo.apply(this, arguments); };
  XMLHttpRequest.prototype.send = function () {
    API.pending++;
    this.addEventListener('loadend', () => {
      API.pending--;
      post({ type: 'cdp:net', kind: 'XHR', url: String(this.__abUrl), method: String(this.__abMethod || 'GET').toUpperCase(), status: this.status });
      if (this.status === 0 || this.status >= 400) post({ type: 'request-failed', url: String(this.__abUrl), status: this.status });
    });
    return xs.apply(this, arguments);
  };
  const ce = console.error;
  console.error = function () {
    try {
      post({ type: 'console-error', message: short(Array.from(arguments).map((a) => {
        try { return typeof a === 'string' ? a : (a && a.stack) || JSON.stringify(a); } catch (e) { return String(a); }
      }).join(' '), 300) });
    } catch (e) {}
    return ce.apply(this, arguments);
  };
  window.addEventListener('error', (e) => {
    if (e.target && e.target !== window && e.target.nodeType === 1) {
      post({ type: 'request-failed', url: String(e.target.src || e.target.href || ''), error: 'resource failed to load' });
    } else {
      post({ type: 'page-error', message: short(e.message, 300), line: e.lineno });
    }
  }, true);
  window.addEventListener('unhandledrejection', (e) => {
    post({ type: 'page-error', message: 'unhandledrejection: ' + short((e.reason && e.reason.message) || e.reason, 300) });
  });
  document.addEventListener('submit', (e) => {
    const f = e.target;
    setTimeout(() => post({
      type: 'form-submit', action: f.getAttribute && f.getAttribute('action'),
      method: ((f.method) || 'get').toLowerCase(), handled_by_page: e.defaultPrevented
    }), 0);
  }, true);

  // ---- helpers -----------------------------------------------------------
  const cs = (el) => getComputedStyle(el);
  const SKIP = new Set(['script', 'style', 'noscript', 'template', 'head', 'meta', 'link', 'svg', 'canvas']);

  function isHidden(el) {
    const s = cs(el);
    if (s.display === 'none' || s.visibility === 'hidden' || s.visibility === 'collapse') return true;
    if (parseFloat(s.opacity) === 0) return true;
    if (!el.getClientRects().length) return true;
    const b = el.getBoundingClientRect();
    return b.width === 0 && b.height === 0;
  }
  function isDisabled(el) {
    try { if (el.matches(':disabled')) return true; } catch (e) {}
    return el.getAttribute('aria-disabled') === 'true';
  }
  function describe(el) {
    let s = el.tagName.toLowerCase();
    if (el.id) s += '#' + el.id;
    if (el.classList && el.classList.length) s += '.' + Array.from(el.classList).slice(0, 3).join('.');
    const r = el.getAttribute('role');
    if (r) s += '[role=' + r + ']';
    const t = short(el.innerText || el.textContent || '', 50);
    if (t) s += ' "' + t + '"';
    return s;
  }
  const INPUT_ROLE = { checkbox: 'checkbox', radio: 'radio', button: 'button', submit: 'button', reset: 'button',
    image: 'button', range: 'slider', search: 'searchbox', file: 'file-input', number: 'spinbutton' };
  function roleOf(el) {
    const ar = el.getAttribute('role');
    if (ar) return ar.split(/\s+/)[0];
    switch (el.tagName.toLowerCase()) {
      case 'a': return el.hasAttribute('href') ? 'link' : null;
      case 'button': case 'summary': return 'button';
      case 'input': {
        const ty = (el.getAttribute('type') || 'text').toLowerCase();
        if (ty === 'hidden') return null;
        return INPUT_ROLE[ty] || 'textbox';
      }
      case 'textarea': return 'textbox';
      case 'select': return el.multiple ? 'listbox' : 'combobox';
      case 'img': return 'img';
      case 'h1': case 'h2': case 'h3': case 'h4': case 'h5': case 'h6': return 'heading';
      case 'nav': return 'navigation';
      case 'main': return 'main';
      case 'form': return 'form';
      case 'dialog': return 'dialog';
      case 'header': return 'banner';
      case 'footer': return 'contentinfo';
      case 'aside': return 'complementary';
      case 'iframe': return 'iframe';
    }
    if (el.getAttribute('contenteditable') !== null && el.isContentEditable) return 'textbox';
    return null;
  }
  const INTERACTIVE = new Set(['link', 'button', 'textbox', 'searchbox', 'checkbox', 'radio', 'combobox', 'listbox',
    'slider', 'switch', 'tab', 'menuitem', 'menuitemcheckbox', 'menuitemradio', 'option', 'file-input', 'spinbutton', 'treeitem']);
  function isInteractive(el, role) {
    if (role && INTERACTIVE.has(role)) return 'role';
    if (el.hasAttribute('onclick')) return 'clickable';
    const ti = el.getAttribute('tabindex');
    if (ti !== null && parseInt(ti, 10) >= 0) return 'clickable';
    if (!role && el.parentElement && cs(el).cursor === 'pointer' && cs(el.parentElement).cursor !== 'pointer') return 'clickable';
    return null;
  }
  function nameOf(el) {
    let n = el.getAttribute('aria-label');
    if (n && short(n, 1)) return short(n, 100);
    const lb = el.getAttribute('aria-labelledby');
    if (lb) {
      const t = lb.split(/\s+/).map((id) => { const x = document.getElementById(id); return x ? x.textContent : ''; }).join(' ');
      if (short(t, 1)) return short(t, 100);
    }
    const tag = el.tagName.toLowerCase();
    if (el.labels && el.labels.length) {
      const t = Array.from(el.labels).map((l) => l.textContent).join(' ');
      if (short(t, 1)) return short(t, 100);
    }
    if (tag === 'input') {
      const ty = (el.getAttribute('type') || 'text').toLowerCase();
      if (ty === 'button' || ty === 'submit' || ty === 'reset')
        return short(el.value || (ty === 'submit' ? 'Submit' : ty === 'reset' ? 'Reset' : ''), 100);
      if (ty === 'image') return short(el.alt, 100);
    }
    if (tag === 'img') return short(el.alt, 100);
    if (tag !== 'input' && tag !== 'textarea' && tag !== 'select') {
      const t = short(el.innerText != null ? el.innerText : el.textContent, 100);
      if (t) return t;
    }
    return short(el.getAttribute('title') || el.getAttribute('placeholder') || el.getAttribute('alt') || el.getAttribute('name') || '', 100);
  }
  function stateOf(el) {
    const st = [];
    if (isDisabled(el)) st.push('disabled');
    const tag = el.tagName;
    const ty = tag === 'INPUT' ? (el.type || '').toLowerCase() : '';
    if (ty === 'checkbox' || ty === 'radio') st.push(el.checked ? 'checked' : 'unchecked');
    else if (el.getAttribute('aria-checked')) st.push(el.getAttribute('aria-checked') === 'true' ? 'checked' : 'unchecked');
    for (const a of ['expanded', 'selected', 'pressed']) {
      const v = el.getAttribute('aria-' + a);
      if (v !== null) st.push(v === 'true' ? a : 'not-' + a);
    }
    if (el.required) st.push('required');
    if (el.readOnly) st.push('readonly');
    if (document.activeElement === el) st.push('focused');
    if (tag === 'INPUT' || tag === 'TEXTAREA') {
      if (ty === 'password') { if (el.value) st.push('value=•••(' + el.value.length + ')'); }
      else if (!['checkbox', 'radio', 'button', 'submit', 'reset', 'image', 'file'].includes(ty) && el.value)
        st.push('value="' + short(el.value, 60) + '"');
    } else if (tag === 'SELECT') {
      const o = el.selectedOptions && el.selectedOptions[0];
      if (o) st.push('value="' + short(o.textContent, 60) + '"');
    }
    return st;
  }
  function related(el, hit) {
    if (hit === el || el.contains(hit)) return true;
    const lab = el.closest && el.closest('label');
    if (lab && lab.contains(hit)) return true;
    if (el.labels) for (const l of el.labels) if (l.contains(hit)) return true;
    let r = el.getRootNode();
    while (r && r.host) { if (r.host === hit) return true; r = r.host.getRootNode(); }
    return false;
  }
  // Returns {x,y} of a click point if the element is the top element there, else an error descriptor.
  function hitTest(el) {
    const r = el.getBoundingClientRect();
    const l = Math.max(r.left, 0), rr = Math.min(r.right, innerWidth);
    const t = Math.max(r.top, 0), b = Math.min(r.bottom, innerHeight);
    if (!(rr > l) || !(b > t)) return { offscreen: true };
    const x = (l + rr) / 2, y = (t + b) / 2;
    const root = el.getRootNode();
    const hit = (root.elementFromPoint ? root : document).elementFromPoint(x, y);
    if (!hit) return { offscreen: true };
    if (!related(el, hit)) return { covered_by: describe(hit), x, y };
    return { x, y };
  }

  // ---- snapshot ----------------------------------------------------------
  API.snapshot = function (id) {
    API.snap = id;
    API.map = new Map();
    const lines = [];
    let n = 0, count = 0, truncated = false;
    const MAX = 1500;
    const prefix = '@s' + API.snap + ':e';
    function emit(depth, text) {
      if (count++ >= MAX) { truncated = true; return; }
      lines.push('  '.repeat(depth) + text);
    }
    function children(node) {
      if (node.shadowRoot) return Array.from(node.shadowRoot.childNodes);
      if (node.tagName === 'SLOT') return node.assignedNodes({ flatten: true });
      return Array.from(node.childNodes);
    }
    function visit(node, depth) {
      if (truncated) return;
      if (node.nodeType === 3) {
        const p = node.parentElement;
        const t = short(node.nodeValue, 120);
        if (t && p && cs(p).visibility === 'visible') emit(depth, 'text "' + t + '"');
        return;
      }
      if (node.nodeType !== 1) return;
      const tag = node.tagName.toLowerCase();
      if (SKIP.has(tag)) return;
      if (cs(node).display === 'none') return;
      const role = roleOf(node);
      const kind = isInteractive(node, role);
      if (kind) {
        const hiddenFile = role === 'file-input' && isHidden(node);
        if (isHidden(node) && !hiddenFile) return;
        const ref = prefix + (++n);
        API.map.set(n, node);
        const st = stateOf(node);
        if (hiddenFile) st.push('hidden');
        const r = node.getBoundingClientRect();
        const inView = r.bottom > 0 && r.top < innerHeight && r.right > 0 && r.left < innerWidth;
        if (hiddenFile) { /* not rendered: no position to check */ }
        else if (inView) {
          const h = hitTest(node);
          if (h.covered_by) st.push('covered by ' + h.covered_by);
        } else st.push('offscreen');
        let line = (kind === 'clickable' && !role ? 'clickable' : role) + ' "' + nameOf(node) + '" ' + ref;
        if (tag === 'a') line += ' href="' + short(node.getAttribute('href'), 80) + '"';
        if (st.length) line += ' [' + st.join(', ') + ']';
        emit(depth, line);
        return;
      }
      if (role === 'heading') {
        const t = short(node.innerText || node.textContent, 120);
        if (t) emit(depth, 'heading[' + tag.slice(1) + '] "' + t + '"');
        return;
      }
      if (role === 'img') { const a = short(node.alt, 80); if (a) emit(depth, 'img "' + a + '"'); return; }
      if (role === 'iframe') { emit(depth, 'iframe "' + short(node.title || node.getAttribute('src'), 80) + '" (contents not included)'); return; }
      if (tag === 'label' && node.control) return; // its text is the control's name
      let d = depth;
      const landmark = role && ['navigation', 'main', 'form', 'dialog', 'banner', 'contentinfo', 'complementary', 'alert', 'alertdialog', 'region'].includes(role);
      if (landmark || node.getAttribute('aria-modal') === 'true') {
        const nm = short(node.getAttribute('aria-label') || '', 60);
        emit(depth, (role || 'dialog') + (nm ? ' "' + nm + '"' : ''));
        d = depth + 1;
      }
      for (const c of children(node)) visit(c, d);
    }
    visit(document.body || document.documentElement, 0);
    return {
      snapshot: API.snap, url: location.href, title: document.title,
      viewport: { w: innerWidth, h: innerHeight }, scroll: { x: Math.round(scrollX), y: Math.round(scrollY) },
      refs: n, truncated: truncated, tree: lines.join('\n')
    };
  };

  // ---- actions -----------------------------------------------------------
  function err(code, message, extra) { return Object.assign({ ok: false, code: code, message: message, retry_safe: true }, extra || {}); }
  function resolve(ref) {
    const m = /^@?s(\d+):e(\d+)$/.exec(String(ref || ''));
    if (!m) return { error: err('BAD_REF', 'Malformed ref "' + ref + '"; expected @s<snapshot>:e<n> as printed by snapshot.') };
    if (API.snap === 0) return { error: err('STALE_REF', 'No snapshot exists for this page (it may have navigated since ' + ref + ' was taken). No action was performed; run snapshot again.') };
    if (+m[1] !== API.snap) return { error: err('STALE_REF', 'Ref ' + ref + ' is from snapshot s' + m[1] + ' but the current snapshot is s' + API.snap + '. No action was performed; use refs from the latest snapshot.') };
    const el = API.map.get(+m[2]);
    if (!el || !el.isConnected) return { error: err('STALE_REF', 'The element for ' + ref + ' is no longer in the document. No action was performed; run snapshot again.') };
    return { el: el };
  }
  // Red outline drawn over the target while the watch window is open (ignored by mutation counting).
  function highlight(el) {
    try {
      const r = el.getBoundingClientRect();
      if (!API.hl) {
        const d = document.createElement('div');
        d.setAttribute('data-ab-hl', '');
        d.style.cssText = 'position:fixed;pointer-events:none;z-index:2147483647;box-sizing:border-box;border:3px solid #ff3b30;border-radius:4px;box-shadow:0 0 0 2px rgba(255,255,255,.85)';
        API.hl = d;
      }
      const d = API.hl;
      d.style.left = r.left + 'px'; d.style.top = r.top + 'px';
      d.style.width = r.width + 'px'; d.style.height = r.height + 'px';
      document.documentElement.appendChild(d);
      clearTimeout(API.hlT);
      API.hlT = setTimeout(() => d.remove(), 2000);
    } catch (e) {}
  }
  function actionable(el) {
    if (isHidden(el)) return err('ELEMENT_HIDDEN', describe(el) + ' is not visible (display:none, visibility:hidden, opacity:0 or zero size).', { element: describe(el) });
    if (isDisabled(el)) return err('ELEMENT_DISABLED', describe(el) + ' is disabled.', { element: describe(el) });
    el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
    if (API.watch) highlight(el);
    const h = hitTest(el);
    if (h.offscreen) return err('OFFSCREEN', describe(el) + ' could not be scrolled into the viewport.', { element: describe(el) });
    if (h.covered_by) return err('ELEMENT_COVERED', describe(el) + ' is covered by ' + h.covered_by + ' at (' + Math.round(h.x) + ',' + Math.round(h.y) + ').',
      { element: describe(el), covered_by: h.covered_by });
    return { ok: true, x: h.x, y: h.y };
  }
  const NON_TEXT = ['checkbox', 'radio', 'button', 'submit', 'reset', 'image', 'file', 'range', 'color', 'hidden'];
  API.act = function (op, ref, arg, watch) {
    API.watch = !!watch;
    const r = resolve(ref);
    if (r.error) return r.error;
    const el = r.el;
    try {
      if (op === 'click') {
        const a = actionable(el);
        if (!a.ok) return a;
        if (el.focus) el.focus({ preventScroll: true });
        const o = { bubbles: true, cancelable: true, composed: true, view: window, clientX: a.x, clientY: a.y, button: 0 };
        const po = Object.assign({ pointerId: 1, pointerType: 'mouse', isPrimary: true }, o);
        el.dispatchEvent(new PointerEvent('pointerdown', po));
        el.dispatchEvent(new MouseEvent('mousedown', o));
        el.dispatchEvent(new PointerEvent('pointerup', po));
        el.dispatchEvent(new MouseEvent('mouseup', o));
        el.click();
        return { ok: true, element: describe(el) };
      }
      if (op === 'fill') {
        const tag = el.tagName, ty = (el.type || '').toLowerCase();
        const isField = tag === 'TEXTAREA' || (tag === 'INPUT' && !NON_TEXT.includes(ty));
        if (!isField && !el.isContentEditable) return err('NOT_FILLABLE', describe(el) + ' is not a text field.', { element: describe(el) });
        const a = actionable(el);
        if (!a.ok) return a;
        if (el.readOnly) return err('ELEMENT_READONLY', describe(el) + ' is read-only.', { element: describe(el) });
        el.focus({ preventScroll: true });
        if (isField) {
          const proto = tag === 'INPUT' ? HTMLInputElement.prototype : HTMLTextAreaElement.prototype;
          Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, arg);
        } else el.textContent = arg;
        el.dispatchEvent(new InputEvent('input', { bubbles: true, composed: true, inputType: 'insertText', data: arg }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
        const res = { ok: true, element: describe(el), value: ty === 'password' ? '•'.repeat(arg.length) : short(arg, 80) };
        if (isField && el.value !== arg && ty !== 'password') res.value_after = short(el.value, 80);
        return res;
      }
      if (op === 'upload') {
        if (el.tagName !== 'INPUT' || (el.type || '').toLowerCase() !== 'file')
          return err('NOT_FILE_INPUT', describe(el) + ' is not an input[type=file]. Use the ref of the file input (snapshot lists hidden ones too).', { element: describe(el) });
        if (isDisabled(el)) return err('ELEMENT_DISABLED', describe(el) + ' is disabled.', { element: describe(el) });
        const spec = JSON.parse(arg);
        if (spec.length > 1 && !el.multiple) return err('NOT_MULTIPLE', describe(el) + ' accepts a single file.', { element: describe(el) });
        const dt = new DataTransfer();
        for (const f of spec) {
          const bin = atob(f.b64), u8 = new Uint8Array(bin.length);
          for (let i = 0; i < bin.length; i++) u8[i] = bin.charCodeAt(i);
          dt.items.add(new File([u8], f.name, { type: f.type }));
        }
        el.files = dt.files;
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
        return { ok: true, element: describe(el), files: spec.map((f) => f.name) };
      }
      if (op === 'submit') {
        const form = el.tagName === 'FORM' ? el : (el.form || el.closest('form'));
        if (API.watch && form) highlight(form);
        if (!form) return err('NO_FORM', describe(el) + ' is not inside a form.', { element: describe(el) });
        if (!form.noValidate && !form.checkValidity()) {
          const bad = form.querySelector(':invalid');
          return err('VALIDATION_FAILED', 'Form not submitted; ' + (bad ? describe(bad) + ': ' + bad.validationMessage : 'it is invalid') + '.', { element: bad ? describe(bad) : null });
        }
        form.requestSubmit();
        return { ok: true, element: describe(form) };
      }
      return err('BAD_OP', 'Unknown op ' + op);
    } catch (e) {
      return err('ACTION_FAILED', String(e && e.message || e), { retry_safe: false });
    }
  };

  API.waitState = function (sel, gone, text, urlSub) {
    const out = { ready: document.readyState === 'complete', pending: API.pending, mut: API.mut };
    try {
      if (sel) { const e = document.querySelector(sel); out.selector = !!e && !isHidden(e); }
      if (gone) { const e = document.querySelector(gone); out.gone = !e || isHidden(e); }
    } catch (e) { out.bad_selector = String(e.message || e); }
    if (text) out.text = ((document.body && document.body.innerText) || '').includes(text);
    if (urlSub) out.url = location.href.includes(urlSub);
    return out;
  };

  // ---- CDP support: remote objects, DOM node ids, input synthesis ---------
  API.objs = new Map(); API.objSeq = 0;
  API.nodeIds = new WeakMap(); API.nodeById = new Map(); API.nodeSeq = 0;
  function nodeIdOf(el) {
    let id = API.nodeIds.get(el);
    if (!id) { id = ++API.nodeSeq; API.nodeIds.set(el, id); API.nodeById.set(id, el); }
    return id;
  }
  const regObj = (v) => { const id = 'o' + (++API.objSeq); API.objs.set(id, v); return id; };
  function remote(v, byValue) {
    const t = typeof v;
    if (v === undefined) return { type: 'undefined' };
    if (v === null) return { type: 'object', subtype: 'null', value: null };
    if (t === 'boolean' || t === 'string') return { type: t, value: v };
    if (t === 'number') {
      if (!Number.isFinite(v) || Object.is(v, -0)) {
        const u = Number.isNaN(v) ? 'NaN' : Object.is(v, -0) ? '-0' : v > 0 ? 'Infinity' : '-Infinity';
        return { type: 'number', unserializableValue: u, description: u };
      }
      return { type: 'number', value: v, description: String(v) };
    }
    if (t === 'bigint') return { type: 'bigint', unserializableValue: v + 'n', description: v + 'n' };
    if (t === 'symbol') return { type: 'symbol', description: String(v), objectId: regObj(v) };
    if (t === 'function') return { type: 'function', className: 'Function', description: short(Function.prototype.toString.call(v), 200), objectId: regObj(v) };
    if (byValue) { try { return { type: 'object', value: JSON.parse(JSON.stringify(v)) }; } catch (e) { return { type: 'object', value: null }; } }
    let sub;
    if (Array.isArray(v)) sub = 'array'; else if (v instanceof Node) sub = 'node'; else if (v instanceof Error) sub = 'error';
    else if (v instanceof Promise) sub = 'promise'; else if (v instanceof RegExp) sub = 'regexp'; else if (v instanceof Date) sub = 'date';
    else if (v instanceof Map) sub = 'map'; else if (v instanceof Set) sub = 'set';
    const cn = (v.constructor && v.constructor.name) || 'Object';
    const o = { type: 'object', className: cn, objectId: regObj(v),
      description: v instanceof Element ? describe(v) : Array.isArray(v) ? 'Array(' + v.length + ')' : v instanceof Error ? errDesc(v) : cn };
    if (sub) o.subtype = sub;
    return o;
  }
  // JavaScriptCore's stack has no "Name: message" header (V8's does), so build it: clients show this text.
  function errDesc(e) { return e.name + ': ' + e.message + (e.stack ? '\n    at ' + String(e.stack).split('\n').join('\n    at ') : ''); }
  function exc(e) {
    const r = remote(e, false);
    if (e instanceof Error) r.description = errDesc(e);
    return { exceptionId: ++API.objSeq, text: 'Uncaught', lineNumber: 0, columnNumber: 0, exception: r };
  }
  API.cdpEvaluate = async function (expr, byValue, awaitP) {
    try {
      let v = (0, eval)(expr);
      if (awaitP && v && typeof v.then === 'function') v = await v;
      return { result: remote(v, byValue) };
    } catch (e) { return { result: remote(e, false), exceptionDetails: exc(e) }; }
  };
  const argValue = (a) => a.objectId ? API.objs.get(a.objectId)
    : a.unserializableValue !== undefined ? ({ 'NaN': NaN, 'Infinity': Infinity, '-Infinity': -Infinity, '-0': -0 })[a.unserializableValue] : a.value;
  API.cdpCall = async function (fnSrc, thisId, args, byValue, awaitP) {
    try {
      const fn = (0, eval)('(' + fnSrc + ')');
      let v = fn.apply(thisId ? API.objs.get(thisId) : undefined, (args || []).map(argValue));
      if (awaitP && v && typeof v.then === 'function') v = await v;
      return { result: remote(v, byValue) };
    } catch (e) { return { result: remote(e, false), exceptionDetails: exc(e) }; }
  };
  API.cdpProps = function (id, own) {
    const o = API.objs.get(id), out = [];
    if (o === undefined || o === null) return { result: out };
    const seen = new Set();
    for (let p = Object(o); p && p !== Object.prototype; p = own ? null : Object.getPrototypeOf(p)) {
      for (const k of Object.getOwnPropertyNames(p)) {
        if (seen.has(k)) continue; seen.add(k);
        let val; try { val = o[k]; } catch (e) { continue; }
        out.push({ name: k, value: remote(val, false), writable: true, configurable: true, enumerable: Object.prototype.propertyIsEnumerable.call(Object(o), k), isOwn: true });
      }
    }
    return { result: out };
  };
  API.cdpRelease = function (id) { if (id) API.objs.delete(id); else API.objs.clear(); };

  function nodeFrom(p) {
    if (p.objectId) return API.objs.get(p.objectId);
    return API.nodeById.get(p.nodeId || p.backendNodeId);
  }
  function nodeDesc(n, depth) {
    const d = { nodeId: nodeIdOf(n), backendNodeId: nodeIdOf(n), nodeType: n.nodeType, nodeName: n.nodeName,
      localName: n.localName || '', nodeValue: n.nodeType === 3 ? n.nodeValue : '', childNodeCount: n.childNodes.length };
    if (n.nodeType === 1) { d.attributes = []; for (const a of n.attributes) d.attributes.push(a.name, a.value); }
    if (n.nodeType === 9) { d.documentURL = location.href; d.baseURL = document.baseURI; }
    if (depth !== 0) d.children = Array.from(n.childNodes).filter((c) => c.nodeType === 1 || c.nodeType === 3).map((c) => nodeDesc(c, depth > 0 ? depth - 1 : depth));
    return d;
  }
  const quads = (el) => Array.from(el.getClientRects()).map((r) => [r.left, r.top, r.right, r.top, r.right, r.bottom, r.left, r.bottom]);
  API.cdpDom = function (op, p) {
    if (op === 'getDocument') return { root: nodeDesc(document, p.depth === undefined ? 1 : p.depth) };
    const el = nodeFrom(p);
    if (!el) return { error: 'Could not find node with given id' };
    switch (op) {
      case 'describeNode': return { node: nodeDesc(el, p.depth === undefined ? 0 : p.depth) };
      case 'resolveNode': return { object: remote(el, false) };
      case 'requestNode': return { nodeId: nodeIdOf(el) };
      case 'querySelector': { const r = el.querySelector(p.selector); return { nodeId: r ? nodeIdOf(r) : 0 }; }
      case 'querySelectorAll': return { nodeIds: Array.from(el.querySelectorAll(p.selector)).map(nodeIdOf) };
      case 'getBoxModel': {
        const r = el.getBoundingClientRect();
        const q = [r.left, r.top, r.right, r.top, r.right, r.bottom, r.left, r.bottom];
        return { model: { content: q, padding: q, border: q, margin: q, width: Math.round(r.width), height: Math.round(r.height) } };
      }
      case 'getContentQuads': return { quads: quads(el) };
      case 'scrollIntoViewIfNeeded': {
        const r = el.getBoundingClientRect();
        if (r.top < 0 || r.left < 0 || r.bottom > innerHeight || r.right > innerWidth) el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
        return {};
      }
      case 'focus': el.focus(); return {};
      case 'getOuterHTML': return { outerHTML: el.outerHTML };
      case 'getAttributes': { const a = []; for (const x of el.attributes) a.push(x.name, x.value); return { attributes: a }; }
    }
    return { error: 'unsupported DOM operation ' + op };
  };
  API.cdpFiles = function (p, spec) {
    const el = nodeFrom(p);
    if (!el || el.tagName !== 'INPUT' || el.type !== 'file') return { error: 'node is not an input[type=file]' };
    const dt = new DataTransfer();
    for (const f of spec) {
      const bin = atob(f.b64), u8 = new Uint8Array(bin.length);
      for (let i = 0; i < bin.length; i++) u8[i] = bin.charCodeAt(i);
      dt.items.add(new File([u8], f.name, { type: f.type }));
    }
    el.files = dt.files;
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
    return {};
  };

  let mouseDownTarget = null;
  API.cdpMouse = function (type, x, y, button, clickCount, dx, dy) {
    const t = document.elementFromPoint(x, y) || document.body;
    const btn = button === 'right' ? 2 : button === 'middle' ? 1 : 0;
    const o = { bubbles: true, cancelable: true, composed: true, view: window, clientX: x, clientY: y, screenX: x, screenY: y,
      button: btn, buttons: type === 'mouseReleased' ? 0 : (1 << btn), detail: clickCount || 1 };
    const po = Object.assign({ pointerId: 1, pointerType: 'mouse', isPrimary: true }, o);
    if (type === 'mouseMoved') {
      t.dispatchEvent(new PointerEvent('pointermove', po)); t.dispatchEvent(new MouseEvent('mousemove', o));
      if (API.hover !== t) { if (API.hover) API.hover.dispatchEvent(new MouseEvent('mouseout', o)); t.dispatchEvent(new MouseEvent('mouseover', o)); API.hover = t; }
    } else if (type === 'mousePressed') {
      mouseDownTarget = t;
      t.dispatchEvent(new PointerEvent('pointerdown', po)); t.dispatchEvent(new MouseEvent('mousedown', o));
      const f = t.closest && t.closest('a[href],button,input,select,textarea,summary,[tabindex],[contenteditable=""],[contenteditable="true"]');
      if (f && f.focus) f.focus({ preventScroll: true });
      else if (document.activeElement && document.activeElement !== document.body) document.activeElement.blur();
    } else if (type === 'mouseReleased') {
      t.dispatchEvent(new PointerEvent('pointerup', po)); t.dispatchEvent(new MouseEvent('mouseup', o));
      const d = mouseDownTarget; mouseDownTarget = null;
      if (d && (d === t || d.contains(t) || t.contains(d))) {
        if (btn === 2) t.dispatchEvent(new MouseEvent('contextmenu', o));
        else { t.dispatchEvent(new MouseEvent('click', o)); if (clickCount === 2) t.dispatchEvent(new MouseEvent('dblclick', o)); }
      }
    } else if (type === 'mouseWheel') {
      t.dispatchEvent(new WheelEvent('wheel', Object.assign({ deltaX: dx || 0, deltaY: dy || 0 }, o)));
      window.scrollBy(dx || 0, dy || 0);
    }
    return {};
  };
  function insertText(text) { try { return document.execCommand('insertText', false, text); } catch (e) { return false; } }
  API.cdpInsert = function (text) { return { ok: insertText(text) }; };
  function focusables() {
    return Array.from(document.querySelectorAll('a[href],button,input,select,textarea,summary,[tabindex],[contenteditable="true"]'))
      .filter((e) => !e.disabled && e.tabIndex >= 0 && !isHidden(e) && e.type !== 'hidden')
      .sort((a, b) => (a.tabIndex || 1e9) - (b.tabIndex || 1e9));
  }
  let keyInserted = false;
  API.cdpKey = function (type, key, code, text, modifiers, keyCode) {
    const ae = document.activeElement;
    const t = ae && ae !== document.documentElement ? ae : document.body;
    const m = modifiers || 0;
    const o = { key: key, code: code, bubbles: true, cancelable: true, composed: true, keyCode: keyCode || 0, which: keyCode || 0,
      altKey: !!(m & 1), ctrlKey: !!(m & 2), metaKey: !!(m & 4), shiftKey: !!(m & 8) };
    if (type === 'keyUp') { t.dispatchEvent(new KeyboardEvent('keyup', o)); return {}; }
    if (type === 'char') { if (!keyInserted && text) insertText(text); keyInserted = false; return {}; }
    keyInserted = false;
    if (!t.dispatchEvent(new KeyboardEvent('keydown', o))) return {};
    const enter = key === 'Enter' || text === '\r';
    const tag = t.tagName;
    if (enter) {
      t.dispatchEvent(new KeyboardEvent('keypress', o));
      if (tag === 'TEXTAREA' || t.isContentEditable) insertText('\n');
      else if (tag === 'BUTTON' || tag === 'A' || tag === 'SUMMARY') t.click();
      else if (tag === 'INPUT' && t.form) { if (t.form.noValidate || t.form.checkValidity()) t.form.requestSubmit(); }
    } else if (text) {
      t.dispatchEvent(new KeyboardEvent('keypress', o));
      insertText(text);
      keyInserted = true;
    } else if (key === 'Backspace') document.execCommand('delete');
    else if (key === 'Delete') document.execCommand('forwardDelete');
    else if (key === ' ' && (tag === 'BUTTON' || (tag === 'INPUT' && /^(checkbox|radio|button|submit)$/.test(t.type)))) t.click();
    else if (key === 'Tab') {
      const list = focusables();
      if (list.length) { const i = list.indexOf(t); list[(i + (m & 8 ? -1 : 1) + list.length) % list.length].focus(); }
    }
    return {};
  };
  API.cdpMetrics = function () {
    return { w: innerWidth, h: innerHeight, sw: document.documentElement.scrollWidth, sh: document.documentElement.scrollHeight,
      x: scrollX, y: scrollY, dpr: devicePixelRatio, url: location.href, origin: location.origin, mime: document.contentType };
  };
  API.cdpAx = function () {
    const out = [{ nodeId: '1', ignored: false, role: { type: 'role', value: 'RootWebArea' }, name: { type: 'computedString', value: document.title }, properties: [], childIds: [] }];
    for (const el of document.querySelectorAll('*')) {
      const role = roleOf(el);
      if (!role || el.closest('[aria-hidden=true]') || isHidden(el)) continue;
      const id = String(out.length + 1);
      out.push({ nodeId: id, parentId: '1', ignored: false, role: { type: 'role', value: role },
        name: { type: 'computedString', value: nameOf(el) }, properties: [], childIds: [], backendDOMNodeId: nodeIdOf(el) });
      out[0].childIds.push(id);
    }
    return { nodes: out };
  };
})();
"""#
