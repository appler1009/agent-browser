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
    new MutationObserver((m) => { API.mut += m.length; })
      .observe(document, { subtree: true, childList: true, attributes: true, characterData: true });
  } catch (e) {}

  const of = window.fetch;
  if (of) {
    window.fetch = function () {
      API.pending++;
      const a = arguments;
      return of.apply(this, a).then(
        (r) => { API.pending--; if (!r.ok) post({ type: 'request-failed', url: String(r.url), status: r.status }); return r; },
        (e) => { API.pending--; post({ type: 'request-failed', url: String((a[0] && a[0].url) || a[0]), error: String(e) }); throw e; });
    };
  }
  const xo = XMLHttpRequest.prototype.open, xs = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function (m, u) { this.__abUrl = u; return xo.apply(this, arguments); };
  XMLHttpRequest.prototype.send = function () {
    API.pending++;
    this.addEventListener('loadend', () => {
      API.pending--;
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
  API.snapshot = function () {
    API.snap++;
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
        if (isHidden(node)) return;
        const ref = prefix + (++n);
        API.map.set(n, node);
        const st = stateOf(node);
        const r = node.getBoundingClientRect();
        const inView = r.bottom > 0 && r.top < innerHeight && r.right > 0 && r.left < innerWidth;
        if (inView) {
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
  function actionable(el) {
    if (isHidden(el)) return err('ELEMENT_HIDDEN', describe(el) + ' is not visible (display:none, visibility:hidden, opacity:0 or zero size).', { element: describe(el) });
    if (isDisabled(el)) return err('ELEMENT_DISABLED', describe(el) + ' is disabled.', { element: describe(el) });
    el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
    const h = hitTest(el);
    if (h.offscreen) return err('OFFSCREEN', describe(el) + ' could not be scrolled into the viewport.', { element: describe(el) });
    if (h.covered_by) return err('ELEMENT_COVERED', describe(el) + ' is covered by ' + h.covered_by + ' at (' + Math.round(h.x) + ',' + Math.round(h.y) + ').',
      { element: describe(el), covered_by: h.covered_by });
    return { ok: true, x: h.x, y: h.y };
  }
  const NON_TEXT = ['checkbox', 'radio', 'button', 'submit', 'reset', 'image', 'file', 'range', 'color', 'hidden'];
  API.act = function (op, ref, arg) {
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
      if (op === 'submit') {
        const form = el.tagName === 'FORM' ? el : (el.form || el.closest('form'));
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
})();
"""#
