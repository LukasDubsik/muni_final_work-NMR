#!/bin/bash

#Name of the resulting file
fil="avg.dat"

#Remove previous averaging
rm -f $fil

#Using awk go file by file, line by ine and average ppm for each element
awk '
  NF {                   # skip empty lines if any
    x[FNR] += $1;        # sum the first column by line number
    c[FNR]++;            # count contributions
    a[FNR] = $3;         # number of element
    if (FNR > max) max = FNR
  }
  END {
    #Print the results
    for (i = 1; i <= max; i++)
      printf("%.6f 1 %d\n", x[i]/c[i], a[i]);
  }
' plots/plot_*.dat > "$fil" 