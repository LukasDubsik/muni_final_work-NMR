#!/bin/bash

N_CORE=15

for file in frames/frame.*.xyz; do

    bas=""$(basename "$file" .xyz)
    base=gauss/${bas}
    echo "%chk=${bas}.chk" > ${base}.gjf
    echo "%mem=15000MB" >> ${base}.gjf
    echo "%nprocshared=4" >> ${base}.gjf
    echo "#P ONIOM(B3LYP/6-31G(d):UFF)=EmbedCharge NMR=ReadAtoms SCRF=COSMO SCF=(XQC,Tight) Integral=UltraFine CPHF=Grid=Ultrafine" >> ${base}.gjf
    echo "" >> ${base}.gjf
    echo "${bas} — GIAO NMR (Cys only, COSMO, ONIOM)" >> ${base}.gjf
    echo "" >> ${base}.gjf
    echo "0 1" >> ${base}.gjf

    # Process atom lines: skip first 2 header lines in XYZ, then for atoms lines add H or L
    tail -n +3 "$file" | grep -v 'XP' | \
      awk -v N=${N_CORE} '{ 
        # NR is awk’s record number, this starts counting at 1 for first atom line after headers
        if (NR <= N) 
          printf("%s H\n", $0);
        else 
          printf("%s L\n", $0);
      }' >> ${base}.gjf

    echo "" >> ${base}.gjf
    echo "ReadAtoms" >> ${base}.gjf
    echo "atoms=1-${N_CORE}" >> ${base}.gjf
    echo "" >> ${base}.gjf

done
