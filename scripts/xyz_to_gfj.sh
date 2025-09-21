#!/bin/bash

N_CORE=14

for file in frames/frame.*.xyz; do

    bas=""$(basename "$file" .xyz)
    base=gauss/${bas}
    echo "%chk=${bas}.chk" > ${base}.gjf
    echo "%mem=15000MB" >> ${base}.gjf
    echo "%nprocshared=8" >> ${base}.gjf
    echo "#P B3LYP/6-31G(d) NMR=ReadAtoms SCRF=COSMO SCF=(XQC,Tight) Integral=UltraFine CPHF=Grid=Ultrafine" >> ${base}.gjf
    echo "" >> ${base}.gjf
    echo "${bas} — GIAO NMR (Cys only, COSMO)" >> ${base}.gjf
    echo "" >> ${base}.gjf
    echo "0 1" >> ${base}.gjf
    {
        tail -n +3 "$file" | grep -v 'XP' #Filter any line containing virtual atom XP
    } >> ${base}.gjf   # skip header lines in XYZ
    echo "" >> ${base}.gjf
    echo "ReadAtoms" >> ${base}.gjf
    echo "atoms=H" >> ${base}.gjf
    echo "" >> ${base}.gjf

done
