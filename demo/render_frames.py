#!/usr/bin/env python3
"""demo/render_frames.py - turn the frames of demo/record_loop.sh into an animated GIF.

usage: python3 demo/render_frames.py FRAME_DIR OUT.gif [FONT.ttf]
Each frame is a pair FRAME_DIR/frame_NN.left.txt (host shell) and frame_NN.right.txt (guest serial
console), the text that tmux capture-pane saved. The text is drawn unchanged in a monospace font,
the two panes side by side with a title line each. Needs Pillow.
Copyright 2026 The fs-9p authors. Licensed under the Apache License, Version 2.0.
"""
import glob
import os
import re
import sys

from PIL import Image, ImageDraw, ImageFont

ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
BG, FG, TITLE_BG, TITLE_FG, RULE = (24, 26, 33), (220, 223, 228), (52, 56, 68), (255, 255, 255), (90, 96, 110)


def lines(path, rows, cols):
    text = ANSI.sub("", open(path, encoding="utf-8", errors="replace").read())
    out = []
    for l in text.split("\n"):
        l = l.rstrip()
        out.extend([l[i:i + cols] for i in range(0, len(l), cols)] or [""])   # wrap, as a terminal does
    while out and not out[-1]:
        out.pop()
    return out[-rows:]


def main():
    fdir, out = sys.argv[1], sys.argv[2]
    font_path = sys.argv[3] if len(sys.argv) > 3 else "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"
    font = ImageFont.truetype(font_path, 14)
    bold = ImageFont.truetype(font_path.replace("DejaVuSansMono.ttf", "DejaVuSansMono-Bold.ttf"), 14) \
        if os.path.exists(font_path.replace("DejaVuSansMono.ttf", "DejaVuSansMono-Bold.ttf")) else font
    cw = int(font.getlength("M")) + 1
    lh = 18
    cols_l, cols_r, rows = 84, 76, 16
    pad, title_h = 10, 26
    w = pad * 4 + cw * (cols_l + cols_r) + 2
    h = title_h + pad * 2 + lh * rows
    titles = ("host (Linux): edit and build with qcc in ~/qnx-share/demo",
              "QNX 8.0 guest (QEMU serial console): /mnt/host/demo")
    frames = []
    for left in sorted(glob.glob(os.path.join(fdir, "frame_*.left.txt"))):
        right = left.replace(".left.txt", ".right.txt")
        img = Image.new("RGB", (w, h), BG)
        d = ImageDraw.Draw(img)
        x0, x1 = pad, pad * 3 + cw * cols_l + 2
        d.rectangle([0, 0, w, title_h], fill=TITLE_BG)
        d.text((x0, 5), titles[0], font=bold, fill=TITLE_FG)
        d.text((x1, 5), titles[1], font=bold, fill=TITLE_FG)
        d.line([x1 - pad, 0, x1 - pad, h], fill=RULE, width=2)
        for x, path, cols in ((x0, left, cols_l), (x1, right, cols_r)):
            for i, line in enumerate(lines(path, rows, cols)):
                d.text((x, title_h + pad + i * lh), line[:cols], font=font, fill=FG)
        frames.append(img.convert("P", palette=Image.ADAPTIVE, colors=16))
    if not frames:
        sys.exit("no frames in " + fdir)
    durations = [1800] * len(frames)
    durations[-1] = 4000
    frames[0].save(out, save_all=True, append_images=frames[1:], duration=durations, loop=0, optimize=True)
    frames[-1].convert("RGB").save(os.path.splitext(out)[0] + ".png")
    print(f"{out}: {len(frames)} frames, {w}x{h}")


if __name__ == "__main__":
    main()
