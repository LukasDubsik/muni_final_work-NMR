#!/bin/bash

for file in frames/frame.*.xyz; do

    bas=""$(basename "$file" .xyz)
    base=gauss/${bas}
    echo "%chk=${bas}.chk" > ${base}.gjf
    #echo "%mem=15000MB" >> ${base}.gjf
    #echo "%nprocshared=4" >> ${base}.gjf
    echo "#P B3LYP/6-31G(d) NMR=(GIAO,ReadAtoms) SCF=(XQC,Tight) Integral=UltraFine CPHF=Grid=Ultrafine" >> ${base}.gjf
    echo "" >> ${base}.gjf
    echo "${bas} — GIAO NMR (H only, COSMO)" >> ${base}.gjf
    echo "" >> ${base}.gjf
    echo "0 1" >> ${base}.gjf

    # Process atom lines: skip first 2 header lines in XYZ, then for atoms lines add H or L
    tail -n +3 "$file" | grep -v 'XP' >> ${base}.gjf

    # Build list of hydrogen atom indices (1-based over the printed geometry)
    H_ATOMS=$(tail -n +3 "$file" | grep -v 'XP' | awk '{i++; if ($1=="H") h=(h?h","i:i)} END{print h}')

    echo "" >> ${base}.gjf
    echo "ReadAtoms" >> ${base}.gjf
    echo "atoms=${H_ATOMS}" >> ${base}.gjf
    echo "" >> ${base}.gjf

done
