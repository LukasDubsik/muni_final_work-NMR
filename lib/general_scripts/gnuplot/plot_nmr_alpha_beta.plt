#!/usr/bin/env gnuplot

datafile = "filtered_avg.dat"    # Input file name after α/β filtering
band = 0.1                 # Kernel width in ppm

set terminal pngcairo enhanced size 1200,700
set output "nmr.png"

set title  "Simulated 1H NMR Gaussian averaged for 5, 10 ns runs"
set xlabel "ppm"
set ylabel "Intensity"
set key off
set grid

# Reverse ppm axis automatically
stats datafile using 1 nooutput
# Set xrange for findable results - our results lie in this range, used for better visibility rather than Max/Min
set xrange [7:-2]
# More sampling points for a smooth curve
set samples 4000

first_label_y = 2 * 0.9    # near the top of the plot
label_step    = 5 * 0.06   # vertical spacing between stacked labels

# Sum of Gaussians centered at each x with weight y
# 1st plot: spectrum
# 2nd plot: labels at x=ppm, y stacked above each other
plot datafile using 1:2 smooth kdensity bandwidth band with lines lw 2, \
     "" using 1:(first_label_y - label_step * $0):3 with labels center notitle
 