import CoreImage
import Foundation

// `agent-browser vault ...`: managing entries. Runs in the CLI process (no helper needed).
// Adding and removing need an interactive terminal, so an agent driving a non-interactive shell cannot
// create, replace or delete credentials; there is no command that prints a stored value.

private func vaultOut(_ result: [String: Any]) -> Never {
    print(jsonString(["ok": true, "result": result, "events": []]))
    exit(0)
}

private func prompt(_ text: String, secret: Bool) -> String? {
    let tty = isatty(STDIN_FILENO) != 0
    if tty { FileHandle.standardError.write(Data(text.utf8)) }
    var old = termios()
    if secret && tty {
        tcgetattr(STDIN_FILENO, &old)
        var raw = old
        raw.c_lflag &= ~tcflag_t(ECHO)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
    }
    defer {
        if secret && tty { tcsetattr(STDIN_FILENO, TCSAFLUSH, &old); FileHandle.standardError.write(Data("\n".utf8)) }
    }
    return readLine(strippingNewline: true)
}

func runVaultCLI(_ args: [String]) -> Never {
    let store = makeVaultStore()
    guard let sub = args.first else { fail("USAGE", "vault takes add <name> --origin URL [--username U] [--totp] [--confirm] [--replace] | origin <name> [--add URL] [--remove URL] | list | rm <name> | audit [--limit N] | selftest") }
    var rest = Array(args.dropFirst())

    func takeFlag(_ name: String) -> Bool {
        guard let i = rest.firstIndex(of: "--\(name)") else { return false }
        rest.remove(at: i)
        return true
    }
    func takeValues(_ name: String) -> [String] {
        var out: [String] = []
        while let i = rest.firstIndex(of: "--\(name)") {
            guard i + 1 < rest.count else { fail("USAGE", "--\(name) needs a value") }
            out.append(rest[i + 1])
            rest.removeSubrange(i...(i + 1))
        }
        return out
    }
    func needInteractive(_ what: String) {
        if isatty(STDIN_FILENO) == 0 && !store.isTestStore {
            fail("VAULT_NEEDS_TTY", "\(what) needs an interactive terminal (run it yourself in a terminal, not through an agent), so that credentials cannot be created or removed by a program.")
        }
    }

    do {
        switch sub {
        case "selftest":
            let bad = totpSelfTest()
            if bad.isEmpty { vaultOut(["selftest": "ok"]) }
            fail("SELFTEST_FAILED", bad.joined(separator: "; "))

        case "list":
            let rows = try store.list().map { ["name": $0.name, "origins": $0.meta.origins, "totp": $0.meta.totp, "confirm": $0.meta.confirm, "recovery": $0.meta.recovery ?? 0, "created": $0.meta.created] as [String: Any] }
            vaultOut(["store": store.isTestStore ? "file (test)" : "keychain", "entries": rows])

        case "audit":
            let limit = Int(takeValues("limit").first ?? "") ?? 20
            let text = (try? String(contentsOfFile: store.auditPath, encoding: .utf8)) ?? ""
            let lines = text.split(separator: "\n").suffix(limit).compactMap { parseJSON(String($0)) }
            vaultOut(["entries": lines])

        case "export":
            needInteractive("vault export")
            let qr = takeFlag("qr")
            let asJSON = takeFlag("json")
            guard let name = rest.first, validVaultName(name) else { fail("USAGE", "vault export <name> [--qr] [--json]") }
            guard let entry = try store.get(name) else { fail("VAULT_NO_ENTRY", "no vault entry \"\(name)\"") }
            guard entry.secret.totp != nil || !(entry.secret.recovery ?? []).isEmpty else {
                fail("VAULT_NO_FIELD", "entry \"\(name)\" has no TOTP secret or recovery codes to export")
            }
            let a = requestApprovalSync(reason: "agent-browser wants to show the 2FA backup for \"\(name)\"", store: store)
            guard a.ok else {
                vaultAudit(store, ["entry": name, "action": "export", "outcome": "APPROVAL_DENIED", "why": a.why])
                fail("VAULT_APPROVAL_DENIED", "export was not approved (\(a.why)).")
            }
            vaultAudit(store, ["entry": name, "action": "export", "outcome": "ok"])
            var out: [String: Any] = ["name": name, "origins": entry.meta.origins, "username": entry.secret.username]
            var uri = ""
            if let t = entry.secret.totp {
                let p = try parseTOTP(t)
                let issuer = URL(string: entry.meta.origins.first ?? "")?.host ?? name
                uri = otpauthURI(stored: t, issuer: issuer, account: entry.secret.username)
                let left = p.period - Int(Date().timeIntervalSince1970) % p.period
                out["totp"] = ["secret": base32Encode(p.secret), "uri": uri, "digits": p.digits, "period": p.period,
                               "algorithm": p.algorithm, "current_code": totpCode(p), "valid_for_seconds": left] as [String: Any]
            }
            if let r = entry.secret.recovery, !r.isEmpty { out["recovery_codes"] = r }
            if asJSON { vaultOut(out) }
            var text = "\(name)  (\(entry.meta.origins.joined(separator: ", ")))\nusername: \(entry.secret.username)\n"
            if let t = out["totp"] as? [String: Any] {
                text += "\nTOTP secret: \(t["secret"] as! String)\notpauth link: \(t["uri"] as! String)\ncurrent code: \(t["current_code"] as! String) (valid for \(t["valid_for_seconds"] as! Int) s)\n"
            }
            if let r = out["recovery_codes"] as? [String] { text += "\nrecovery codes (\(r.count)):\n" + r.map { "  \($0)" }.joined(separator: "\n") + "\n" }
            text += "\nKeep this somewhere safe (a password manager, or printed and stored offline). The vault itself is only in this Mac's login keychain.\n"
            print(text)
            if qr && !uri.isEmpty { printQR(uri) }
            exit(0)

        case "recovery":
            needInteractive("vault recovery")
            guard let name = rest.first, validVaultName(name), var entry = try store.get(name) else { fail("USAGE", "vault recovery <name>  (entry must exist)") }
            FileHandle.standardError.write(Data("Paste the recovery codes for \(name), one per line, then an empty line:\n".utf8))
            var codes: [String] = []
            while let l = readLine(strippingNewline: true), !l.trimmingCharacters(in: .whitespaces).isEmpty { codes.append(l.trimmingCharacters(in: .whitespaces)) }
            guard !codes.isEmpty else { fail("USAGE", "no codes entered") }
            entry.secret.recovery = codes
            entry.meta.recovery = codes.count
            try store.put(entry, replace: true)
            vaultAudit(store, ["entry": name, "action": "recovery", "count": codes.count, "outcome": "ok"])
            vaultOut(["entry": name, "saved": codes.count])

        case "origin":
            needInteractive("vault origin")
            let adds = takeValues("add"), removes = takeValues("remove")
            guard let name = rest.first, validVaultName(name), rest.count == 1, !(adds.isEmpty && removes.isEmpty) else {
                fail("USAGE", "vault origin <name> [--add https://site]... [--remove https://site]...")
            }
            guard var entry = try store.get(name) else { fail("VAULT_NO_ENTRY", "no vault entry \"\(name)\"") }
            let addN = try adds.map { try normalizeVaultOrigin($0, allowFile: store.isTestStore) }
            let remN = try removes.map { try normalizeVaultOrigin($0, allowFile: store.isTestStore) }
            let before = entry.meta.origins
            var now = Set(before)
            for r in remN {
                guard now.contains(r) else { fail("VAULT_NO_ORIGIN", "entry \"\(name)\" is not set for \(r)") }
                now.remove(r)
            }
            now.formUnion(addN)
            guard !now.isEmpty else { fail("USAGE", "an entry needs at least one site; use vault rm to delete it") }
            let after = now.sorted()
            if after == before.sorted() { vaultOut(["entry": name, "origins": after, "changed": false]) }
            if entry.meta.confirm {
                let a = requestApprovalSync(reason: "agent-browser wants to change the sites allowed for \"\(name)\"", store: store)
                guard a.ok else {
                    vaultAudit(store, ["entry": name, "action": "origin", "outcome": "APPROVAL_DENIED", "why": a.why])
                    fail("VAULT_APPROVAL_DENIED", "the change was not approved (\(a.why)).")
                }
            }
            entry.meta.origins = after
            try store.put(entry, replace: true)
            vaultAudit(store, ["entry": name, "action": "origin", "from": before, "origins": after, "outcome": "ok"])
            vaultOut(["entry": name, "origins": after, "changed": true])

        case "rm":
            needInteractive("vault rm")
            guard let name = rest.first, validVaultName(name) else { fail("USAGE", "vault rm <name>") }
            guard try store.remove(name) else { fail("VAULT_NO_ENTRY", "no vault entry \"\(name)\"") }
            vaultAudit(store, ["entry": name, "action": "remove", "outcome": "ok"])
            vaultOut(["removed": name])

        case "add":
            needInteractive("vault add")
            let origins = takeValues("origin")
            let usernameFlag = takeValues("username").first
            let wantTOTP = takeFlag("totp")
            let confirm = takeFlag("confirm")
            let replace = takeFlag("replace")
            guard let name = rest.first, validVaultName(name), rest.count == 1 else {
                fail("USAGE", "vault add <name> --origin https://site [--origin ...] [--username U] [--totp] [--confirm] [--replace]  (name: letters, digits, - _ .)")
            }
            guard !origins.isEmpty else { fail("USAGE", "vault add needs at least one --origin, the only site(s) where this login may be used") }
            let norm = try Array(Set(origins.map { try normalizeVaultOrigin($0, allowFile: store.isTestStore) })).sorted()
            if let existing = try store.get(name), !replace {
                _ = existing
                fail("VAULT_EXISTS", "entry \"\(name)\" already exists; pass --replace to overwrite it (the password must be entered again).")
            }
            let username = usernameFlag ?? prompt("Username for \(name): ", secret: false) ?? ""
            guard !username.isEmpty else { fail("USAGE", "username is required") }
            guard let password = prompt("Password for \(name) (hidden): ", secret: true), !password.isEmpty else { fail("USAGE", "password is required") }
            if password.count < 4 { FileHandle.standardError.write(Data("warning: passwords shorter than 4 characters cannot be redacted from output\n".utf8)) }
            var totp: String?
            if wantTOTP {
                guard let t = prompt("TOTP secret or otpauth:// URI (hidden): ", secret: true), !t.isEmpty else { fail("USAGE", "a TOTP secret is required with --totp") }
                _ = try parseTOTP(t)  // validates
                totp = t.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let meta = VaultMeta(origins: norm, confirm: confirm, totp: totp != nil, created: ISO8601DateFormatter().string(from: Date()))
            try store.put(VaultEntry(name: name, meta: meta, secret: VaultSecret(username: username, password: password, totp: totp)), replace: replace)
            vaultAudit(store, ["entry": name, "action": replace ? "replace" : "add", "origins": norm, "outcome": "ok"])
            vaultOut(["added": name, "origins": norm, "totp": totp != nil, "confirm": confirm])

        default:
            fail("USAGE", "unknown vault command \"\(sub)\"")
        }
    } catch let e as CmdError {
        fail(e.code, e.message)
    } catch {
        fail("VAULT_ERROR", "\(error)")
    }
}

/// Prints a QR code with explicit black/white cells so it scans on both light and dark terminals.
func printQR(_ text: String) {
    guard let f = CIFilter(name: "CIQRCodeGenerator") else { return }
    f.setValue(Data(text.utf8), forKey: "inputMessage")
    f.setValue("M", forKey: "inputCorrectionLevel")
    guard let img = f.outputImage, let cg = CIContext().createCGImage(img, from: img.extent) else { return }
    let w = cg.width, h = cg.height
    var px = [UInt8](repeating: 255, count: w * h)
    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                        bitmapInfo: CGImageAlphaInfo.none.rawValue)
    ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    let white = "\u{1B}[107m  \u{1B}[0m", black = "\u{1B}[40m  \u{1B}[0m"
    let quiet = String(repeating: white, count: w + 4)
    var out = [quiet, quiet]
    for y in 0..<h { out.append(white + white + (0..<w).map { px[y * w + $0] < 128 ? black : white }.joined() + white + white) }
    out += [quiet, quiet]
    print(out.joined(separator: "\n"))
}
