#!/bin/bash

# shellcheck disable=SC2154
N_CORE="${limit}"

for file in frames/frame.*.xyz; do

    bas=""$(basename "$file" .xyz)
    base=gauss/${bas}
    echo "%chk=${bas}.chk" > "${base}".gjf
    # shellcheck disable=SC2129
    printf "%s\n" "#P B3LYP/6-31G(d) NMR=(GIAO,ReadAtoms) SCF=XQC Int=UltraFine CPHF=Grid=Ultrafine Charge" >> "${base}".gjf

    echo "" >> "${base}".gjf
    echo "${bas} — GIAO NMR (Cys only, Explicit water as point charges)" >> "${base}".gjf
    echo "" >> "${base}".gjf
    echo "0 1" >> "${base}".gjf

    {
		tail -n +3 "$file" | grep -v 'XP'
    	echo ""
	} >> "${base}".gjf

    # Only the selected H atoms will have NMR computed
    H_ATOMS=$(tail -n +3 "$file" | grep -v 'XP' | head -n "$N_CORE" | awk '{i++; if ($1=="H") h=(h?h","i:i)} END{print h}')
    {
		echo "ReadAtoms"
    	echo "atoms=${H_ATOMS}"
    	echo "" 
	} >> "${base}".gjf

done
