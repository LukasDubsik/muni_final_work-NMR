#!/bin/bash

# shellcheck disable=SC2154
N_CORE=${limit}

for file in frames/frame_*.xyz; do

    bas=""$(basename "$file" .xyz)
    base=gauss/${bas}
    echo "%chk=${bas}.chk" > "${base}".gjf
    # shellcheck disable=SC2129
    printf "%s\n" "#P B3LYP/6-31G(d) NMR=(GIAO,ReadAtoms) SCRF=COSMO SCF=(XQC,Tight) Int=UltraFine CPHF=Grid=Ultrafine" >> "${base}".gjf

    echo "" >> "${base}".gjf
    echo "${bas} — GIAO NMR (Solute with bound waters)" >> "${base}".gjf
    echo "" >> "${base}".gjf
    echo "0 1" >> "${base}".gjf

    {
		tail -n +3 "$file" | grep -v 'XP' | awk '{i++; h=(~$1)} END{print h}'
    	echo ""
	} >> "${base}".gjf

    # Only the selected H atoms will have NMR computed
    H_ATOMS=$(tail -n +3 "$file" | grep -v 'XP' | head -n "$N_CORE" | awk '{i++; if ($1 ~ /^H/) h=(h?h","i:i)} END{print h}')
    {
		echo "ReadAtoms"
    	echo "atoms=${H_ATOMS}"
    	echo "" 
	} >> "${base}".gjf

done
