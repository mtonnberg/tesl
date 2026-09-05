#!/usr/bin/env python3
"""Regression test for diagnostic-title attribute injection in the playground."""

from html.parser import HTMLParser
from pathlib import Path
import json
import re
import subprocess


ROOT = Path(__file__).resolve().parents[1]
EDITOR = ROOT / "playground" / "editor.js"


class FirstSpan(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.attrs = None

    def handle_starttag(self, tag, attrs):
        if tag == "span" and self.attrs is None:
            self.attrs = dict(attrs)


source = EDITOR.read_text(encoding="utf-8")
match = re.search(r"^const esc = s => (.*?);$", source, re.DOTALL | re.MULTILINE)
assert match, "playground esc helper not found"

# Execute the production helper, then parse the exact attribute context used by
# renderEditorLayers. HTMLParser exposes attributes in the same shape as the DOM.
payload = 'error E000: got " onanimationstart=alert(document.domain) x="'
script = f"const esc = s => {match.group(1)}; process.stdout.write(esc({json.dumps(payload)}));"
escaped = subprocess.run(
    ["node", "-e", script], check=True, capture_output=True, text=True
).stdout

parser = FirstSpan()
parser.feed(f'<span class="sq error" title="{escaped}">source</span>')
assert parser.attrs is not None
assert set(parser.attrs) == {"class", "title"}, parser.attrs
assert parser.attrs["title"] == payload
