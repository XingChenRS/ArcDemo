"""
graft：在 __DATA 段尾 padding 写入 XRCH+8B 槽位，刷新 tramp，classify 入口改 B。
"""
import argparse
import os
import struct
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
MAIN = os.path.join(ROOT, "ios", "Payload", "Arc-mobile.app", "Arc-mobile")

CLASSIFY_OFF = 0x870FD0
TRAMP_OFF = 0x1039500
IMAGE_BASE = 0x100000000
SLOT_MAGIC = b"XRCH"
SLOT_BLOCK = SLOT_MAGIC + b"\x00\x00\x00\x00" + b"\x00\x00\x00\x00\x00\x00\x00\x00"  # 16B

LC_SEGMENT_64 = 0x19


def fat_arm64_slice_offset(raw):
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


def parse_sections(raw):
    base = fat_arm64_slice_offset(raw)
    pos = base + 32
    ncmds = struct.unpack_from("<I", raw, base + 16)[0]
    secs = []
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", raw, pos)
        if cmd == LC_SEGMENT_64:
            name = raw[pos + 8:pos + 24].split(b"\0")[0].decode()
            vmaddr, vmsize, fileoff, filesize = struct.unpack_from("<QQQQ", raw, pos + 24)
            secs.append({
                "name": name, "vmaddr": vmaddr, "size": vmsize,
                "off": fileoff, "fsz": filesize, "pos": pos,
            })
        pos += cmdsize
    return secs


def patch_seg_size(data, sec_pos, new_vmsize, new_fsz):
    struct.pack_into("<Q", data, sec_pos + 32, new_vmsize)
    struct.pack_into("<Q", data, sec_pos + 48, new_fsz)


def encode_b(pc, target):
    return 0x14000000 | (((target - pc) >> 2) & 0x3FFFFFF)


def encode_adrp(rd, pc, target):
    imm = ((target & ~0xFFF) - (pc & ~0xFFF)) >> 12
    imm &= 0x1FFFFF
    if imm >= 0x100000:
        imm -= 0x200000
    hi = (imm >> 2) & 0x7FFFF
    lo = imm & 3
    return 0x90000000 | (lo << 29) | (hi << 5) | (rd & 0x1F)


def encode_add_imm(rd, rn, imm12):
    return 0x91000000 | ((imm12 & 0xFFF) << 10) | ((rn & 0x1F) << 5) | (rd & 0x1F)


def encode_ldr_x64(rd, rn, byte_off):
    return 0xF9400000 | ((byte_off // 8) << 10) | ((rn & 0x1F) << 5) | (rd & 0x1F)


def encode_cbz(rt, pc, target):
    return 0xB4000000 | (((target - pc) >> 2) & 0x7FFFF) << 5 | (rt & 0x1F)


def decode_adrp_target(insn, pc):
    immlo = (insn >> 29) & 3
    immhi = (insn >> 5) & 0x7ffff
    imm = (immhi << 2) | immlo
    if imm & 0x100000:
        imm -= 0x200000
    return (pc & ~0xFFF) + (imm << 12)


def build_tramp(classify_vma, tramp_vma, slot_vma, orig):
    page_off = slot_vma & 0xFFF
    pc = tramp_vma
    insns = [encode_adrp(16, pc, slot_vma)]
    pc += 4
    if page_off:
        insns.append(encode_add_imm(16, 16, page_off))
        pc += 4
    insns.append(encode_ldr_x64(16, 16, 0))
    pc += 4
    cbz_pc = pc
    insns.append(encode_cbz(16, pc, pc + 8))
    pc += 4
    insns.append(0xD61F0200)  # BR x16
    pc += 4
    fb = pc
    insns.extend(orig)
    pc += 16
    insns.append(encode_b(pc, classify_vma + 16))
    idx = 3 if page_off else 2
    insns[idx] = encode_cbz(16, cbz_pc, fb)
    return insns


def vma_to_fileoff(secs, vma):
    for s in secs:
        if s["vmaddr"] <= vma < s["vmaddr"] + max(s["size"], s["fsz"]):
            return s["off"] + (vma - s["vmaddr"])
    return None


def ensure_slot_in_data(data, secs):
    """在 __DATA 文件末尾插入 XRCH+slot（16B），并后移 __LINKEDIT。"""
    data_sec = next((s for s in secs if s["name"] == "__DATA"), None)
    if not data_sec:
        raise RuntimeError("__DATA segment not found")

    old_fsz = data_sec["fsz"]
    old_end = data_sec["off"] + old_fsz

    # 已 graft：文件末尾已是 slot block
    if old_fsz >= len(SLOT_BLOCK):
        chunk = bytes(data[old_end - len(SLOT_BLOCK):old_end])
        if chunk == SLOT_BLOCK:
            slot_vma = data_sec["vmaddr"] + old_fsz - 8
            return slot_vma, 0

    pad = (8 - (old_fsz % 8)) % 8
    insert = bytes(pad) + SLOT_BLOCK
    delta = len(insert)

    data[old_end:old_end] = insert

    new_fsz = old_fsz + delta
    patch_seg_size(data, data_sec["pos"], data_sec["size"], new_fsz)
    data_sec["fsz"] = new_fsz

    link = next((s for s in secs if s["name"] == "__LINKEDIT"), None)
    if link and link["off"] >= old_end:
        link["off"] += delta
        struct.pack_into("<Q", data, link["pos"] + 40, link["off"])

    slot_vma = data_sec["vmaddr"] + old_fsz + pad + len(SLOT_BLOCK) - 8
    return slot_vma, delta


def graft(path, dry_run=False):
    with open(path, "rb") as f:
        data = bytearray(f.read())

    secs = parse_sections(data)
    slot_vma, delta = ensure_slot_in_data(data, secs)
    print(f"[i] slot_vma=0x{slot_vma:x} off=0x{slot_vma - IMAGE_BASE:x} file_expand={delta}")

    classify_vma = IMAGE_BASE + CLASSIFY_OFF
    tramp_vma = IMAGE_BASE + TRAMP_OFF

    if dry_run:
        insns = build_tramp(classify_vma, tramp_vma, slot_vma,
                            [0xA9BC5FF8, 0xA90157F6, 0xA9024FF4, 0xA9037BFD])
        w0 = insns[0]
        decoded = decode_adrp_target(w0, tramp_vma)
        print(f"[dry] tramp insns={len(insns)} adrp->0x{decoded:x} slot=0x{slot_vma:x}")
        return True

    classify_fo = vma_to_fileoff(secs, classify_vma)
    tramp_fo = vma_to_fileoff(secs, tramp_vma)
    if classify_fo is None or tramp_fo is None:
        print("[!] classify/tramp fileoff fail")
        return False

    entry_w = struct.unpack_from("<I", data, classify_fo)[0]
    already = (entry_w >> 26) == 0x05
    orig = (
        [0xA9BC5FF8, 0xA90157F6, 0xA9024FF4, 0xA9037BFD]
        if already
        else [struct.unpack_from("<I", data, classify_fo + i)[0] for i in range(0, 16, 4)]
    )
    insns = build_tramp(classify_vma, tramp_vma, slot_vma, orig)
    if not already:
        struct.pack_into("<I", data, classify_fo, encode_b(classify_vma, tramp_vma))
    for i, w in enumerate(insns):
        struct.pack_into("<I", data, tramp_fo + i * 4, w)

    with open(path, "wb") as f:
        f.write(data)

    # verify
    with open(path, "rb") as f:
        raw = f.read()
    if raw.find(SLOT_MAGIC) < 0:
        print("[!] XRCH not found after write")
        return False
    print(f"[+] graft ok slot=0x{slot_vma:x}")
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--binary", default=MAIN)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    if not os.path.isfile(args.binary):
        sys.exit(f"[!] not found: {args.binary}")
    print(f"[i] graft {args.binary}")
    try:
        ok = graft(args.binary, args.dry_run)
    except Exception as e:
        print(f"[!] {e}")
        ok = False
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
