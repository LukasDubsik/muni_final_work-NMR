#!/bin/bash
set -euo pipefail

# shellcheck disable=SC2154
N_CORE=${limit}
char=${charge}
WATER_MODE=${water_mode:-discard}
TIP3P_O=${water_oxygen_charge:--0.834}
TIP3P_H=${water_hydrogen_charge:-0.417}

mkdir -p gauss

# "Light" elements that you want on 6-31++G(d,p) (add/remove as needed)
LIGHT_ORDER=(H C N O S Se P F Cl Br I)

case "$WATER_MODE" in
    discard|point_charges|full_qm) ;;
    *)
        echo "[ERROR] Unsupported water mode: $WATER_MODE" >&2
        exit 1
        ;;
esac

for file in frames/frame_*.xyz; do
    [[ -f "$file" ]] || continue

    bas=$(basename "$file" .xyz)
    gjf="gauss/${bas}.gjf"

    solute_block=$(tail -n +3 "$file" | awk -v ncore="$N_CORE" 'NR <= ncore { print }')
    water_block=$(tail -n +3 "$file" | awk -v ncore="$N_CORE" 'NR > ncore { print }')

    if [[ -z "$solute_block" ]]; then
        echo "[ERROR] ${bas}: empty solute block after XYZ split" >&2
        exit 1
    fi

    if [[ "$WATER_MODE" == "full_qm" && -n "$water_block" ]]; then
        qm_block=$(printf "%s\n%s\n" "$solute_block" "$water_block")
    else
        qm_block="$solute_block"
    fi

    # Collect elements present in the QM region only.
    ELEM_SET=$(
        printf "%s\n" "$qm_block" | awk '
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

    ROUTE_EXTRA=""
    if [[ "$WATER_MODE" == "point_charges" && -n "$water_block" ]]; then
        ROUTE_EXTRA=" Charge NoSymm"
    fi

    LIGHT_ELEMS=()
    for e in "${LIGHT_ORDER[@]}"; do
        if has_elem "$e"; then
            LIGHT_ELEMS+=("$e")
        fi
    done

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
        echo "[ERROR] ${bas}: unsupported elements in QM region (no basis mapping): ${UNKNOWN[*]}" >&2
        echo "        Add them to LIGHT_ORDER or add a dedicated basis/ECP block." >&2
        exit 1
    fi

    {
        printf "%%chk=%s.chk\n" "$bas"
        printf "#P B3LYP/%s NMR=(GIAO,ReadAtoms)%s SCRF=COSMO SCF=(XQC,Tight) Int=UltraFine CPHF=Grid=UltraFine\n\n" "$ROUTE_BASIS" "$ROUTE_EXTRA"
        printf "%s -- GIAO NMR\n\n" "$bas"
        printf "%s 1\n" "$char"
    } > "$gjf"

    printf "%s\n" "$qm_block" | awk '
    {
        name=$1; x=$2; y=$3; z=$4
        sub(/[0-9].*$/, "", name)
        elem=toupper(substr(name,1,1)) tolower(substr(name,2))
        printf "%-2s %12.6f %12.6f %12.6f\n", elem, x, y, z
    }' >> "$gjf"
    echo "" >> "$gjf"

    # Background charge distribution must come immediately after the molecule
    # specification when the Charge keyword is present.
    if [[ "$WATER_MODE" == "point_charges" && -n "$water_block" ]]; then
        printf "%s\n" "$water_block" | awk \
            -v qO="$TIP3P_O" \
            -v qH="$TIP3P_H" \
            -v base="$bas" '
        {
            name=$1; x=$2; y=$3; z=$4
            sub(/[0-9].*$/, "", name)
            elem=toupper(substr(name,1,1)) tolower(substr(name,2))

            if (elem == "O") {
                q = qO
            } else if (elem == "H") {
                q = qH
            } else {
                printf("[ERROR] %s: non-water atom after solute boundary in point-charge mode: %s\n", base, elem) > "/dev/stderr"
                exit 2
            }

            printf "%12.6f %12.6f %12.6f % .6f\n", x, y, z, q
        }' >> "$gjf"
        echo "" >> "$gjf"
    fi

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

    H_ATOMS=$(printf "%s\n" "$solute_block" | awk '
        {i++; if ($1 ~ /^H/) h=(h?h","i:i)}
        END{print h}
    ')

    if [[ -n "${H_ATOMS:-}" ]]; then
        {
            echo "atoms=${H_ATOMS}"
            echo ""
        } >> "$gjf"
    else
        echo "[WARN] ${bas}: no H atoms selected for ReadAtoms (atoms=... would be empty)" >&2
    fi
done