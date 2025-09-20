#!/usr/bin/env gnuplot

datafile = "avg.dat"    #Input file name
band = 0.04         #Kernel width in ppm

set terminal pngcairo enhanced size 1200,700
set output "${name}_nmr.png"

set title  "Simulated 1H NMR Gaussian averaged for 100ps (image per ps)"
set xlabel "ppm"
set ylabel "Instensity"
set key off
set grid

#Reverse ppm axis automatically
stats datafile using 1 nooutput
#Set xrange for findable results - our results lie in this range, used for better visibility rather than Max/Min
set xrange [5:-2]
#More sampling points for a smooth curve
set samples 4000

#Sum of Gaussians centered at each x with weight y
plot datafile using 1:2 smooth kdensity bandwidth band with lines lw 2, "" using 1:2:3 with labels center offset char 0,1 notitle