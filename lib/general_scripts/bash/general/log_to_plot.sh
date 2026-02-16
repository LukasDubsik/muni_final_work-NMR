#!/bin/bash
set -euo pipefail

num=1
mkdir -p plots

: "${SIGMA_TMS:?SIGMA_TMS is not set (run_analysis must export it)}"

for file in nmr/frame_*.log; do
    awk -v SIGMA_TMS="${SIGMA_TMS}" -v LIMIT="${limit}" -f gjf_to_plot.awk "$file" > "plots/plot_${num}.dat"
    ((num++))
done

bash average_plot.sh
LC_ALL=C sort -n -k1,1 plots/plot_*.dat > all_peaks.dat
