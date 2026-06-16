#!/bin/bash
# cchud — Claude Code Heads-Up Display (macOS: double-click in Finder to launch)
cd "$(dirname "$0")" || exit 1

RSCRIPT="$(command -v Rscript)"
if [ -z "$RSCRIPT" ]; then
  for p in /opt/homebrew/bin/Rscript /usr/local/bin/Rscript \
           /Library/Frameworks/R.framework/Resources/bin/Rscript; do
    [ -x "$p" ] && RSCRIPT="$p" && break
  done
fi
if [ -z "$RSCRIPT" ]; then
  echo "Rscript not found. Install R from https://cran.r-project.org/ (or 'brew install r')."
  echo "Press any key to close."; read -r -n 1
  exit 1
fi

"$RSCRIPT" run.R
status=$?
if [ "$status" -ne 0 ]; then
  echo
  echo "cchud exited with status $status. Press any key to close."
  read -r -n 1
fi
