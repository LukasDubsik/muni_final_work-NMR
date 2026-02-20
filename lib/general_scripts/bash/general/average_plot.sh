#!/bin/bash
set -euo pipefail
shopt -s nullglob

files=("$@")
if (( ${#files[@]} == 0 )); then
  echo "[ERROR] average_plot.sh: no input files" >&2
  exit 1
fi

# Keep only existing non-empty files
ok_files=()
for f in "${files[@]}"; do
  [[ -s "$f" ]] && ok_files+=("$f")
done

if (( ${#ok_files[@]} == 0 )); then
  echo "[ERROR] average_plot.sh: no non-empty input files" >&2
  exit 1
fi

# Average by atom index (3rd column), not by line number.
awk '
  {
    ppm  = $1 + 0
    inten= $2 + 0
    id   = $3
    sum[id]  += ppm
    sumi[id] += inten
    n[id]++
  }
  END {
    for (id in sum) {
      printf "%.6f %.6f %s\n", sum[id]/n[id], sumi[id]/n[id], id
    }
  }
' "${ok_files[@]}" | sort -n -k3,3 > avg.dat