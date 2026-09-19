#!/usr/bin/env python3
"""
Compare rendered frames against a reference render of the same frozen scene.

  tools/image-quality.py <reference.png> <candidate.png> [more candidates...]

Reports PSNR (dB, higher is closer; identical = inf) and mean absolute error on
luma, over the whole frame. Used to quantify upscaling quality against the
native-resolution render, not to judge aesthetics.
"""
import math, sys
from PIL import Image

def luma(path):
    im = Image.open(path).convert("RGB")
    return im.size, [0.299 * r + 0.587 * g + 0.114 * b for r, g, b in im.getdata()]

def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    ref_size, ref = luma(sys.argv[1])
    print(f"reference {sys.argv[1]} {ref_size[0]}x{ref_size[1]}")
    for cand in sys.argv[2:]:
        size, c = luma(cand)
        if size != ref_size:
            print(f"  {cand}: size {size} differs; skipped"); continue
        mse = sum((a - b) ** 2 for a, b in zip(ref, c)) / len(ref)
        mae = sum(abs(a - b) for a, b in zip(ref, c)) / len(ref)
        psnr = float("inf") if mse == 0 else 10 * math.log10(255 ** 2 / mse)
        print(f"  {cand.split('/')[-1]:44s} PSNR {psnr:6.2f} dB   MAE {mae:5.2f}")

if __name__ == "__main__":
    import warnings; warnings.filterwarnings("ignore")
    main()
