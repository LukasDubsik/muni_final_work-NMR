#!/bin/bash

num=1
sigma=32.2  #Value computed by program Multiwfn for shift

#Extract the NMR data for each *.log file resulting from running Gaussian
for file in nmr/frame.*.log; do

    awk -v SIGMA_TMS=${sigma} -v LIMIT=${limit} -f gjf_to_plot.awk $file > plots/plot.${num}.dat
    ((num++))

done

#Then average all the files into singular result -> avg.dat
bash average_plot.sh
