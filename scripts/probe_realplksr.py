"""Non-blocking probe for the optional RealPLKSR Core ML model archive.

This script is intentionally separate from the main app's conversion pipeline.
It records the exact upstream archive SHA-256 and layout before integration.
"""
from pathlib import Path
from urllib.request import Request, urlopen
import hashlib
import zipfile

url = (
    "https://huggingface.co/333i/4xNomosWebPhoto_RealPLKSR-coreml-ios/"
    "resolve/main/4xNomosWebPhoto_RealPLKSR_512_coreml_compiled.zip"
)
destination = Path("build/realplksr-probe.zip")
destination.parent.mkdir(parents=True, exist_ok=True)
request = Request(url, headers={"User-Agent": "DefUpscaler-model-provenance/0.3"})
digest = hashlib.sha256()
with urlopen(request, timeout=60) as response, destination.open("wb") as out:
    while block := response.read(1024 * 1024):
        digest.update(block)
        out.write(block)
print("MODEL_ARCHIVE_SHA256", digest.hexdigest(), flush=True)
print("MODEL_ARCHIVE_BYTES", destination.stat().st_size, flush=True)
with zipfile.ZipFile(destination) as z:
    for info in z.infolist()[:45]:
        print("MODEL_FILE", info.filename, info.file_size, flush=True)
