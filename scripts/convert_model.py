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
    def __init__(self, blocks=6):
        super().__init__()
        self.conv_first = nn.Conv2d(3, 64, 3, 1, 1)
        self.body = nn.Sequential(*(RRDB() for _ in range(blocks)))
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


def convert(name, filename, url, digest_expected, blocks):
    OUT.mkdir(parents=True, exist_ok=True)
    weights = OUT / filename
    if not weights.exists():
        urllib.request.urlretrieve(url, weights)
    digest = hashlib.sha256(weights.read_bytes()).hexdigest()
    expected_digest = digest_expected
    if digest != expected_digest:
        raise RuntimeError("Model checksum mismatch; refusing to load weights")
    net = RRDBNet(blocks).eval()
    state = torch.load(weights, map_location="cpu", weights_only=True)
    net.load_state_dict(state["params_ema"], strict=True)
    wrapper = ImageOutput(net).eval()
    torch.set_num_threads(2)
    torch.manual_seed(42)
    example = torch.rand(1, 3, 160, 160)
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, example)
    print(f"Converting {name}", flush=True)
    model = ct.convert(
        traced, inputs=[ct.ImageType(name="input", shape=ct.EnumeratedShapes(shapes=[(1, 3, n, n) for n in [96, 160, 224]], default=(1, 3, 96, 96)), scale=1 / 255)],
        outputs=[ct.TensorType(name="output", dtype=np.float32)],
        minimum_deployment_target=ct.target.macOS14,
        compute_precision=ct.precision.FLOAT16,
        skip_model_load=True,
    )
    model.author = "Real-ESRGAN authors; Core ML packaging by DefUpscaler"
    model.short_description = filename + "; adaptive RGB tiles 96/160/224, output 4x"
    model.license = "BSD-3-Clause; see THIRD_PARTY_NOTICES.md"
    model.save(str(OUT / f"{name}.mlpackage"))
    print(f"Loading {name} on CPU (portable parity reference)", flush=True)
    model = ct.models.MLModel(str(OUT / f"{name}.mlpackage"), compute_units=ct.ComputeUnit.CPU_ONLY)
    print(f"Validating {name}", flush=True)
    # Exercise the actual Core ML runtime, including image normalization and output quantization.
    rng = np.random.default_rng(42)
    errors = []
    for pixels in [rng.integers(0, 256, (n, n, 3), dtype=np.uint8) for n in [96, 160, 224]] + [np.full((96, 96, 3), [30, 100, 220], dtype=np.uint8)]:
        tensor = torch.from_numpy(pixels.copy()).permute(2, 0, 1).unsqueeze(0).float() / 255
        with torch.no_grad():
            expected = wrapper(tensor).squeeze(0).permute(1, 2, 0).numpy()
        actual = np.asarray(model.predict({"input": Image.fromarray(pixels)})["output"], dtype=np.float32).squeeze(0).transpose(1, 2, 0)
        mae = float(np.abs(expected - actual).mean())
        if not np.isfinite(mae) or mae > 2.0:
            raise RuntimeError(f"Core ML parity failed: MAE={mae:.4f}/255")
        errors.append(mae)
    report = {"source": url, "sha256": hashlib.sha256(weights.read_bytes()).hexdigest(),
              "coreml_mae_255": errors, "tiles": [96, 160, 224], "scale": 4,
              "torch": torch.__version__, "coremltools": ct.__version__}
    return report


if __name__ == "__main__":
    reports = {}
    reports["Anime4x"] = convert("Anime4x", "RealESRGAN_x4plus_anime_6B.pth", URL,
        "f872d837d3c90ed2e05227bed711af5671a6fd1c9f7d7e91c911a61f155e99da", 6)
    reports["Photo4x"] = convert("Photo4x", "RealESRGAN_x4plus.pth",
        "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth",
        "4fa0d38905f75ac06eb49a7951b426670021be3018265fd191d2125df9d682f1", 23)
    (OUT / "model-provenance.json").write_text(json.dumps(reports, indent=2) + "\n")
    print(json.dumps(reports, indent=2))
