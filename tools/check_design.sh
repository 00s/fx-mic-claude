#!/bin/zsh
# Design-system guard, run by make_app.sh: type is Apple's own fonts only (SF Pro and SF Mono through Font.ui and
# Font.mono in Sources/FXMic/HUD.swift). Fails if a bundled or named font comes back. Changing the type is a design
# system change: update this check, CLAUDE.md's "Design system" and Font.ui / Font.mono together.
cd "$(dirname "$0")/.."
bad=$(grep -rnE '\.custom\(|NSFont\(name|CTFontManagerRegister|ATSApplicationFontsPath|UIAppFonts|\.(ttf|otf|woff2?)\b' \
        Sources tools/make_app.sh 2>/dev/null)
fonts=$(ls fonts 2>/dev/null)
if [[ -n "$bad" || -n "$fonts" ]]; then
  echo "design check failed: the app's type is Apple's fonts only (see CLAUDE.md, Design system)"
  [[ -n "$bad" ]] && echo "$bad"
  [[ -n "$fonts" ]] && echo "fonts/ holds: $fonts"
  exit 1
fi
