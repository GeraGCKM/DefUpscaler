#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/screenshots
python - <<'PY'
from PIL import Image, ImageDraw
image = Image.new('RGB', (400, 650), '#738ba1')
draw = ImageDraw.Draw(image)
draw.rectangle((40, 80, 360, 570), fill='#e7e3d9')
draw.ellipse((90, 180, 310, 400), fill='#334353')
image.save('build/ui-fixture.png')
PY
for appearance in light dark; do
    defaults write io.geragckm.DefUpscaler appearance -string "$appearance"
    open build/DefUpscaler.app --args --preview-fixture "$PWD/build/ui-fixture.png"
    sleep 4
    pgrep -x DefUpscaler >/dev/null
    if ! screencapture -x "build/screenshots/$appearance.png"; then
        echo '::warning::Screen capture unavailable on this runner; manual visual QA remains required.'
    fi
    killall DefUpscaler
    sleep 1
done
defaults delete io.geragckm.DefUpscaler appearance
