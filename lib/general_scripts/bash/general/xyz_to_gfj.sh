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

            # Normalize element symbol for Gaussian: AU -> Au, CL -> Cl, BR -> Br, etc.
			elem = toupper(substr(name, 1, 1)) tolower(substr(name, 2))
			printf "%-2s %12.6f %12.6f %12.6f\n", elem, x, y, z
        }
        '
    	echo ""
	} >> "${base}".gjf

	# Build the light-element basis header only from elements actually present in the XYZ.
	ELEM_SET=$(
		tail -n +3 "$file" | grep -v 'XP' | awk '{
			e=$1
			sub(/[0-9].*$/, "", e)
			e=toupper(substr(e,1,1)) tolower(substr(e,2))
			print e
		}' | sort -u
	)

	ELEM_LINE=""
	for e in H C N O S P F Cl Br I; do
		if grep -qx "$e" <<< "$ELEM_SET"; then
			ELEM_LINE+="${e} "
		fi
	done
	ELEM_LINE+="0"

	# Split the atoms by basis
	{
        echo "$ELEM_LINE"
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
