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

Tagged releases ship a signed, universal binary. It is not notarized, so Gatekeeper warns on first run; clear the quarantine flag with `xattr -d com.apple.quarantine agent-browser` (see [Release](#release)).

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
| `click` / `submit <ref>`, `fill <ref> <text>`, `fill <ref> --secret <entry>`, `login <entry>`, `upload <ref> <abs-path…>` | act on an element |
| `wait [--load] [--idle] [--download] [--selector] [--gone] [--text] [--url] [--ms] [--timeout]` | wait for conditions |
| `screenshot [path]` | PNG of the viewport |
| `tabs`, `tab new [url]` / `switch <id>` / `close [id]` | popups and `target=_blank` open as a new current tab |
| `downloads` | files saved from downloads |
| `cookies export [file]` / `import <file>` / `clear`, `storage export` / `import` | move login state in or out |
| `viewport [W H]`, `useragent <ua>\|reset`, `block images\|media\|fonts\|scripts\|styles\|url <re>\|clear` | page environment |
| `watch [on\|off\|pause\|resume\|status]` | live window; `pause` hands control to you |
| `totp enroll <entry>`, `recovery save <entry>` | capture 2FA setup secrets and recovery codes straight into the vault |
| `vault list` / `audit` (`add`, `rm`, `export` are for you) | saved logins, see [Vault](#vault-logins-for-bots) |
| `sessions` | every running session with its state; never starts one |
| `menubar [start\|install\|uninstall]` | menu bar item, see [Menu bar](#menu-bar) |
| `status`, `cdp`, `mcp`, `close` | |

`--profile NAME` keeps cookies and storage between runs (default: temporary, discarded on close). The helper also saves **all** of the profile's cookies, session cookies without an expiry included, to `~/.agent-browser/profiles/NAME/cookies.enc` and restores them at startup, because WebKit drops session cookies on exit and, on some macOS versions, doesn't write its store before exiting. That file is encrypted (AES-256-GCM) with a random key kept in your login keychain, and is owner-only; if the key is unavailable the cookies are not saved (never written as plain text), and a file that can't be decrypted is kept as `cookies.enc.unreadable`. WebKit's own data folder for the profile (localStorage and similar) is not encrypted by agent-browser; FileVault covers it. `cookies export` writes the plain JSON you ask for, owner-only. The menu bar item shows each session's profile and when its cookies were last saved.

## What agents get back

```json
{"ok": true, "result": {"outcome": "dialog: alert(\"hi\")"}, "events": [{"type": "console-error", "message": "…"}]}
{"ok": false, "error": {"code": "ELEMENT_COVERED", "message": "button \"Buy now\" is covered by div#ov.overlay at (640,400).", "retry_safe": true}, "events": []}
```

- **`outcome`** says what an action did: `navigated: /done`, `dialog: …`, `download: file (N bytes)`, `opened tab t2`, `submitted`, `dom-changed` or `no-op`.
- **`events`** list navigations, loads, redirects, dialogs (auto-accepted), console errors, failed requests, form submits and downloads since the last command.
- **`retry_safe: true`** means the command had no effect, so it can be run again once the cause is fixed.
- Common codes: `STALE_REF`, `ELEMENT_COVERED`, `ELEMENT_HIDDEN`, `ELEMENT_DISABLED`, `VALIDATION_FAILED`, `NOT_FILE_INPUT`, `TIMEOUT`, `NAVIGATION_FAILED`, `NO_SUCH_TAB`; vault: `ORIGIN_MISMATCH`, `VAULT_NO_ENTRY`, `VAULT_APPROVAL_DENIED`, `VAULT_NEEDS_TTY`, `NO_LOGIN_FIELDS`, `TOTP_NOT_FOUND`, `TOTP_AMBIGUOUS`.
- **`needs_human`** appears in a result when the page looks like a CAPTCHA or a "prove you are human" check. Agents are told not to solve or bypass it: they run `watch on` and `watch pause`, ask you to complete it, then `watch resume`. The session shows as needing you in the menu bar. It is a heuristic hint, not an error.
- Snapshot ids are unique across tabs, so a ref can never act on the wrong page.

## MCP

```sh
claude mcp add agent-browser -- /path/to/agent-browser mcp
```

25 tools (`browser_open`, `browser_snapshot`, `browser_click`, `browser_login`, …) map one to one onto the commands above. Usage guidance is sent in the server's `instructions`.

## Menu bar

`agent-browser menubar` starts a small menu bar item (it detaches, so you can close the terminal; `menubar install` starts it at login, `menubar uninstall` removes that). It lists every running session with its page and state (idle, working on a command, paused, or waiting for your approval) and lets you show or hide its window, take over (pause the agent) and resume, save a screenshot to the Desktop, see the recent steps, or close the session. The icon changes when something needs you, and a notification appears when a command is waiting for you or a saved login needs approval. It never starts a browser, and the browsers keep running if it quits.

## Vault (logins for bots)

The bots have their own credential store, separate from your Passwords app and Safari. Entries live in the login keychain under `dev.appler.agent-browser.vault`.

```sh
agent-browser vault add github --origin https://github.com --totp --confirm   # you, in a terminal; prompts hide the password
agent-browser login github --submit        # the agent: fills username, password and the current one-time code
agent-browser fill @s1:e4 --secret github --field password
```

- **Agents see names, not values.** The helper types the value; results, events, snapshots and errors never contain it, and anything a page echoes back (a password in a GET url) is redacted. No command reads a value out.
- **Locked to the site.** An entry only works on its own origin (https, or http on localhost); elsewhere you get `ORIGIN_MISMATCH` and nothing is typed. The check also runs inside the page at fill time.
- **`vault add` and `rm` need an interactive terminal**, so a program cannot create, replace or delete entries. Replacing an entry means typing the password again.
- **More than one host:** repeat `--origin` on `vault add`, or change an existing entry's sites without touching its password with `vault origin NAME --add https://nid.example.com --remove https://old.example.com` (terminal only; entries with `--confirm` ask for approval).
- **`--totp`** stores a base32 secret or `otpauth://` URI; `login` fills the current code. **`--confirm`** asks for Touch ID or your password on every use.
- **Signing up with 2FA:** on the setup page, `totp enroll github` reads the QR code (decoded with Vision), the `otpauth://` link or the setup key and saves it into the entry; the agent never receives it, and snapshots hide setup keys and links. It refuses to guess if the page shows different secrets. Then `fill REF --secret github --field totp` types the first code. `recovery save github` stores the recovery codes the same way (`--selector CSS` if they aren't found automatically). You can also enter them yourself with `vault recovery github`.
- **Your own backup:** `agent-browser vault export github [--qr]` (terminal only, asks for Touch ID or your password) prints the TOTP secret, the `otpauth://` link, the current code and the recovery codes, and can draw a QR code to scan into your own authenticator. Store that in your password manager or print it; the vault lives only in this Mac's login keychain and does not sync.
- **Audit:** every use is logged without values to `~/.agent-browser/vault-audit.log` (`vault audit`).
- **Not combined with DevTools:** a session that typed secrets refuses `cdp start`, and entries are refused while it runs, since a DevTools client could read the page.

The vault protects the password and the TOTP seed. A setup page shows its key before enrollment, so an agent that screenshots it first can still see the QR code; recovery codes are visible to an agent that reads that page before `recovery save` (afterwards they are redacted from output). It does not hide the signed-in session itself (`cookies export` still returns session cookies), a visible one-time code can show up in a screenshot, and a compromised site you allowed can read what you type into it.

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
Tests/integration.sh        # drives the real helper against local fixtures (≈30 s, 227 checks; needs jq, optionally node 22+ and network)
Tests/cdp-compat.sh         # opt-in: installs Puppeteer and Playwright in a temp dir and runs both
```

Set `AGENT_BROWSER_CDP_TRACE=<file>` before starting the helper to log DevTools traffic.

### Release

`Scripts/package.sh` builds a universal binary, signs it (Developer ID, Hardened Runtime), runs the integration tests against the signed binary, notarizes it when credentials are available (otherwise it warns and skips) and writes `dist/agent-browser-<version>-macos.tar.gz`. Locally it uses the Developer ID identity from your keychain (team in a git-ignored `.signing.local`); notarization needs an `AgentBrowser-Notary` keychain profile or `ASC_*` variables. Pushing a tag `vX.Y.Z` matching `VERSION` runs `.github/workflows/release.yml`, which needs the repository secrets `TEAM_ID`, `MACOS_CERTIFICATE`, `MACOS_CERTIFICATE_PWD` and `KEYCHAIN_PASSWORD`; add `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_P8` to also notarize. Keep `VERSION` and `Sources/agent-browser/Version.swift` in step.

## License

[MIT](LICENSE)
