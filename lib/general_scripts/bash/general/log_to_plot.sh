#!/bin/bash

num=1

# Default SIGMA_TMS comes from config (kept as fallback)
SIGMA_TMS_DEFAULT="${sigma}"
SIGMA_TMS="${SIGMA_TMS_DEFAULT}"

# Prefer extracting SIGMA_TMS from Gaussian output (frame_0) so we do not rely on a hardcoded constant
ref_log="nmr/frame_0.log"
if [[ ! -f "$ref_log" ]]; then
    ref_log=$(ls -1 nmr/frame_*.log 2>/dev/null | head -n 1)
fi

if [[ -f "$ref_log" ]]; then
    ref_sigma=$(awk -v LIMIT="${limit}" '
        /Magnetic shielding tensor/ { inblock=1; next }
        inblock && /Isotropic/ {
            atom=$1; elem=$2; iso=$5
            if (elem=="H" && atom<=LIMIT) { print iso; exit }
        }
        inblock && /^$/ { inblock=0 }
    ' "$ref_log")
    if [[ -n "$ref_sigma" ]]; then
        SIGMA_TMS="$ref_sigma"
    fi
fi


#Extract the NMR data for each *.log file resulting from running Gaussian
for file in nmr/frame_*.log; do

    # shellcheck disable=SC2154
    awk -v SIGMA_TMS="${SIGMA_TMS}" -v LIMIT="${limit}" -f gjf_to_plot.awk "$file" > plots/plot_${num}.dat
    ((num++))

done

#Then average all the files into singular result -> avg.dat
bash average_plot.sh
