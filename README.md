# agent-browser

A lightweight local browser for AI agents on macOS, built on the system WebKit (`WKWebView`). It has real layout, CSS and JavaScript, so agents can use actual web apps, which `curl` can't do, and it needs no Chrome download.

- **Agent-native loop:** `snapshot` → act on a `ref` → `snapshot` again. Every command prints one JSON object.
- **Fails loudly:** acting on a hidden, disabled or covered element is an error that names the cause. A stale ref returns `STALE_REF`. Nothing reports success that didn't happen.
- **No window by default** (nothing on screen, not even a transparent one), with an optional watch window that highlights the target and lets you pause and take over. The watch window is an ordinary titled, resizable window, so a window manager can tile and move it; it has a Dock entry only while it is shown.
- **CLI, MCP server and a thin CDP endpoint** over the same engine.

Requires macOS 14+. Not a Chrome replacement: WebKit quirks apply, and there is no request interception.

## Install

Download `AgentBrowser-<version>.dmg` from [Releases](https://github.com/appler1009/agent-browser/releases) (signed and notarized), drag **Agent Browser** to Applications and open it. It runs as the [menu bar item](#menu-bar); its menu has **Install command-line tool…**, which links `agent-browser` into `~/.local/bin`. The release also has a tarball with just the universal binary.

Or build from source:

```sh
swift build -c release            # binary at .build/release/agent-browser
```

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

The first command starts a background helper that owns the page (`close` stops it; it also exits after 30 idle minutes). `--session NAME` (or `AGENT_BROWSER_SESSION`) runs independent browsers side by side. All sessions run inside that one helper process, and the watch windows of sessions you show open as tabs of a single window (a session's tab leaves the window when you hide it).

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
| `note list` / `show <host>` / `add <host> "text"` / `rm <host> <id>` | short how-to notes per site that agents read before working and add when they work something out, see [Notes](#notes-per-site) |
| `profile list` / `rm <name>` / `prune` | disk used by saved profiles; `rm` deletes one for good, `prune` lists data left by deleted profiles (`--yes` deletes; terminal only) |
| `policy [show]` / `check` (`set`, `reset` are for you) | limits on hosts, private addresses, tabs, downloads and dialogs, see [Policy](#policy-limits-you-set) |
| `status`, `cdp`, `mcp`, `close` | |

`--profile NAME` keeps cookies and storage between runs (default: temporary, discarded on close). The helper also saves **all** of the profile's cookies, session cookies without an expiry included, to `~/.agent-browser/profiles/NAME/cookies.enc` and restores them at startup, because WebKit drops session cookies on exit and, on some macOS versions, doesn't write its store before exiting. That file is encrypted (AES-256-GCM) with a random key kept in your login keychain, and is owner-only; if the key is unavailable the cookies are not saved (never written as plain text), and a file that can't be decrypted is kept as `cookies.enc.unreadable`. WebKit's own data folder for the profile (localStorage and similar) is not encrypted by agent-browser; FileVault covers it. `cookies export` writes the plain JSON you ask for, owner-only. The menu bar item shows each session's profile and when its cookies were last saved. When a persistent session closes, the page cache (tens of MB) is dropped; logins and site data are kept.

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

27 tools (`browser_open`, `browser_snapshot`, `browser_click`, `browser_login`, …) map one to one onto the commands above. Usage guidance is sent in the server's `instructions`.

## Menu bar

`agent-browser menubar` starts a small menu bar item (it detaches, so you can close the terminal; `menubar install` starts it at login, `menubar uninstall` removes that). It lists every running session with its page and state (idle, working on a command, paused, or waiting for your approval) and lets you show or hide its window, take over (pause the agent) and resume, save a screenshot to the Desktop, see the recent steps, or close the session. The icon changes when something needs you, and a notification (from the app bundle; macOS asks permission the first time) appears when a command is waiting for you or a saved login needs approval; clicking it shows that session's window. It never starts a browser, and the browsers keep running if it quits.

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

## Notes per site

Notes are short how-to hints for a site ("search is behind the magnifier icon", "dismiss the cookie banner first"), kept per host in `~/.agent-browser/notes/<host>.json` (owner-only, outside any repository). When a page on a host that has notes is opened, the result carries a `notes` hint; an agent reads them with `browser_notes` (or `agent-browser note show --here`) and adds what it works out with `browser_note_add` (or `note add --here "text"`). Notes for `example.com` also apply to `shop.example.com`. They are shown to agents as data, not instructions.

Text that looks private is refused with `NOTE_SENSITIVE`: email addresses, `password: …` style values, one-time codes, authenticator links, token-like strings and long numbers. Limits: 600 characters per note, 25 notes per host. You can review and remove notes any time with `note list`, `note show <host>` and `note rm <host> <id>`.

## Policy (limits you set)

`agent-browser policy` shows the limits; `policy set ...` changes them. Changing them needs an interactive terminal, so a page or an agent talking to the browser cannot loosen them (it is stored in `~/.agent-browser/policy.json`, owner-only, and running sessions pick up changes). It is not a defence against an agent that can run shell commands as you, and it filters navigations, frames, popups, downloads and dialogs, not every image or script request (use `block url` for those).

```sh
agent-browser policy set --allow-host example.com --allow-host '*.example.org'   # only these hosts (wildcard = subdomains)
agent-browser policy set --deny-host ads.example.net --private block --max-tabs 5
agent-browser policy check http://192.168.0.7/ --from public                      # what would happen? (read-only)
```

- **Hosts:** with an allowlist set, other hosts are refused (`open` fails with `NAVIGATION_BLOCKED`; a link or redirect is cancelled and reported as a `navigation-blocked` event). A deny entry always wins.
- **Private addresses (default `block`):** a page on the public internet cannot send the browser to `localhost`, a private or link-local address (`10.x`, `192.168.x`, `169.254.169.254`, `*.local`), including names that resolve to one. Addresses you type with `open` may be private, and so may links from a page you are already viewing on one. `--private allow` turns this off.
- **Downloads:** `--max-downloads N` (default 20 per session) and `--max-download-mb N` (default 200). A download announced as too big is refused, and one that does not announce its size is cut off when it reaches the cap, with no partial file kept. Saved files get the macOS quarantine flag (`quarantined` in `downloads`), so Gatekeeper checks them before they are opened.
- **Dialogs:** `alert()` is accepted and reported. `confirm()` and `prompt()` follow `--dialogs ask|accept|dismiss`: by default (`ask`) a sheet opens on the watch window (shown for the purpose) and the session counts as needing you; with no answer in 60 s it is cancelled, so an unattended agent never hangs. `accept` / `dismiss` answer automatically. The `dialog` event says who answered (`user`, `policy` or `timeout`).
- **Popups:** `--max-tabs N` (default 8) caps open tabs; extra popups are dropped (`popup-blocked`) and `tab new` fails with `TAB_LIMIT`.

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
- There is no file-chooser UI (use `upload`); `alert()` is accepted automatically and `confirm()`/`prompt()` follow the [policy](#policy-limits-you-set).
- One profile per session; CDP evaluation is blocked on pages whose CSP forbids `eval`.
- Pointer-driven pages that need real hover or drag are only approximated.

## Development

```sh
Tests/integration.sh        # drives the real helper against local fixtures (≈30 s, 311 checks; needs jq, optionally node 22+ and network)
Tests/perf.sh                # CPU and memory of the host and its WebKit helpers in a few scenarios (macOS tools only)
Tests/cdp-compat.sh         # opt-in: installs Puppeteer and Playwright in a temp dir and runs both
```

Set `AGENT_BROWSER_CDP_TRACE=<file>` before starting the helper to log DevTools traffic.

### Release

`Scripts/package.sh` builds a universal binary, signs it (Developer ID, Hardened Runtime), runs the integration tests against the signed binary, wraps it in `Agent Browser.app`, notarizes and staples the app, and writes `dist/AgentBrowser-<version>.dmg` (signed, notarized and stapled, with a Finder-styled window) and `dist/agent-browser-<version>-macos.tar.gz`. Without credentials it warns and skips notarization (an error when `REQUIRE_NOTARIZATION=1`). Locally it uses the Developer ID identity from your keychain (team in a git-ignored `.signing.local`); notarization needs an `AgentBrowser-Notary` keychain profile or `ASC_*` variables. Pushing a tag `vX.Y.Z` matching `VERSION` runs `.github/workflows/release.yml`, which needs the repository secrets `TEAM_ID`, `MACOS_CERTIFICATE`, `MACOS_CERTIFICATE_PWD`, `KEYCHAIN_PASSWORD`, `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_P8` (the base64 of the App Store Connect `.p8` key). Running the workflow by hand is a dry run that publishes nothing. Keep `VERSION` and `Sources/agent-browser/Version.swift` in step.

## License

[MIT](LICENSE)
