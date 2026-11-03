"""Generate an apples-to-apples synthetic visual comparison and basic error metrics.

The metric is an engineering check only. Real photo perceptual quality and
hallucinations require manual inspection on representative source photos.
"""
import json
from pathlib import Path
import sys
import numpy as np
from PIL import Image, ImageDraw

folder = Path(sys.argv[1] if len(sys.argv) > 1 else "build/quality")
reference = Image.open(folder / "reference.png").convert("RGB")
original = Image.open(folder / "input.png").convert("RGB")
candidates = [
    ("Lanczos only", original.resize(reference.size, Image.Resampling.LANCZOS)),
    ("RealESRGAN x4", Image.open(folder / "realesrgan4.png").convert("RGB")),
    ("RealESRGAN x2 + Lanczos", Image.open(folder / "realesrgan2.png").convert("RGB").resize(reference.size, Image.Resampling.LANCZOS)),
    ("RealPLKSR x4", Image.open(folder / "realplksr4.png").convert("RGB")),
]
ref = np.asarray(reference, dtype=np.float64)
metrics = {"description": "Deterministic synthetic high-frequency reference; not a photo benchmark", "candidates": {}}
panels = [("Reference", reference)] + candidates
for name, image in candidates:
    if image.size != reference.size:
        raise ValueError(name + " has incorrect comparison dimensions")
    delta = np.asarray(image, dtype=np.float64) - ref
    mse = float(np.mean(delta * delta))
    mae = float(np.mean(np.abs(delta)))
    psnr = float(10 * np.log10(255 * 255 / mse)) if mse else 100.0
    metrics["candidates"][name] = {"psnr_db": round(psnr, 3), "mae_8bit": round(mae, 3)}
    print(f"{name}: synthetic PSNR {psnr:.2f} dB; MAE {mae:.2f} / 255", flush=True)
panel_width, panel_height = reference.size
sheet = Image.new("RGB", (panel_width * len(panels), panel_height + 40), "#16181e")
draw = ImageDraw.Draw(sheet)
for i, (name, image) in enumerate(panels):
    sheet.paste(image, (i * panel_width, 40))
    draw.text((i * panel_width + 6, 12), name, fill="white")
sheet.save(folder / "comparison.png")
(folder / "synthetic-quality.json").write_text(json.dumps(metrics, indent=2) + "\n")
