#!/bin/sh
# The cardinal rule (frontend/CLAUDE.md), for the Apple TV: every colour
# comes from Palette (StreamTV/Design/Theme.swift). A raw colour anywhere
# else fails `make lint` — the tvOS twin of bin/design-guard.
found=$(grep -rnE '(^|[^A-Za-z])Color(\(|\.[a-z])|(foregroundStyle|fill|background|tint|stroke|strokeBorder)\(\s*\.(primary|secondary)\b|(^|[^A-Za-z0-9_])\.(red|orange|yellow|green|blue|purple|pink|gray|grey|white|black|brown|cyan|mint|indigo|teal)\b' \
  StreamTV StreamTVTopShelf 2>/dev/null --include=*.swift \
  | grep -v '^StreamTV/Design/Theme.swift:' \
  | grep -vE '^[^:]+:[0-9]+:\s*//')
if [ -n "$found" ]; then
  echo "Raw colours outside Palette (use Palette.*):"
  echo "$found"
  exit 1
fi
echo "lint-colors: every colour comes from Palette."
