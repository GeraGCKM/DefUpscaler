"""Build-time only. Convert official Real-ESRGAN weights and verify Core ML parity."""
import hashlib
import json
from pathlib import Path
import urllib.request

import coremltools as ct
import numpy as np
from PIL import Image
import torch
from torch import nn
from torch.nn import functional as F

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build" / "models"
URL = "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.2.4/RealESRGAN_x4plus_anime_6B.pth"


class DenseBlock(nn.Module):
    def __init__(self):
        super().__init__()
        for i in range(1, 6):
            setattr(self, f"conv{i}", nn.Conv2d(64 + (i - 1) * 32, 64 if i == 5 else 32, 3, 1, 1))

    def forward(self, x):
        values = [x]
        for i in range(1, 5):
            values.append(F.leaky_relu(getattr(self, f"conv{i}")(torch.cat(values, dim=1)), 0.2))
        return x + self.conv5(torch.cat(values, dim=1)) * 0.2


class RRDB(nn.Module):
    def __init__(self):
        super().__init__()
        self.rdb1, self.rdb2, self.rdb3 = DenseBlock(), DenseBlock(), DenseBlock()

    def forward(self, x):
        return x + self.rdb3(self.rdb2(self.rdb1(x))) * 0.2


class RRDBNet(nn.Module):
    def __init__(self):
        super().__init__()
        self.conv_first = nn.Conv2d(3, 64, 3, 1, 1)
        self.body = nn.Sequential(*(RRDB() for _ in range(6)))
        self.conv_body = nn.Conv2d(64, 64, 3, 1, 1)
        self.conv_up1 = nn.Conv2d(64, 64, 3, 1, 1)
        self.conv_up2 = nn.Conv2d(64, 64, 3, 1, 1)
        self.conv_hr = nn.Conv2d(64, 64, 3, 1, 1)
        self.conv_last = nn.Conv2d(64, 3, 3, 1, 1)

    def forward(self, x):
        first = self.conv_first(x)
        x = first + self.conv_body(self.body(first))
        x = F.leaky_relu(self.conv_up1(F.interpolate(x, scale_factor=2, mode="nearest")), 0.2)
        x = F.leaky_relu(self.conv_up2(F.interpolate(x, scale_factor=2, mode="nearest")), 0.2)
        return self.conv_last(F.leaky_relu(self.conv_hr(x), 0.2))


class ImageOutput(nn.Module):
    def __init__(self, network):
        super().__init__()
        self.network = network

    def forward(self, x):
        return torch.clamp(self.network(x), 0, 1) * 255


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    weights = OUT / "RealESRGAN_x4plus_anime_6B.pth"
    if not weights.exists():
        urllib.request.urlretrieve(URL, weights)
    digest = hashlib.sha256(weights.read_bytes()).hexdigest()
    expected_digest = "f872d837d3c90ed2e05227bed711af5671a6fd1c9f7d7e91c911a61f155e99da"
    if digest != expected_digest:
        raise RuntimeError("Model checksum mismatch; refusing to load weights")
    net = RRDBNet().eval()
    state = torch.load(weights, map_location="cpu", weights_only=True)
    net.load_state_dict(state["params_ema"], strict=True)
    wrapper = ImageOutput(net).eval()
    torch.set_num_threads(2)
    torch.manual_seed(42)
    example = torch.rand(1, 3, 160, 160)
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, example)
    model = ct.convert(
        traced, inputs=[ct.ImageType(name="input", shape=example.shape, scale=1 / 255)],
        outputs=[ct.ImageType(name="output", color_layout=ct.colorlayout.RGB)],
        minimum_deployment_target=ct.target.macOS14,
        compute_precision=ct.precision.FLOAT16,
    )
    model.author = "Real-ESRGAN authors; Core ML packaging by DefUpscaler"
    model.short_description = "RealESRGAN_x4plus_anime_6B; 160px RGB input, 640px RGB output"
    model.license = "BSD-3-Clause; see THIRD_PARTY_NOTICES.md"
    model.save(str(OUT / "Anime4x.mlpackage"))
    # Exercise the actual Core ML runtime, including image normalization and output quantization.
    rng = np.random.default_rng(42)
    errors = []
    for pixels in [rng.integers(0, 256, (160, 160, 3), dtype=np.uint8),
                   np.full((160, 160, 3), [30, 100, 220], dtype=np.uint8)]:
        tensor = torch.from_numpy(pixels.copy()).permute(2, 0, 1).unsqueeze(0).float() / 255
        with torch.no_grad():
            expected = wrapper(tensor).squeeze(0).permute(1, 2, 0).numpy()
        actual = np.asarray(model.predict({"input": Image.fromarray(pixels)})["output"].convert("RGB"), dtype=np.float32)
        mae = float(np.abs(expected - actual).mean())
        if not np.isfinite(mae) or mae > 2.0:
            raise RuntimeError(f"Core ML parity failed: MAE={mae:.4f}/255")
        errors.append(mae)
    report = {"source": URL, "sha256": hashlib.sha256(weights.read_bytes()).hexdigest(),
              "coreml_mae_255": errors, "tile": 160, "scale": 4,
              "torch": torch.__version__, "coremltools": ct.__version__}
    (OUT / "model-provenance.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
