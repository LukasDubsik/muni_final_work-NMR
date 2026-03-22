#!/bin/bash
set -euo pipefail

# shellcheck disable=SC2154
N_CORE=${limit}      # number of solute heavy atoms (for ReadAtoms H selection)
char=${charge}
WATER_MODE=${water_mode}   # discard | point_charges | full_qm

# TIP3P point charges used when WATER_MODE=point_charges
#   O: -0.834 e    H: +0.417 e  (AMBER TIP3P)
TIP3P_O=-0.834
TIP3P_H=0.417

mkdir -p gauss

# "Light" elements that you want on 6-31++G(d,p) (add/remove as needed)
LIGHT_ORDER=(H C N O S Se P F Cl Br I)

for file in frames/frame_*.xyz; do
    bas=$(basename "$file" .xyz)
    base="gauss/${bas}"
    gjf="${base}.gjf"

    # ------------------------------------------------------------------
    # Split the XYZ into two groups:
    #   - solute atoms  (first N_CORE lines after the header)
    #   - water atoms   (the remainder, expected to be O/H only)
    # ------------------------------------------------------------------
    total_atoms=$(head -n 1 "$file")
    n_water=$(( total_atoms - N_CORE ))

    # Extract solute and water coordinate blocks (skip 2-line XYZ header)
    solute_block=$(tail -n +3 "$file" | grep -v 'XP' | head -n "$N_CORE")

    if (( n_water > 0 )); then
        water_block=$(tail -n +3 "$file" | grep -v 'XP' | tail -n "$n_water")
    else
        water_block=""
    fi

    # ------------------------------------------------------------------
    # Collect elements present in the SOLUTE for basis set assignment
    # ------------------------------------------------------------------
    ELEM_SET=$(
        echo "$solute_block" | awk '
        {
            e=$1
            sub(/[0-9].*$/, "", e)
            e=toupper(substr(e,1,1)) tolower(substr(e,2))
            print e
        }' | sort -u
    )

    has_elem() { grep -Fxq "$1" <<< "$ELEM_SET"; }

    HAS_AU=0
    if has_elem "Au"; then HAS_AU=1; fi

    ROUTE_BASIS="Gen"
    if (( HAS_AU )); then ROUTE_BASIS="GenECP"; fi

    LIGHT_ELEMS=()
    for e in "${LIGHT_ORDER[@]}"; do
        if has_elem "$e"; then
            LIGHT_ELEMS+=("$e")
        fi
    done

    # Guard: detect unsupported elements in solute
    UNKNOWN=()
    while read -r e; do
        [[ -z "$e" ]] && continue
        [[ "$e" == "Au" ]] && continue
        found=0
        for le in "${LIGHT_ORDER[@]}"; do
            [[ "$e" == "$le" ]] && { found=1; break; }
        done
        (( found )) || UNKNOWN+=("$e")
    done <<< "$ELEM_SET"

    if ((${#UNKNOWN[@]})); then
        echo "[ERROR] ${bas}: unsupported elements in XYZ (no basis mapping): ${UNKNOWN[*]}" >&2
        echo "        Add them to LIGHT_ORDER or add a dedicated basis/ECP block." >&2
        exit 1
    fi

    # ------------------------------------------------------------------
    # Write the Gaussian input file
    # ------------------------------------------------------------------
    {
        printf "%%chk=%s.chk\n" "$bas"

        # For point charges we add Charge to the route card so Gaussian reads
        # the Bq atoms as external point charges rather than QM atoms.
        if [[ "$WATER_MODE" == "point_charges" && -n "$water_block" ]]; then
            printf "#P B3LYP/%s NMR=(GIAO,ReadAtoms) SCRF=COSMO SCF=(XQC,Tight) Int=UltraFine CPHF=Grid=UltraFine Charge\n\n" "$ROUTE_BASIS"
        else
            printf "#P B3LYP/%s NMR=(GIAO,ReadAtoms) SCRF=COSMO SCF=(XQC,Tight) Int=UltraFine CPHF=Grid=UltraFine\n\n" "$ROUTE_BASIS"
        fi

        printf "%s — GIAO NMR (Solute with COSMO)\n\n" "$bas"
        printf "%s 1\n" "$char"
    } > "$gjf"

    # ------------------------------------------------------------------
    # Write solute coordinates
    # ------------------------------------------------------------------
    echo "$solute_block" | awk '
    {
        name=$1; x=$2; y=$3; z=$4
        sub(/[0-9].*$/, "", name)
        elem=toupper(substr(name,1,1)) tolower(substr(name,2))
        printf "%-2s %12.6f %12.6f %12.6f\n", elem, x, y, z
    }' >> "$gjf"

    # ------------------------------------------------------------------
    # Optionally append water atoms (full_qm mode only; discard = skip)
    # ------------------------------------------------------------------
    if [[ "$WATER_MODE" == "full_qm" && -n "$water_block" ]]; then
        echo "$water_block" | awk '
        {
            name=$1; x=$2; y=$3; z=$4
            sub(/[0-9].*$/, "", name)
            elem=toupper(substr(name,1,1)) tolower(substr(name,2))
            printf "%-2s %12.6f %12.6f %12.6f\n", elem, x, y, z
        }' >> "$gjf"
    fi

    echo "" >> "$gjf"

    # ------------------------------------------------------------------
    # Basis set section (solute elements only; never for Bq/water)
    # ------------------------------------------------------------------
    {
        if ((${#LIGHT_ELEMS[@]})); then
            printf "%s 0\n" "${LIGHT_ELEMS[*]}"
            echo "6-31++G(d,p)"
            echo "****"
        fi

        if (( HAS_AU )); then
            echo "Au 0"
            echo "SDD"
            echo "****"
        fi

        echo ""

        if (( HAS_AU )); then
            echo "Au 0"
            echo "SDD"
            echo ""
        fi
    } >> "$gjf"

    # ------------------------------------------------------------------
    # ReadAtoms section: select H atoms among solute atoms only
    # ------------------------------------------------------------------
    H_ATOMS=$(
        echo "$solute_block" | awk '
        {i++; if ($1 ~ /^H/) h=(h?h","i:i)}
        END{print h}
        '
    )

    if [[ -n "${H_ATOMS:-}" ]]; then
        {
            echo "atoms=${H_ATOMS}"
            echo ""
        } >> "$gjf"
    else
        echo "[WARN] ${bas}: no H atoms selected for ReadAtoms (atoms=... would be empty)" >&2
    fi

    # ------------------------------------------------------------------
    # Point-charge section (Bq atoms), written AFTER the blank line that
    # terminates the ReadAtoms block.  Gaussian reads this when 'Charge'
    # appears in the route card.
    # ------------------------------------------------------------------
    if [[ "$WATER_MODE" == "point_charges" && -n "$water_block" ]]; then
        echo "$water_block" | awk \
            -v qO="$TIP3P_O" \
            -v qH="$TIP3P_H" '
        {
            name=$1; x=$2; y=$3; z=$4
            # Normalise element symbol
            sub(/[0-9].*$/, "", name)
            elem=toupper(substr(name,1,1)) tolower(substr(name,2))

            # Assign TIP3P partial charge based on element
            if (elem == "O" || elem == "o") {
                q = qO
            } else {
                # Treat everything else in a water residue as H
                q = qH
            }

            # Gaussian point-charge format: Bq  x  y  z  charge
            printf "Bq %12.6f %12.6f %12.6f  %8.5f\n", x, y, z, q
        }' >> "$gjf"
        echo "" >> "$gjf"
    fi

done