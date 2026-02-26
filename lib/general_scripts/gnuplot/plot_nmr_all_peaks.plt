#!/usr/bin/env gnuplot

datafile = "all_peaks.dat"    # x=ppm, y=intensity

set terminal pngcairo enhanced size 1200,700
set output "nmr_all_peaks.png"

set title  "Simulated 1H NMR - summed Lorentzian-broadened spectrum"
set xlabel "ppm"
set ylabel "Intensity"
set key off
set grid

# Peak width in ppm (full width at half maximum).
# Increase for broader/smoother peaks, decrease for sharper peaks.
fwhm = 0.03

# Dense sampling so the summed curve looks smooth
set samples 5000

# Determine ppm span from all peaks and expand xrange to include edge peaks
stats datafile using 1 nooutput
xmin = STATS_min
xmax = STATS_max

xmargin = (xmax - xmin) * 0.05
if (xmargin < 0.5) xmargin = 0.5

# Reverse ppm axis (NMR convention)
set xrange [xmax + xmargin : xmin - xmargin]

# Count how many peaks we have
stats datafile using 0 nooutput
npeaks = STATS_records

# Store peak positions and intensities in arrays
array ppm[npeaks]
array amp[npeaks]

set table $PEAKLOAD
    plot datafile using (ppm[int($0)+1] = $1):(amp[int($0)+1] = $2)
unset table

# Lorentzian line shape with height = input intensity at the peak center
lorentz(x, x0, a) = a / (1.0 + 4.0*((x - x0)/fwhm)**2)

# Total spectrum = sum of all broadened peaks
spectrum(x) = sum [i=1:npeaks] lorentz(x, ppm[i], amp[i])

set yrange [0:*]

plot '+' using 1:(spectrum($1)) with lines lw 2