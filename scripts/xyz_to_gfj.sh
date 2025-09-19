#!/bin/bash

for file in frames/frame.*.xyz; do

    base="gauss/"$(basename "$file" .xyz)
    echo "%chk=${base}.chk" > ${base}.gjf
    echo "%mem=15000MB" >> ${base}.gjf
    echo "%nprocshared=8" >> ${base}.gjf
    echo "#P B3LYP/6-31G(d) NMR=GIAO SCRF=(PCM,Solvent=Water) SCF=(XQC,Tight) Integral=UltraFine CPHF=Grid=Ultrafine" >> ${base}.gjf
    echo "" >> ${base}.gjf
    echo "${base} — GIAO NMR" >> ${base}.gjf
    echo "" >> ${base}.gjf
    echo "0 1" >> ${base}.gjf
    {
        tail -n +3 "$file" | grep -v 'XP' #Filter any line containing virtual atom XP
    } >> ${base}.gjf   # skip header lines in XYZ
    echo "" >> ${base}.gjf

done