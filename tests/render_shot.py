#!/usr/bin/env python3
"""Render a screen dump from tests/bodies/shot.lua into a PNG preview.

Approximate: fonts are drawn with OpenCV's Hershey faces rather than the
handheld's, so glyphs differ slightly. Positions, sizes and colours are exact,
which is what the preview is for.
"""
import json, sys, cv2, numpy as np

def render(path, out, zoom=3):
    d = json.load(open(path))
    W, H = d["w"], d["h"]
    img = np.full((H*zoom, W*zoom, 3), 255, np.uint8)
    for o in d["ops"]:
        col = tuple(int(v) for v in reversed(o["col"]))   # RGB -> BGR
        a, b, c, e = o["a"]*zoom, o["b"]*zoom, o["c"]*zoom, o["d"]*zoom
        if o["k"] == "fill":
            cv2.rectangle(img, (a, b), (a+c, b+e), col, -1)
        elif o["k"] == "rect":
            cv2.rectangle(img, (a, b), (a+c, b+e), col, max(1, zoom//3))
        elif o["k"] == "line":
            cv2.line(img, (a, b), (c, e), col, max(1, zoom//3))
        elif o["k"] == "str":
            fs = o["fs"]
            scale = fs * zoom / 30.0
            thick = max(1, int(round(scale*2.0)) if o["fb"] == "b" else int(round(scale*1.3)))
            face = cv2.FONT_HERSHEY_DUPLEX if o["fb"] == "b" else cv2.FONT_HERSHEY_SIMPLEX
            baseline = b + int(fs*zoom*0.82)
            cv2.putText(img, o["t"], (a, baseline), face, scale, col, thick, cv2.LINE_AA)
    # frame the visible page so cut-off content is obvious
    cv2.rectangle(img, (0, 0), (W*zoom-1, H*zoom-1), (120, 120, 120), 2)
    cv2.imwrite(out, img)
    print("wrote", out, f"({W}x{H} logical)")

for name in sys.argv[1:]:
    base = "/tmp/claude-0/-home-user-TI-Nspire-CX-II-Casino/60701558-354b-5432-aad2-03d3880ac64e/scratchpad"
    render(f"{base}/shot_{name}.json", f"{base}/shot_{name}.png")
