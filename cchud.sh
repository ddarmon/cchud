#!/bin/sh
# cchud — Claude Code Heads-Up Display (Linux / generic POSIX launcher)
cd "$(dirname "$0")" || exit 1

if ! command -v Rscript >/dev/null 2>&1; then
  echo "Rscript not found. Install R (e.g. 'sudo apt install r-base') and ensure it is on PATH."
  exit 1
fi

exec Rscript run.R
