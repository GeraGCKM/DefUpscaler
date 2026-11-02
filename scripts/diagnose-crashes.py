"""Print only exception and faulting stack, never full crash environment."""
import json
from pathlib import Path
root = Path.home() / 'Library/Logs/DiagnosticReports'
for path in sorted(root.glob('*.ips')):
    if not any(word in path.name.lower() for word in ('python', 'defupscaler', 'coreml')):
        continue
    try:
        raw = path.read_text()
        _, end = json.JSONDecoder().raw_decode(raw)
        report = json.loads(raw[end:])
        print(path.name)
        print('Exception:', report.get('exception'))
        print('Termination:', report.get('termination'))
        print('Application info:', report.get('asi'))
        threads = report.get('threads', [])
        for thread in threads:
            if thread.get('triggered'):
                for frame in thread.get('frames', [])[:20]:
                    print(frame.get('symbol'), frame.get('symbolLocation'))
    except (ValueError, OSError) as error:
        print(type(error).__name__)
