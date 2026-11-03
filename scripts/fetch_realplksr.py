"""Download the optional vetted Core ML RealPLKSR conversion at build time."""
from pathlib import Path, PurePosixPath
from urllib.request import urlopen, Request
import hashlib
import json
import shutil
import tempfile
import zipfile

OUT = Path(__file__).resolve().parents[1] / "build" / "models"
URL = (
    "https://huggingface.co/333i/4xNomosWebPhoto_RealPLKSR-coreml-ios/"
    "resolve/main/4xNomosWebPhoto_RealPLKSR_512_coreml_compiled.zip"
)
SHA256 = "187b0c2fa3c2cb3bd20aef647e68a07e61316559e41bd53bfaa72090facb51be"
ROOT = "4xNomosWebPhoto_RealPLKSR_512.mlmodelc"
UPSTREAM_CHECKPOINT_SHA256 = "9be0228f98156a100d6636d99b373ed2785b999723f9adc4cca504329ab157f2"

def main():
    OUT.mkdir(parents=True, exist_ok=True)
    archive = OUT / "webphoto-model.zip"
    if not archive.exists():
        request = Request(URL, headers={"User-Agent": "DefUpscaler/0.3 model-build"})
        with urlopen(request, timeout=70) as response, archive.open("wb") as target:
            size = 0
            while chunk := response.read(1024 * 1024):
                size += len(chunk)
                if size > 100 * 1024 * 1024:
                    raise ValueError("Model download exceeds archive size budget")
                target.write(chunk)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != SHA256:
        archive.unlink(missing_ok=True)
        raise ValueError("RealPLKSR compiled model archive SHA-256 mismatch")
    destination = OUT / "WebPhoto4x.mlmodelc"
    with zipfile.ZipFile(archive) as z, tempfile.TemporaryDirectory(dir=OUT) as temp:
        for member in z.infolist():
            path = PurePosixPath(member.filename)
            if path.is_absolute() or ".." in path.parts or path.parts[0] not in (ROOT, "model.json"):
                raise ValueError("Unexpected path in model archive")
            if member.file_size > 90 * 1024 * 1024:
                raise ValueError("Unexpectedly large model archive member")
        z.extractall(temp)
        extracted = Path(temp) / ROOT
        if not (extracted / "model.mil").is_file() or not (extracted / "weights" / "weight.bin").is_file():
            raise ValueError("Compiled model files are incomplete")
        if destination.exists():
            shutil.rmtree(destination)
        shutil.copytree(extracted, destination)
    provenance = OUT / "model-provenance.json"
    models = json.loads(provenance.read_text()) if provenance.exists() else {}
    models["WebPhoto4x"] = {
        "source": "https://huggingface.co/Phips/4xNomosWebPhoto_RealPLKSR",
        "coreml_port": URL,
        "compiled_archive_sha256": SHA256,
        "upstream_checkpoint_sha256": UPSTREAM_CHECKPOINT_SHA256,
        "license": "CC-BY-4.0",
        "format": "Core ML fixed 512x512 -> 2048x2048 pixel buffer",
        "model_parity": "conversion author's separate reference test; run native integration locally"
    }
    provenance.write_text(json.dumps(models, indent=2) + "\n")
    print("Verified optional RealPLKSR model:", destination)

if __name__ == "__main__":
    main()
