#!/usr/bin/env python3
"""Perf sampler: python3 perf.py <host-pid> <seconds> [label]
Measures the host, the WebKit helper processes started after the host, and optionally other pids (PERF_EXTRA=pid,pid).
CPU% comes from cputime deltas (percent of one core); memory is phys footprint from `footprint`."""
import os, re, subprocess, sys, time, json

def ps_all():
    out = subprocess.run(["ps", "-axo", "pid=,ppid=,lstart=,cputime=,rss=,command="], capture_output=True, text=True).stdout
    rows = {}
    for l in out.splitlines():
        m = re.match(r"\s*(\d+)\s+(\d+)\s+(\w+\s+\d+\s+\w+\s+[\d:]+\s+\d+)\s+([\d:.]+)\s+(\d+)\s+(.*)", l)
        if not m: continue
        pid, ppid, ls, ct, rss, cmd = m.groups()
        t = time.mktime(time.strptime(ls, "%a %d %b %H:%M:%S %Y"))
        parts = ct.split(":")
        sec = float(parts[-1]) + 60 * int(parts[-2]) + (3600 * int(parts[-3]) if len(parts) > 2 else 0)
        rows[int(pid)] = dict(pid=int(pid), ppid=int(ppid), start=t, cpu=sec, rss=int(rss), cmd=cmd)
    return rows

import ctypes
_f = ctypes.CDLL("/usr/lib/libSystem.B.dylib").responsibility_get_pid_responsible_for_pid
_f.argtypes = [ctypes.c_int]; _f.restype = ctypes.c_int

def mine(rows, host):
    """The host plus every process macOS attributes to it (its WebKit helpers)."""
    out = [host]
    for p, r in rows.items():
        if p != host and "com.apple.WebKit." in r["cmd"] and _f(p) == host: out.append(p)
    for p in os.environ.get("PERF_EXTRA", "").split(","):
        if p.strip().isdigit() and int(p) in rows: out.append(int(p))
    return out

def footprint_kb(pids):
    tot = {}
    for p in pids:
        r = subprocess.run(["footprint", "-p", str(p), "--noCategories"], capture_output=True, text=True).stdout
        m = re.search(r"Footprint:\s+([\d.]+)\s+(KB|MB|GB|bytes)", r)
        if m:
            v = float(m.group(1)); u = m.group(2)
            tot[p] = v * {"KB": 1, "MB": 1024, "GB": 1048576, "bytes": 1 / 1024}[u]
    return tot

def kind(cmd):
    for k in ("WebContent", "Networking", "GPU"):
        if k in cmd: return k
    return "host" if "agent-browser" in cmd else "other"

def main():
    host = int(sys.argv[1]); secs = float(sys.argv[2]); label = sys.argv[3] if len(sys.argv) > 3 else ""
    a = ps_all(); pids = mine(a, host)
    time.sleep(secs)
    b = ps_all()
    pids = [p for p in mine(b, host)]
    res = {"label": label, "secs": secs, "procs": {}}
    fp = footprint_kb(pids)
    for p in pids:
        if p in a and p in b:
            cpu = 100 * (b[p]["cpu"] - a[p]["cpu"]) / secs
        elif p in b:
            cpu = 100 * b[p]["cpu"] / secs
        else: continue
        k = kind(b[p]["cmd"])
        e = res["procs"].setdefault(k, {"n": 0, "cpu": 0.0, "mb": 0.0, "rss_mb": 0.0})
        e["n"] += 1; e["cpu"] += cpu; e["mb"] += fp.get(p, 0) / 1024; e["rss_mb"] += b[p]["rss"] / 1024
    res["total_cpu"] = round(sum(v["cpu"] for v in res["procs"].values()), 1)
    res["total_mb"] = round(sum(v["mb"] for v in res["procs"].values()), 1)
    for v in res["procs"].values():
        for k in ("cpu", "mb", "rss_mb"): v[k] = round(v[k], 1)
    print(json.dumps(res))

main()
