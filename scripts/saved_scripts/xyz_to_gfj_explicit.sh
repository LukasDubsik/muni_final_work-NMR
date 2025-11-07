#!/bin/bash

N_CORE=${limit}

# TIP3P charges for waters (used for atoms > N_CORE)
Q_O="-0.834"
Q_H="+0.417"

for file in frames/frame.*.xyz; do

    bas=""$(basename "$file" .xyz)
    base=gauss/${bas}
    echo "%chk=${bas}.chk" > ${base}.gjf
    #echo "%mem=15000MB" >> ${base}.gjf
    #echo "%nprocshared=4" >> ${base}.gjf
    printf "%s\n" "#P B3LYP/6-31G(d) NMR=(GIAO,ReadAtoms) SCF=XQC Int=UltraFine CPHF=Grid=Ultrafine Charge"      >> ${base}.gjf

    echo "" >> ${base}.gjf
    echo "${bas} — GIAO NMR (Cys only, Explicit water as point charges)" >> ${base}.gjf
    echo "" >> ${base}.gjf
    echo "0 1" >> ${base}.gjf

    # Print only the first N atoms of the cys residue
    tail -n +3 "$file" | grep -v 'XP' | head -n ${N_CORE} >> ${base}.gjf
    echo "" >> ${base}.gjf

    # Process atom lines: skip first 2 header lines in XYZ, then get water atoms, give them charges
    tail -n +3 "$file" | grep -v 'XP' | tail -n +$((N_CORE+1)) \
      | awk -v qO="${Q_O}" -v qH="${Q_H}" '{
            el=$1; x=$2; y=$3; z=$4;
            q = (el=="O") ? qO : ((el=="H") ? qH : 0.0);
            printf("%s %s %s %s 0.0\n", x, y, z, q);
        }' >> ${base}.gjf
    
    echo "" >> ${base}.gjf

    # Build list of hydrogen atom indices (1-based over the printed geometry)
    H_ATOMS=$(tail -n +3 "$file" | grep -v 'XP' | head -n ${N_CORE} | awk '{i++; if ($1=="H") h=(h?h","i:i)} END{print h}')
    echo "ReadAtoms" >> ${base}.gjf
    echo "atoms=${H_ATOMS}" >> ${base}.gjf
    echo "" >> ${base}.gjf

done
