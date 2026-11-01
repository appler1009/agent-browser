# agent-browser

A lightweight local browser for AI agents on macOS, built on the system WebKit (`WKWebView`). It has real layout, CSS and JavaScript, so agents can use actual web apps, which `curl` can't do, and it needs no Chrome download.

- **Agent-native loop:** `snapshot` → act on a `ref` → `snapshot` again. Every command prints one JSON object.
- **Fails loudly:** acting on a hidden, disabled or covered element is an error that names the cause. A stale ref returns `STALE_REF`. Nothing reports success that didn't happen.
- **Windowless by default**, with an optional watch window that highlights the target and lets you pause and take over.
- **CLI, MCP server and a thin CDP endpoint** over the same engine.

Requires macOS 14+. Not a Chrome replacement: WebKit quirks apply, and there is no request interception.

## Install

```sh
swift build -c release            # binary at .build/release/agent-browser
```

Tagged releases ship a signed, notarized universal binary (see [Release](#release)).

## Quick start

```console
$ agent-browser open https://example.com
{"ok":true,"result":{"url":"https://example.com/","title":"Example Domain","status":200,"tab":"t1"},"events":[…]}
$ agent-browser snapshot --text
# https://example.com/ — Example Domain (snapshot s1, 1 refs)
text "This domain is for use in documentation examples without needing permission. …"
link "Learn more" @s1:e1 href="https://iana.org/help/example-domains"
$ agent-browser click @s1:e1
{"ok":true,"result":{"outcome":"navigated: /help/example-domains","url":"https://www.iana.org/help/example-domains",…},"events":[…]}
```

The first command starts a background helper that owns the page (`close` stops it; it also exits after 30 idle minutes). `--session NAME` (or `AGENT_BROWSER_SESSION`) runs independent browsers side by side.

## Commands

| Command | |
|---|---|
| `open <url>` | navigate; a URL that is a file download is saved and reported |
| `snapshot [--text] [--interactive] [--max-chars N] [--max-nodes N] [--selector CSS]` | tree with refs (`@s3:e7`); same-origin iframes and open shadow roots included; flags cap the size |
| `click` / `submit <ref>`, `fill <ref> <text>`, `upload <ref> <abs-path…>` | act on an element |
| `wait [--load] [--idle] [--download] [--selector] [--gone] [--text] [--url] [--ms] [--timeout]` | wait for conditions |
| `screenshot [path]` | PNG of the viewport |
| `tabs`, `tab new [url]` / `switch <id>` / `close [id]` | popups and `target=_blank` open as a new current tab |
| `downloads` | files saved from downloads |
| `cookies export [file]` / `import <file>` / `clear`, `storage export` / `import` | move login state in or out |
| `viewport [W H]`, `useragent <ua>\|reset`, `block images\|media\|fonts\|scripts\|styles\|url <re>\|clear` | page environment |
| `watch [on\|off\|pause\|resume\|status]` | live window; `pause` hands control to you |
| `status`, `cdp`, `mcp`, `close` | |

`--profile NAME` keeps cookies and storage between runs (default: temporary, discarded on close). Exported cookie files are written `0600`.

## What agents get back

```json
{"ok": true, "result": {"outcome": "dialog: alert(\"hi\")"}, "events": [{"type": "console-error", "message": "…"}]}
{"ok": false, "error": {"code": "ELEMENT_COVERED", "message": "button \"Buy now\" is covered by div#ov.overlay at (640,400).", "retry_safe": true}, "events": []}
```

- **`outcome`** says what an action did: `navigated: /done`, `dialog: …`, `download: file (N bytes)`, `opened tab t2`, `submitted`, `dom-changed` or `no-op`.
- **`events`** list navigations, loads, redirects, dialogs (auto-accepted), console errors, failed requests, form submits and downloads since the last command.
- **`retry_safe: true`** means the command had no effect, so it can be run again once the cause is fixed.
- Common codes: `STALE_REF`, `ELEMENT_COVERED`, `ELEMENT_HIDDEN`, `ELEMENT_DISABLED`, `VALIDATION_FAILED`, `NOT_FILE_INPUT`, `TIMEOUT`, `NAVIGATION_FAILED`, `NO_SUCH_TAB`.
- Snapshot ids are unique across tabs, so a ref can never act on the wrong page.

## MCP

```sh
claude mcp add agent-browser -- /path/to/agent-browser mcp
```

20 tools (`browser_open`, `browser_snapshot`, `browser_click`, …) map one to one onto the commands above. Usage guidance is sent in the server's `instructions`.

## DevTools protocol (thin)

`agent-browser cdp start [--port N]` serves a localhost-only endpoint (`/json/version`, `/json/list`, WebSocket at `/devtools/browser|page/<id>`) that Puppeteer and Playwright can attach to:

```js
const browser = await puppeteer.connect({ browserWSEndpoint: ws });          // or
const browser = await chromium.connectOverCDP(ws);
```

Covers Target, Page (navigate, lifecycle, screenshot, PDF), Runtime, DOM, Input, Network (document and fetch/XHR events, cookies), Accessibility and the basics of Emulation. It is "compatible enough", not Chrome parity. Unsupported things fail with a protocol error rather than pretending: `Fetch` interception, browser contexts, request headers and throttling, touch. Requests carrying an `Origin` header or a non-local `Host` are refused, but any local process can use the endpoint while it is running, so start it only when needed (`cdp stop`).

## Limits

- Clicks and typing are synthesized in JavaScript, so `isTrusted` is false; a few sites check it.
- Cross-origin iframes are listed but not entered; closed shadow roots are invisible.
- JavaScript dialogs are accepted automatically; there is no file-chooser UI (use `upload`).
- One profile per session; CDP evaluation is blocked on pages whose CSP forbids `eval`.
- Pointer-driven pages that need real hover or drag are only approximated.

## Development

```sh
Tests/integration.sh        # drives the real helper against local fixtures (≈20 s; needs jq, optionally node 22+ and network)
Tests/cdp-compat.sh         # opt-in: installs Puppeteer and Playwright in a temp dir and runs both
```

Set `AGENT_BROWSER_CDP_TRACE=<file>` before starting the helper to log DevTools traffic.

### Release

`Scripts/package.sh` builds a universal binary, signs it (Developer ID, Hardened Runtime), runs the integration tests against the signed binary, notarizes it and writes `dist/agent-browser-<version>-macos.tar.gz`. Locally it uses the Developer ID identity from your keychain (team in a git-ignored `.signing.local`); notarization needs an `AgentBrowser-Notary` keychain profile or `ASC_*` variables. Pushing a tag `vX.Y.Z` matching `VERSION` runs `.github/workflows/release.yml`, which needs the repository secrets `TEAM_ID`, `MACOS_CERTIFICATE`, `MACOS_CERTIFICATE_PWD`, `KEYCHAIN_PASSWORD`, `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_P8`. Keep `VERSION` and `Sources/agent-browser/Version.swift` in step.

## License

[MIT](LICENSE)
