#!/usr/bin/env gnuplot

datafile = "avg.dat"    # Input file name after α/β filtering
band = 0.1                 # Kernel width in ppm

set terminal pngcairo enhanced size 1200,700
set output "nmr.png"

set title  "Simulated 1H NMR Gaussian averaged for 5, 10 ns runs"
set xlabel "ppm"
set ylabel "Intensity"
set key off
set grid

# Determine ppm span from the averaged peaks and expand xrange to include all peaks.
# NOTE: stats is filtered by xrange/yrange if already set, so do this before set xrange. :contentReference[oaicite:4]{index=4}
stats datafile using 1 nooutput
xmin    = STATS_min
xmax    = STATS_max
nlabels = STATS_records

# Add a small margin so kdensity tails and edge peaks are not clipped
xmargin = (xmax - xmin) * 0.05
if (xmargin < 5*band) xmargin = 5*band
if (xmargin < 0.5)    xmargin = 0.5

# Reverse ppm axis by giving xrange in descending order. :contentReference[oaicite:5]{index=5}
set xrange [xmax + xmargin : xmin - xmargin]

# More sampling points for a smooth curve
set samples 4000

# Pre-pass: estimate the max intensity of the smoothed spectrum for auto label placement.
# set table requires an explicit unset table to return to normal plotting. :contentReference[oaicite:6]{index=6}
kdtmp = "__kdensity.tmp"
set table kdtmp 
plot datafile using 1:2 smooth kdensity bandwidth band
unset table

stats kdtmp using 2 nooutput
ymax = STATS_max
if (ymax <= 0) ymax = 1

# Auto label "start" (top) and "descent" (step) based on peak count and spectrum height.
label_top     = ymax * 1.10
label_bottom  = ymax * 0.20
first_label_y = label_top
label_step    = (nlabels > 1) ? ((label_top - label_bottom) / (nlabels - 1)) : 0.0

# Headroom for labels
set yrange [0:label_top*1.05]

# Optional: cleanup temp table output
system sprintf("rm -f %s", kdtmp)

# Safety: some gnuplot builds reset output/terminal after set table; force them back.
set terminal pngcairo enhanced size 1200,700
set output "nmr.png"

# Sum of Gaussians centered at each x with weight y
# 1st plot: spectrum
# 2nd plot: labels at x=ppm, y stacked above each other
plot datafile using 1:2 smooth kdensity bandwidth band with lines lw 2, \
     "" using 1:(first_label_y - label_step * $0):3 with labels center notitle