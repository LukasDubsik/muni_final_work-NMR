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


#  ESP charges with hydrogens summed into heavy atoms:
#                1
#      1  C    0.787946
#      2  C   -0.004780
#      3  C    0.000958
#      6  N   -0.225277
#      7  N   -0.241868
#      8  Cl  -0.422541
#      9  C    0.009268
#     10  C    0.013553
#     11  C    0.012683
#     12  C   -0.097025
#     13  C   -0.098975
#     14  C    0.053538
#     18  C    0.013158
#     19  C    0.028417
#     20  C    0.013798
#     21  C   -0.101376
#     22  C   -0.096654
#     23  C    0.054082
#     27  C    0.449859
#     28  C   -0.160667
#     29  C   -0.172039
#     37  C    0.447207
#     38  C   -0.170090
#     39  C   -0.161311
#     47  C    0.431545
#     48  C   -0.155665
#     49  C   -0.167892
#     57  C    0.443093
#     58  C   -0.170753
#     59  C   -0.157344
#     67  Au  -0.154849
