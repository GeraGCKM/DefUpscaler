"""Share byte-identical weight blobs across fixed-shape profiles, inside the bundle.

Only weights are deduplicated. Each model keeps its own compiled graph/metadata.
The packaged-model inference tests must pass before the ZIP is delivered.
"""
import hashlib
import os
from pathlib import Path
import sys

root = Path(sys.argv[1]).resolve()
seen = {}
saved = 0
for path in sorted(root.glob('*.mlmodelc/**/weight*.bin')):
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if digest not in seen:
        seen[digest] = path
        continue
    original = seen[digest]
    size = path.stat().st_size
    path.unlink()
    path.symlink_to(os.path.relpath(original, path.parent))
    assert path.resolve().is_relative_to(root)
    saved += size
print(f'Shared identical model weights: {saved:,} bytes avoided')
