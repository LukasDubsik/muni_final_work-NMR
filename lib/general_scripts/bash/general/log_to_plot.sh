#!/bin/bash
set -euo pipefail

shopt -s nullglob

num=1
mkdir -p plots

rm -f plots/plot_*.dat avg.dat all_peaks.dat

gaussian_log_ok() {
  local log_file=$1
  [[ -f "$log_file" ]] || return 1
  grep -q "Normal termination of Gaussian" "$log_file" || return 1
  ! grep -q "Error termination" "$log_file"
}

: "${SIGMA_TMS:?SIGMA_TMS is not set (run_analysis must export it)}"

for file in nmr/frame_*.log; do
  if ! gaussian_log_ok "$file"; then
    echo "[WARN] Skipping non-terminated Gaussian log: $file" >&2
    continue
  fi

  bas=$(basename "$file" .log)
  out="plots/plot_${bas}.dat"

  awk -v SIGMA_TMS="${sigma}" -v LIMIT="${limit}" -f gjf_to_plot.awk "$file" > "$out"

  if [[ ! -s "$out" ]]; then
    echo "[WARN] No shielding data extracted from: $file" >&2
    rm -f "$out"
  fi
done

plot_files=(plots/plot_*.dat)
(( ${#plot_files[@]} > 0 )) || { echo "[ERROR] No plot_*.dat generated" >&2; exit 1; }

bash average_plot.sh "${plot_files[@]}"
cat "${plot_files[@]}" | sort -n -k1,1 > all_peaks.dat
