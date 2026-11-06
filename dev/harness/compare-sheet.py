#!/usr/bin/env python3
"""校验「随包发的图集」和 JS 原版逐像素一致。

对拍台已经在 Lua 侧验过一遍（dump-lua.mjs + compare.mjs），但那验的是内存里的帧。
这个脚本验的是**真正会进包的那张 PNG**：按描述符切格、去掉 1px 护边，
再和 JS 参考帧（dump-js.mjs 产的 fNNN.rgba）逐像素比。

用法：
    python3 scripts/tap-pixelfx/dev/harness/compare-sheet.py assets/image/fx/impacts/hit-spark.json .tmp/pxref/HitSpark
    python3 scripts/tap-pixelfx/dev/harness/compare-sheet.py --all .tmp/pxref        # 按 Effects 里的路径批量
"""

import json
import os
import sys

from PIL import Image


def compare(json_path, ref_dir, limit=None):
    with open(json_path, "r", encoding="utf-8") as fh:
        desc = json.load(fh)
    png_path = os.path.join(os.path.dirname(json_path), desc["image"])
    sheet = Image.open(png_path).convert("RGBA")
    if sheet.size != (desc["aw"], desc["ah"]):
        return False, f"图集尺寸 {sheet.size} 与描述符 ({desc['aw']},{desc['ah']}) 不符"

    frames = desc["frames"]
    if limit:
        frames = min(frames, limit)
    w, h, pad = desc["w"], desc["h"], desc.get("pad", 0)
    cw, ch, cols = desc["cw"], desc["ch"], desc["cols"]

    for i in range(frames):
        ref_path = os.path.join(ref_dir, "f%03d.rgba" % i)
        if not os.path.exists(ref_path):
            return False, "缺参考帧 %s" % ref_path
        with open(ref_path, "rb") as fh:
            ref = fh.read()
        col, row = i % cols, i // cols
        cell = sheet.crop((col * cw + pad, row * ch + pad, col * cw + pad + w, row * ch + pad + h))
        got = cell.tobytes()
        if len(got) != len(ref):
            return False, "第 %d 帧字节数不符" % i
        if got != ref:
            diff = sum(1 for a, b in zip(got, ref) if a != b)
            return False, "第 %d 帧有 %d 个字节不同" % (i, diff)
    return True, "全部 %d 帧一致" % frames


PAIRS = {
    "impacts/hit-spark": "HitSpark",
    "impacts/crit-hit": "CritHit",
    "melee/sword-slash": "SwordSlash",
    "projectiles/arrow": "Arrow",
    "holy/heal": "Heal",
    "spawn/poof": "Poof",
    "explosions/small-explosion": "SmallExplosion",
    "ui/damage-number": "DamageNumber",
}


def main():
    if len(sys.argv) >= 3 and sys.argv[1] == "--all":
        ref_root = sys.argv[2]
        bad = 0
        for effect_id, module in sorted(PAIRS.items()):
            json_path = os.path.join("scripts/tap-pixelfx/atlas", effect_id + ".json")
            ref_dir = os.path.join(ref_root, module)
            ok, msg = compare(json_path, ref_dir)
            print("%-30s %s  %s" % (effect_id, "MATCH" if ok else "DIFF", msg))
            if not ok:
                bad += 1
        print("RESULT=%s" % ("PASS" if bad == 0 else "FAIL"))
        return 0 if bad == 0 else 1

    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    ok, msg = compare(sys.argv[1], sys.argv[2])
    print(("MATCH: " if ok else "DIFF: ") + msg)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
