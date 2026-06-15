"""
注入 libAccDemoArcaea.dylib + libellekit.dylib（与仓库根 inject.py 同步）
"""
import os
import shutil
import struct
import subprocess
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
APP = os.path.join(ROOT, "ios", "Payload", "Arc-mobile.app")
MAIN = os.path.join(APP, "Arc-mobile")
FW_DIR = os.path.join(APP, "Frameworks")
DYLIB_NAMES = ["libAccDemoArcaea.dylib", "libellekit.dylib"]
INJECT_NAME = "@rpath/libAccDemoArcaea.dylib"

LC_LOAD_DYLIB = 0x8000000C
LC_RPATH = 0x8000001C


def fat_arm64_slice_offset(raw: bytes) -> int:
    if raw[:4] != b"\xca\xfe\xba\xbe":
        return 0
    nfat = struct.unpack(">I", raw[4:8])[0]
    off = 8
    for _ in range(nfat):
        cputype, _, so, _, _ = struct.unpack(">IIIII", raw[off:off + 20])
        off += 20
        if cputype in (0x0100000c, 0x00000012):
            return so
    return 0


def slice_range(raw: bytes) -> tuple[int, int]:
    base = fat_arm64_slice_offset(raw)
    if base:
        nfat = struct.unpack(">I", raw[4:8])[0]
        off = 8
        for _ in range(nfat):
            cputype, _, so, sz, _ = struct.unpack(">IIIII", raw[off:off + 20])
            off += 20
            if cputype in (0x0100000c, 0x00000012):
                return so, so + sz
    return 0, len(raw)


def parse_load_commands(raw: bytes, base: int):
    ncmds, sizeofcmds = struct.unpack_from("<II", raw, base + 16)
    pos = base + 32
    cmds = []
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", raw, pos)
        cmds.append((cmd, cmdsize, pos))
        pos += cmdsize
    return ncmds, sizeofcmds, cmds


def has_load_dylib(raw: bytes, base: int, name: str) -> bool:
    _, _, cmds = parse_load_commands(raw, base)
    for cmd, cmdsize, pos in cmds:
        if (cmd & 0xFFFFFF) != 0x0C:
            continue
        path_off = struct.unpack_from("<I", raw, pos + 8)[0]
        path = raw[pos + path_off:pos + cmdsize].split(b"\0")[0].decode()
        if path == name:
            return True
    return False


def has_rpath(raw: bytes, base: int, path: str) -> bool:
    _, _, cmds = parse_load_commands(raw, base)
    for cmd, cmdsize, pos in cmds:
        if (cmd & 0xFFFFFF) != 0x1C:
            continue
        path_off = struct.unpack_from("<I", raw, pos + 8)[0]
        rp = raw[pos + path_off:pos + cmdsize].split(b"\0")[0].decode()
        if rp == path:
            return True
    return False


def build_load_dylib_cmd(path: str) -> bytes:
    path_b = path.encode("ascii") + b"\0"
    cmdsize = (24 + len(path_b) + 7) & ~7
    cmd = bytearray(cmdsize)
    struct.pack_into("<II", cmd, 0, LC_LOAD_DYLIB, cmdsize)
    struct.pack_into("<IIII", cmd, 8, 24, 2, 0x10000, 0x10000)
    cmd[24:24 + len(path_b)] = path_b
    return bytes(cmd)


def build_rpath_cmd(path: str) -> bytes:
    path_b = path.encode("ascii") + b"\0"
    cmdsize = (12 + len(path_b) + 7) & ~7
    cmd = bytearray(cmdsize)
    struct.pack_into("<II", cmd, 0, LC_RPATH, cmdsize)
    struct.pack_into("<I", cmd, 8, 12)
    cmd[12:12 + len(path_b)] = path_b
    return bytes(cmd)


def padding_after_lc(raw: bytes, base: int, sizeofcmds: int) -> int:
    end = base + 32 + sizeofcmds
    i = end
    sl_end = slice_range(raw)[1]
    limit = min(sl_end, len(raw))
    while i < limit and raw[i] == 0:
        i += 1
    return i - end


def insert_load_commands_inplace(data: bytearray, base: int) -> list[str]:
    logs = []
    ncmds, sizeofcmds, _ = parse_load_commands(data, base)

    to_add = []
    if not has_load_dylib(data, base, INJECT_NAME):
        to_add.append(build_load_dylib_cmd(INJECT_NAME))
    if not has_rpath(data, base, "@executable_path/Frameworks"):
        to_add.append(build_rpath_cmd("@executable_path/Frameworks"))

    if not to_add:
        logs.append("already has LC_LOAD_DYLIB + LC_RPATH")
        return logs

    need = sum(len(c) for c in to_add)
    pad = padding_after_lc(data, base, sizeofcmds)
    if need > pad:
        raise RuntimeError(
            f"load command padding too small: need {need} bytes, have {pad}"
        )

    insert_at = base + 32 + sizeofcmds
    for cmd in to_add:
        data[insert_at:insert_at + len(cmd)] = cmd
        insert_at += len(cmd)
        sizeofcmds += len(cmd)
        ncmds += 1

    struct.pack_into("<II", data, base + 16, ncmds, sizeofcmds)
    logs.append(f"inserted {len(to_add)} load command(s) (+{need} bytes in padding)")
    return logs


def find_dylibs() -> list[str]:
    candidates = [
        os.path.join(ROOT, "ci-artifacts", "libAccDemoArcaea-trollstore"),
        ROOT,
    ]
    found = []
    for name in DYLIB_NAMES:
        path = None
        for d in candidates:
            p = os.path.join(d, name)
            if os.path.isfile(p):
                path = p
                break
        if not path:
            raise FileNotFoundError(f"dylib missing: {name} (ROOT or ci-artifacts/)")
        found.append(path)
    return found


def main():
    if not os.path.isfile(MAIN):
        print(f"[!] main not found: {MAIN}")
        sys.exit(1)

    try:
        dylibs = find_dylibs()
    except FileNotFoundError as e:
        print(f"[!] {e}")
        sys.exit(1)

    os.makedirs(FW_DIR, exist_ok=True)
    for d in dylibs:
        dst = os.path.join(FW_DIR, os.path.basename(d))
        shutil.copy2(d, dst)
        print(f"[+] copied -> {dst}")

    graft_script = os.path.join(ROOT, "graft_hook.py")
    if os.path.isfile(graft_script):
        r = subprocess.run(
            [sys.executable, graft_script, "--binary", MAIN],
            capture_output=True,
            text=True,
        )
        if r.returncode == 0:
            print(r.stdout.strip())
        else:
            print("[!] graft_hook failed:", r.stderr or r.stdout)
            sys.exit(1)

    with open(MAIN, "rb") as f:
        data = bytearray(f.read())

    base = fat_arm64_slice_offset(data)
    try:
        logs = insert_load_commands_inplace(data, base)
        for line in logs:
            print(f"[+] {line}")
    except RuntimeError as e:
        print(f"[!] {e}")
        sys.exit(1)

    with open(MAIN, "wb") as f:
        f.write(data)

    size = os.path.getsize(MAIN)
    with open(MAIN, "rb") as f:
        raw = f.read()
    xrch = raw.find(b"XRCH")
    _, sl_end = slice_range(raw)
    print(f"[+] wrote {MAIN}")
    print(f"[i] size={size} (slice_end={sl_end}) XRCH@{xrch}")
    if size < sl_end - 1000:
        print("[!] WARNING: file smaller than slice — possible corruption")
        sys.exit(1)


if __name__ == "__main__":
    main()
