#!/usr/bin/env python3
"""
KCD2 groschen (money) live editor for Linux/Proton - single player.

Edits the running KingdomCome.exe process memory directly. This works only
where the client owns the value: single player. On a KCD:MP server the purse is
the server's own record (the default money guard), so a memory edit there reads
as the money the server says you have and is put back - use the server-side
GivePlayerMoney in gamemodes/purse.lua instead.

Workflow (safe, Cheat-Engine style):
  1. scan   - find all memory cells holding your current groschen amount
  2. refine - change money once in-game (buy/sell something), the tool keeps
              only cells that followed the change
  3. patch  - write the new amount into the confirmed cells
  4. watch  - optionally keep re-applying the amount (in case the game
              overwrites it)

Usage:
  kcd2_groschen.py ps
  kcd2_groschen.py set --value 8149515          # all-in-one interactive
  kcd2_groschen.py scan --value 164 --out cand.txt
  kcd2_groschen.py refine --value 150 --candidates cand.txt --out cand2.txt
  kcd2_groschen.py patch --value 8149515 --candidates cand2.txt
  kcd2_groschen.py watch --value 8149515 --candidates cand2.txt

No dependencies - stdlib only. Requires ptrace_scope=0 (already true here)
and same user as the game (already true).
"""

import argparse
import os
import struct
import sys
import time

DTYPES = {
    "int32": ("<i", 4),
    "int64": ("<q", 8),
    "float32": ("<f", 4),
}

CHUNK = 4 << 20  # 4 MiB read chunks


def die(msg):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def info(msg):
    print(msg, flush=True)


# ---------------------------------------------------------------- process ---

def find_game_pids():
    hits = []
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            cmd = open(f"/proc/{pid}/cmdline", "rb").read()
        except OSError:
            continue
        if b"KingdomCome.exe" in cmd:
            hits.append((int(pid), cmd.replace(b"\x00", b" ").decode("utf-8", "replace")))
    return hits


def require_pid(explicit=None):
    if explicit:
        if not os.path.exists(f"/proc/{explicit}/mem"):
            die(f"no such process: {explicit}")
        return explicit
    hits = find_game_pids()
    if not hits:
        die("KingdomCome.exe is not running. Start single player first "
            "(./kcd2-launch.sh sp), then run this tool again.")
    if len(hits) > 1:
        info("note: multiple KingCome.exe processes found, using the first")
    return hits[0][0]


# ----------------------------------------------------------------- memory ---

def open_mem(pid, write=False):
    return os.open(f"/proc/{pid}/mem", os.O_RDWR if write else os.O_RDONLY)


def anon_writable_regions(pid):
    """Writable regions that are not file-backed (heaps, not dll/exe code)."""
    out = []
    with open(f"/proc/{pid}/maps") as f:
        for line in f:
            parts = line.split()
            perm = parts[1]
            if "w" not in perm:
                continue
            start_s, end_s = parts[0].split("-")
            start, end = int(start_s, 16), int(end_s, 16)
            if end - start < 64:
                continue
            path = parts[5] if len(parts) >= 6 else ""
            if path.startswith("/"):
                continue  # skip file-backed (game exe, dlls) - money lives on the heap
            out.append((start, end))
    return out


def read_chunk(fd, addr, size):
    """pread with per-page fallback for mappings that contain holes."""
    try:
        buf = os.pread(fd, size, addr)
        if len(buf) == size:
            return buf
    except OSError:
        pass
    # fallback: page by page, skipping unreadable pages
    buf = bytearray()
    page = 4096
    p = addr
    end = addr + size
    while p < end:
        n = min(page, end - p)
        try:
            buf += os.pread(fd, n, p)
        except OSError:
            buf += b"\x00" * n
        p += n
    return bytes(buf)


def scan_memory(pid, value, dtype, progress=True):
    """Return addresses whose int/float value equals `value`."""
    fmt, size = DTYPES[dtype]
    pat = struct.pack(fmt, value)
    fd = open_mem(pid)
    regions = anon_writable_regions(pid)
    total = sum(e - s for s, e in regions)
    done = 0
    next_report = 1 << 30
    hits = []
    try:
        for s, e in regions:
            off = s
            while off < e:
                n = min(CHUNK, e - off)
                buf = read_chunk(fd, off, n)
                start = 0
                while True:
                    i = buf.find(pat, start)
                    if i < 0:
                        break
                    hits.append(off + i)
                    start = i + 1
                off += n
                done += n
                if progress and done >= next_report:
                    info(f"  scanned {done >> 20} / {total >> 20} MiB, {len(hits)} hits so far")
                    next_report += 1 << 30
    finally:
        os.close(fd)
    return hits


def read_val(fd, addr, dtype):
    fmt, size = DTYPES[dtype]
    b = os.pread(fd, size, addr)
    if len(b) < size:
        return None
    return struct.unpack(fmt, b)[0]


def read_many(fd, addrs, dtype):
    """Bulk-read values for many addresses using 1 MiB windows."""
    fmt, size = DTYPES[dtype]
    out = {}
    addrs = sorted(addrs)
    win = 1 << 20
    i, n = 0, len(addrs)
    while i < n:
        base = addrs[i]
        j = i
        while j < n and addrs[j] < base + win:
            j += 1
        group = addrs[i:j]
        length = group[-1] - base + size
        buf = read_chunk(fd, base, length)
        for a in group:
            o = a - base
            if o + size <= len(buf):
                out[a] = struct.unpack(fmt, buf[o:o + size])[0]
        i = j
    return out


# ----------------------------------------------------------- candidates io --

def save_candidates(path, addrs, dtype, value):
    with open(path, "w") as f:
        f.write(f"# kcd2-groschen candidates dtype={dtype} value={value}\n")
        for a in addrs:
            f.write(f"0x{a:x}\n")


def load_candidates(path):
    dtype, addrs = None, []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line.startswith("#"):
                for tok in line.split():
                    if tok.startswith("dtype="):
                        dtype = tok.split("=", 1)[1]
                continue
            if line:
                addrs.append(int(line, 0))
    if dtype not in DTYPES:
        die(f"bad or missing dtype in {path}")
    return addrs, dtype


# ---------------------------------------------------------------- commands --

def cmd_ps(_args):
    hits = find_game_pids()
    if not hits:
        info("KingdomCome.exe is NOT running.")
        info("Start single player first:  ./kcd2-launch.sh sp")
        sys.exit(1)
    for pid, cmd in hits:
        info(f"pid {pid}: {cmd[:150]}")


def do_scan(pid, value, dtype, out):
    info(f"scanning pid {pid} for value {value} as {dtype} ...")
    t0 = time.time()
    hits = scan_memory(pid, value, dtype)
    dt = time.time() - t0
    info(f"done in {dt:.1f}s: {len(hits)} candidate addresses")
    if hits:
        save_candidates(out, hits, dtype, value)
        info(f"saved to {out}")
    return hits


def do_refine(cand_path, value, out, dtype_override=None, pid=None, watch=0.0):
    addrs, dtype = load_candidates(cand_path)
    if dtype_override:
        dtype = dtype_override
    pid = require_pid(pid)
    fd = open_mem(pid)
    kept = []
    try:
        if watch > 0:
            # poll: keep cells that hit the target value at ANY point in the window
            deadline = time.time() + watch
            found = set()
            remaining = list(addrs)
            while time.time() < deadline and remaining:
                vals = read_many(fd, remaining, dtype)
                still = []
                for a in remaining:
                    if vals.get(a) == value:
                        found.add(a)
                    else:
                        still.append(a)
                remaining = still
                info(f"  poll: {len(found)} matched, {len(remaining)} left, "
                     f"{max(0, deadline - time.time()):.0f}s to go")
                if remaining:
                    time.sleep(1.0)
            kept = sorted(found)
        else:
            vals = read_many(fd, addrs, dtype)
            for a in addrs:
                if vals.get(a) == value:
                    kept.append(a)
    finally:
        os.close(fd)
    info(f"{len(addrs)} candidates -> {len(kept)} still equal {value}")
    if kept:
        save_candidates(out, kept, dtype, value)
        info(f"saved to {out}")
    return kept


def do_patch(cand_path, value, force=False, pid=None):
    addrs, dtype = load_candidates(cand_path)
    if not addrs:
        die("no candidates to patch")
    if len(addrs) > 500 and not force:
        die(f"{len(addrs)} candidates is a lot - refine more, or pass --force")
    pid = require_pid(pid)
    fmt, size = DTYPES[dtype]
    payload = struct.pack(fmt, value)
    fd = open_mem(pid, write=True)
    ok = 0
    try:
        for a in addrs:
            try:
                os.pwrite(fd, payload, a)
                ok += 1
            except OSError as e:
                info(f"  write failed at 0x{a:x}: {e}")
    finally:
        os.close(fd)
    # verify
    fd = open_mem(pid)
    good = 0
    try:
        for a in addrs:
            v = read_val(fd, a, dtype)
            if v == value:
                good += 1
    finally:
        os.close(fd)
    info(f"patched {ok}/{len(addrs)} addresses, verified {good} read back as {value}")
    if good == 0:
        die("nothing stuck - the value type may be wrong, redo scan with --dtype float32")


def do_watch(cand_path, value, interval, pid=None):
    addrs, dtype = load_candidates(cand_path)
    pid = require_pid(pid)
    fmt, size = DTYPES[dtype]
    payload = struct.pack(fmt, value)
    info(f"watching {len(addrs)} address(es) every {interval}s - press Ctrl+C to stop")
    drifts = 0
    fd_ro = open_mem(pid)
    fd_rw = open_mem(pid, write=True)
    last_report = time.time()
    try:
        while True:
            for a in addrs:
                v = read_val(fd_ro, a, dtype)
                if v != value:
                    try:
                        os.pwrite(fd_rw, payload, a)
                        drifts += 1
                        info(f"  [{time.strftime('%H:%M:%S')}] value at 0x{a:x} was {v}, reset to {value}")
                    except OSError as e:
                        info(f"  write failed at 0x{a:x}: {e} (game probably exited)")
                        return
            if time.time() - last_report >= 60:
                info(f"  [{time.strftime('%H:%M:%S')}] still watching, {drifts} drift(s) so far")
                last_report = time.time()
            time.sleep(interval)
    except KeyboardInterrupt:
        info(f"\nstopped watching ({drifts} drift(s) total)")
    finally:
        os.close(fd_ro)
        os.close(fd_rw)


def cmd_set(args):
    """Interactive all-in-one flow."""
    pid = require_pid(args.pid)
    cur = args.current
    if cur is None:
        cur = int(input("How many groschen do you have RIGHT NOW (as shown in game)? ").strip())
    target = args.value

    # initial scan across dtypes
    hits, dtype = [], None
    for dt in ("int32", "float32", "int64"):
        info(f"scanning pid {pid} for {cur} as {dt} ...")
        hits = scan_memory(pid, cur, dt)
        info(f"  -> {len(hits)} hits")
        if hits:
            dtype = dt
            break
    if not hits:
        die(f"could not find {cur} anywhere in memory - is the amount exactly as shown in game?")
    cand = "/tmp/kcd2_groschen_cand.txt"
    save_candidates(cand, hits, dtype, cur)

    # interactive refine rounds
    for rnd in range(1, 5):
        input(f"\nRound {rnd}: in the game, change your groschen amount ONCE "
              f"(buy/sell/drop anything, even 1 groschen).\n"
              f"Then press Enter here (game stays running)... ")
        new = int(input("Now type the groschen amount shown in game: ").strip())
        if new == cur:
            info("amount did not change - try again")
            continue
        kept = do_refine(cand, new, cand, pid=pid, watch=90.0)
        cur = new
        if not kept:
            die("all candidates lost - money may have been stored differently, "
                "run 'scan' again with the new amount")
        if len(kept) <= 25 or rnd == 4:
            break

    info(f"\nconfirmed {len(kept)} money cell(s), patching to {target} ...")
    save_candidates(cand, kept, dtype, cur)
    do_patch(cand, target, pid=pid)
    info("done. Your groschen should now show the new amount (inventory may need reopening).")
    if input("Keep it locked so the game can't overwrite it? (y/N): ").strip().lower() == "y":
        do_watch(cand, target, args.interval, pid=pid)


def main():
    ap = argparse.ArgumentParser(description="KCD2 groschen live memory editor (single player)")
    ap.add_argument("--pid", type=int, default=None, help="game pid (default: auto-detect)")
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("ps", help="find the running game process")

    p = sub.add_parser("scan", help="scan memory for your current groschen value")
    p.add_argument("--value", type=int, required=True)
    p.add_argument("--dtype", choices=list(DTYPES), default="int32")
    p.add_argument("--out", default="/tmp/kcd2_groschen_cand.txt")

    p = sub.add_parser("refine", help="keep only candidates that now equal the new value")
    p.add_argument("--value", type=int, required=True)
    p.add_argument("--candidates", default="/tmp/kcd2_groschen_cand.txt")
    p.add_argument("--out", default="/tmp/kcd2_groschen_cand.txt")
    p.add_argument("--dtype", choices=list(DTYPES), default=None)
    p.add_argument("--watch", type=float, default=0.0,
                   help="poll for this many seconds, keeping cells that hit the value at any point")

    p = sub.add_parser("patch", help="write the target value into candidate addresses")
    p.add_argument("--value", type=int, required=True)
    p.add_argument("--candidates", default="/tmp/kcd2_groschen_cand.txt")
    p.add_argument("--force", action="store_true")

    p = sub.add_parser("watch", help="keep re-applying the value (lock mode)")
    p.add_argument("--value", type=int, required=True)
    p.add_argument("--candidates", default="/tmp/kcd2_groschen_cand.txt")
    p.add_argument("--interval", type=float, default=2.0)

    p = sub.add_parser("set", help="interactive: set groschen to a new amount")
    p.add_argument("--value", type=int, required=True, help="target amount")
    p.add_argument("--current", type=int, default=None, help="current amount (skip prompt)")
    p.add_argument("--interval", type=float, default=2.0, help="lock interval for watch mode")

    args = ap.parse_args()
    if args.cmd == "ps":
        cmd_ps(args)
    elif args.cmd == "scan":
        do_scan(require_pid(args.pid), args.value, args.dtype, args.out)
    elif args.cmd == "refine":
        do_refine(args.candidates, args.value, args.out, args.dtype,
                  pid=args.pid, watch=args.watch)
    elif args.cmd == "patch":
        do_patch(args.candidates, args.value, args.force, pid=args.pid)
    elif args.cmd == "watch":
        do_watch(args.candidates, args.value, args.interval, pid=args.pid)
    elif args.cmd == "set":
        cmd_set(args)


if __name__ == "__main__":
    main()
