#!/usr/bin/env gnuplot

datafile = "all_peaks.dat"    # Un-averaged peaks from all frames (x=ppm, y=intensity)

set terminal pngcairo enhanced size 1200,700
set output "nmr_all_peaks.png"

set title  "Simulated 1H NMR - all per-frame peaks (no averaging, sharp)"
set xlabel "ppm"
set ylabel "Intensity"
set key off
set grid

# Determine ppm span from all peaks and expand xrange to include edge peaks
stats datafile using 1 nooutput
xmin = STATS_min
xmax = STATS_max

xmargin = (xmax - xmin) * 0.05
if (xmargin < 0.5) xmargin = 0.5

# Reverse ppm axis (NMR convention)
set xrange [xmax + xmargin : xmin - xmargin]

# Stick spectrum: each peak is a sharp impulse (vertical line) at its ppm
set yrange [0:1.2]

plot datafile using 1:2 with impulses lw 1
