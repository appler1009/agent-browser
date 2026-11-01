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
    guard let sub = args.first else { fail("USAGE", "vault takes add <name> --origin URL [--username U] [--totp] [--confirm] [--replace] | list | rm <name> | audit [--limit N] | selftest") }
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
            let rows = try store.list().map { ["name": $0.name, "origins": $0.meta.origins, "totp": $0.meta.totp, "confirm": $0.meta.confirm, "created": $0.meta.created] as [String: Any] }
            vaultOut(["store": store.isTestStore ? "file (test)" : "keychain", "entries": rows])

        case "audit":
            let limit = Int(takeValues("limit").first ?? "") ?? 20
            let text = (try? String(contentsOfFile: store.auditPath, encoding: .utf8)) ?? ""
            let lines = text.split(separator: "\n").suffix(limit).compactMap { parseJSON(String($0)) }
            vaultOut(["entries": lines])

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
