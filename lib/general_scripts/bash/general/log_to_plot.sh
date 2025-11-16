#!/bin/bash

num=1

#Extract the NMR data for each *.log file resulting from running Gaussian
for file in nmr/frame_*.log; do

    # shellcheck disable=SC2154
    awk -v SIGMA_TMS="${sigma}" -v LIMIT="${limit}" -f gjf_to_plot.awk "$file" > plots/plot_${num}.dat
    ((num++))

done

#Then average all the files into singular result -> avg.dat
bash average_plot.sh
