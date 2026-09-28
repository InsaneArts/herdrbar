#!/bin/bash
# Fills in Casks/herdrbar.rb.in from an actual release zip. Never use a hash you did not compute.
set -euo pipefail
[[ $# == 3 && "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && -f "$2" ]] || {
  echo 'Usage: Scripts/generate-cask.sh VERSION ZIP OUTPUT' >&2; exit 1;
}
digest="$(shasum -a 256 "$2" | awk '{print $1}')"
sed -e "s/@VERSION@/$1/g" -e "s/@SHA256@/$digest/g" "$(dirname "$0")/../Casks/herdrbar.rb.in" > "$3"
