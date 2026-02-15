#!/bin/bash
set -euo pipefail

# shellcheck disable=SC2154
N_CORE=${limit}
char=${charge}

mkdir -p gauss

# "Light" elements that you want on 6-31++G(d,p) (add/remove as needed)
LIGHT_ORDER=(H C N O S Se P F Cl Br I)

for file in frames/frame_*.xyz; do
    bas=$(basename "$file" .xyz)
    base="gauss/${bas}"
    gjf="${base}.gjf"

    # Collect elements present (normalized like Gaussian expects: AU->Au, SE->Se, CL->Cl)
    ELEM_SET=$(
        tail -n +3 "$file" | grep -v 'XP' | awk '
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

    # Choose Gen vs GenECP based on whether Au is present
    ROUTE_BASIS="Gen"
    if (( HAS_AU )); then ROUTE_BASIS="GenECP"; fi

    # Build the light-element header line only from elements actually present
    LIGHT_ELEMS=()
    for e in "${LIGHT_ORDER[@]}"; do
        if has_elem "$e"; then
            LIGHT_ELEMS+=("$e")
        fi
    done

    # Guard: detect unsupported elements (present but not mapped)
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

    # Write header
    {
        printf "%%chk=%s.chk\n" "$bas"
        printf "#P B3LYP/%s NMR=(GIAO,ReadAtoms) SCRF=COSMO SCF=(XQC,Tight) Int=UltraFine CPHF=Grid=UltraFine\n\n" "$ROUTE_BASIS"
        printf "%s — GIAO NMR (Solute with COSMO)\n\n" "$bas"
        printf "%s 1\n" "$char"
    } > "$gjf"

    # Write coordinates
    tail -n +3 "$file" | grep -v 'XP' | awk '
    {
        name=$1; x=$2; y=$3; z=$4
        sub(/[0-9].*$/, "", name)
        elem=toupper(substr(name,1,1)) tolower(substr(name,2))
        printf "%-2s %12.6f %12.6f %12.6f\n", elem, x, y, z
    }' >> "$gjf"
    echo "" >> "$gjf"

    # Write basis section: only what is present
    {
        # Light elements (only if any present)
        if ((${#LIGHT_ELEMS[@]})); then
            printf "%s 0\n" "${LIGHT_ELEMS[*]}"
            echo "6-31++G(d,p)"
            echo "****"
            echo ""
        fi

        # Au basis (only if Au present)
        if (( HAS_AU )); then
            echo "Au 0"
            echo "SDD"
            echo "****"
            echo ""
            # ECP section for GenECP (only if Au present)
            echo "Au 0"
            echo "SDD"
            echo ""
        fi
    } >> "$gjf"

    # Only the selected H atoms will have NMR computed
    # (keeps your original behavior: scan first N_CORE atoms, then pick H indices among them)
    H_ATOMS=$(
        tail -n +3 "$file" | grep -v 'XP' | head -n "$N_CORE" | awk '
        {i++; if ($1 ~ /^H/) h=(h?h","i:i)}
        END{print h}
        '
    )

    # If none selected, don't emit a broken ReadAtoms section
    if [[ -n "${H_ATOMS:-}" ]]; then
        {
            #echo "ReadAtoms"
            echo "atoms=${H_ATOMS}"
            echo ""
        } >> "$gjf"
    else
        echo "[WARN] ${bas}: no H atoms selected for ReadAtoms (atoms=... would be empty)" >&2
    fi

done
