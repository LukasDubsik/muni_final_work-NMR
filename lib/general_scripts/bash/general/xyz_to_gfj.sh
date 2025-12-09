#!/bin/bash

# shellcheck disable=SC2154
N_CORE=${limit}
char=${charge}

for file in frames/frame_*.xyz; do

    bas=""$(basename "$file" .xyz)
    base=gauss/${bas}
    echo "%chk=${bas}.chk" > "${base}".gjf
    # shellcheck disable=SC2129
    printf "%s\n" "#P B3LYP/GenECP NMR=(GIAO,ReadAtoms) SCRF=COSMO SCF=(XQC,Tight) Int=UltraFine CPHF=Grid=Ultrafine" >> "${base}".gjf

    echo "" >> "${base}".gjf
    echo "${bas} — GIAO NMR (Solute with COSMO)" >> "${base}".gjf
    echo "" >> "${base}".gjf
    echo "$char 1" >> "${base}".gjf

    {
		tail -n +3 "$file" | grep -v 'XP' | awk '
        {
            name = $1
            x = $2; y = $3; z = $4

			sub(/[0-9].*$/, "", name)

            if (length(name) >= 2 && substr(name,2,1) ~ /[a-z]/) {
                elem = substr(name, 1, 2)
            } else {
                elem = substr(name, 1, 1)
            }

            printf "%-2s %12.6f %12.6f %12.6f\n", elem, x, y, z
        }
        '
    	echo ""
	} >> "${base}".gjf

	# Split the atoms by basis
	{
        echo "H C N O S P F Cl Br I 0"
        echo "6-31++G(d,p)"
        echo "****"
        echo "Au 0"
        echo "SDD"
        echo "****"
        echo ""
        echo "Au 0"
        echo "SDD"
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
