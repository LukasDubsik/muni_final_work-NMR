#!/bin/bash

num=1

# Default SIGMA_TMS comes from config (kept as fallback)
SIGMA_TMS_DEFAULT="${sigma}"
SIGMA_TMS="${SIGMA_TMS_DEFAULT}"

# Optional: derive SIGMA_TMS from a dedicated TMS reference log (same method/basis/solvent).
# Set TMS_LOG to point at it. We only auto-use frame_0 if it *looks like* TMS (contains Si).
# ref_log="${TMS_LOG:-nmr/tms.log}"
# if [[ ! -f "$ref_log" ]]; then
#     if [[ -f "nmr/frame_0.log" ]] && grep -qE '^[[:space:]]*Si[[:space:]]+Isotropic' "nmr/frame_0.log"; then
#         ref_log="nmr/frame_0.log"
#     fi
# fi

# if [[ -f "$ref_log" ]]; then
#     ref_sigma=$(awk '
#         /Magnetic shielding tensor/ { inblock=1; next }
#         inblock && /Isotropic/ {
#             elem=$2; iso=$5
#             if (elem=="H") { print iso; exit }
#         }
#         inblock && /^$/ { inblock=0 }
#     ' "$ref_log")
#     if [[ -n "$ref_sigma" ]]; then
#         SIGMA_TMS="$ref_sigma"
#     fi
# fi


#Extract the NMR data for each *.log file resulting from running Gaussian
for file in nmr/frame_*.log; do

	ref_sigma=$(awk '
        /Magnetic shielding tensor/ { inblock=1; next }
        inblock && /Isotropic/ {
            elem=$2; iso=$5
            if (elem=="H") { print iso; exit }
        }
        inblock && /^$/ { inblock=0 }
    ' "$file")
    if [[ -n "$ref_sigma" ]]; then
        SIGMA_TMS="$ref_sigma"
    fi

    # shellcheck disable=SC2154
    awk -v SIGMA_TMS="${SIGMA_TMS}" -v LIMIT="${limit}" -f gjf_to_plot.awk "$file" > plots/plot_${num}.dat
    ((num++))

done

#Then average all the files into singular result -> avg.dat
bash average_plot.sh

#Also export all per-frame peaks (no averaging) for "sharp peak" plotting
LC_ALL=C sort -n -k1,1 plots/plot_*.dat > all_peaks.dat
