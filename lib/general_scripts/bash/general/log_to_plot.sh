#!/bin/bash
set -euo pipefail

num=1

# Resolve paths robustly
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"          # .../lib/general_scripts
AWK_SCRIPT="$ROOT_DIR/awk/gjf_to_plot.awk"
AVG_SCRIPT="$SCRIPT_DIR/average_plot.sh"

mkdir -p plots

# 1) Constant reference shielding (σ_ref)
# Default: take from config variable "${sigma}" (your existing behavior)
SIGMA_REF="${sigma}"

# Optional: if you provide a dedicated TMS reference log, compute σ_ref as the MEAN of all H in that log
# export TMS_LOG="path/to/tms.log"
if [[ -n "${TMS_LOG:-}" && -f "${TMS_LOG}" ]]; then
  tms_mean=$(
    awk '
      /Magnetic shielding tensor/ {inblock=1}
      inblock && /Isotropic/ {
        line=$0
        gsub(/Isotropic=/,  "Isotropic =",  line)
        gsub(/Anisotropy=/, "Anisotropy =", line)
        n = split(line, a, /[[:space:]]+/)
        for (i = 1; i <= n - 3; i++) {
          if (a[i] ~ /^[0-9]+$/ && a[i+1] ~ /^[A-Za-z]{1,2}$/ && a[i+2] == "Isotropic") {
            elem = toupper(a[i+1])
            iso  = (a[i+3] == "=" ? a[i+4] : a[i+3])
            gsub(/[dD]/, "E", iso)
            if (elem=="H") { sum += (iso+0); cnt++ }
          }
        }
      }
      inblock && /^$/ {inblock=0}
      END { if (cnt>0) printf("%.6f\n", sum/cnt) }
    ' "${TMS_LOG}"
  )
  if [[ -n "$tms_mean" ]]; then
    SIGMA_REF="$tms_mean"
  fi
fi

# 2) Optional linear scaling of shifts (defaults: no scaling)
SCALE_M="${SCALE_M:-1}"
SCALE_B="${SCALE_B:-0}"

# 3) Extract per-frame shifts using a CONSTANT σ_ref
for file in nmr/frame_*.log; do
  awk -v SIGMA_REF="${SIGMA_REF}" \
      -v SCALE_M="${SCALE_M}" -v SCALE_B="${SCALE_B}" \
      -v LIMIT="${limit}" \
      -f "${AWK_SCRIPT}" "$file" > "plots/plot_${num}.dat"
  ((num++))
done

# Average into avg.dat
bash "${AVG_SCRIPT}"

# Export all raw peaks
LC_ALL=C sort -n -k1,1 plots/plot_*.dat > all_peaks.dat
