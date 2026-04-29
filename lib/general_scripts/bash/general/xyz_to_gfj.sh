#!/bin/bash
set -euo pipefail

# shellcheck disable=SC2154
N_CORE=${limit}
char=${charge}
WATER_MODE=${water_mode}
TIP3P_O=${water_oxygen_charge}
TIP3P_H=${water_hydrogen_charge}
DEUTERIUM_WATER=${deuterium_water:-false}

mkdir -p gauss

# Project layout: this script is copied to process/spectrum/gauss_prep/xyz_to_gfj.sh,
# so ../../../inputs/bases points back to the repository input basis directory.
SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
BASIS_DIR_DEFAULT=$(cd -- "$SCRIPT_DIR/../../../inputs/bases" 2>/dev/null && pwd || true)
BASIS_DIR=${BASIS_DIR:-$BASIS_DIR_DEFAULT}

OTHER_BASIS="6-311++G(2df,2pd)"
WATER_BASIS="6-31G(d)"

AU_BAS_FILE="$BASIS_DIR/Au_bas"
AU_ECP_FILE="$BASIS_DIR/Au_pot"
S_BAS_FILE="$BASIS_DIR/S_bas"
S_ECP_FILE="$BASIS_DIR/S_pot"
SE_BAS_FILE="$BASIS_DIR/Se_bas"
SE_ECP_FILE="$BASIS_DIR/Se_pot"

require_file() {
    local f="$1"
    [[ -f "$f" ]] || {
        echo "[ERROR] Missing required basis/ECP file: $f" >&2
        exit 1
    }
}

emit_basis_body_from_file() {
    local f="$1"
    awk '
        NR == 1 { next }
        /^[[:space:]]*\*\*\*\*[[:space:]]*$/ { next }
        { print }
    ' "$f"
}

emit_ecp_body_from_file() {
    local f="$1"
    awk 'NR == 1 { next } { print }' "$f"
}

# "Light" elements supported in the QM region.
# D (deuterium) is included so full_qm D2O water does not trigger an unknown-element abort.
LIGHT_ORDER=(H D C N O S Se Si P F Cl Br I)

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

    # In full_qm + D2O mode, replace water H atoms with D before building the QM block.
    if [[ "$WATER_MODE" == "full_qm" && "$DEUTERIUM_WATER" == "true" && -n "$water_block" ]]; then
        water_block=$(printf "%s\n" "$water_block" | awk '
        {
            name=$1; x=$2; y=$3; z=$4
            sub(/[0-9].*$/, "", name)
            elem=toupper(substr(name,1,1)) tolower(substr(name,2))
            if (elem == "H") elem = "D"
            printf "%-2s %12.6f %12.6f %12.6f\n", elem, x, y, z
        }')
    fi

    if [[ "$WATER_MODE" == "full_qm" && -n "$water_block" ]]; then
        qm_block=$(printf "%s\n%s\n" "$solute_block" "$water_block")
    else
        qm_block="$solute_block"
    fi

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
    HAS_S=0
    HAS_SE=0
    if has_elem "Au"; then HAS_AU=1; fi
    if has_elem "S"; then HAS_S=1; fi
    if has_elem "Se"; then HAS_SE=1; fi

    HAS_ECP=0
    if (( HAS_AU || HAS_S || HAS_SE )); then HAS_ECP=1; fi

    ROUTE_BASIS="Gen"
    if (( HAS_ECP )); then ROUTE_BASIS="GenECP"; fi

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

    if (( HAS_AU )); then
        require_file "$AU_BAS_FILE"
        require_file "$AU_ECP_FILE"
    fi
    if (( HAS_S )); then
        require_file "$S_BAS_FILE"
        require_file "$S_ECP_FILE"
    fi
    if (( HAS_SE )); then
        require_file "$SE_BAS_FILE"
        require_file "$SE_ECP_FILE"
    fi

    {
        printf "%%chk=%s.chk\n" "$bas"
        printf "#P wB97XD/%s NMR=(GIAO,ReadAtoms)%s SCRF=(IEFPCM,Solvent=Water) SCF=(XQC,Tight) Int=UltraFine CPHF=Grid=UltraFine\n\n" "$ROUTE_BASIS" "$ROUTE_EXTRA"
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
        if [[ "$WATER_MODE" == "full_qm" && -n "$water_block" ]]; then
            SOLUTE_OTHER_IDX=$(printf "%s\n" "$solute_block" | awk '
                {
                    e=$1
                    sub(/[0-9].*$/, "", e)
                    e=toupper(substr(e,1,1)) tolower(substr(e,2))
                    if (e != "S" && e != "Se" && e != "Au") {
                        printf "%d ", NR
                    }
                }
            ')

            SOLUTE_S_IDX=$(printf "%s\n" "$solute_block" | awk '
                {
                    e=$1
                    sub(/[0-9].*$/, "", e)
                    e=toupper(substr(e,1,1)) tolower(substr(e,2))
                    if (e == "S") {
                        printf "%d ", NR
                    }
                }
            ')

            SOLUTE_SE_IDX=$(printf "%s\n" "$solute_block" | awk '
                {
                    e=$1
                    sub(/[0-9].*$/, "", e)
                    e=toupper(substr(e,1,1)) tolower(substr(e,2))
                    if (e == "Se") {
                        printf "%d ", NR
                    }
                }
            ')

            AU_IDX=$(printf "%s\n" "$solute_block" | awk '
                {
                    e=$1
                    sub(/[0-9].*$/, "", e)
                    e=toupper(substr(e,1,1)) tolower(substr(e,2))
                    if (e == "Au") {
                        printf "%d ", NR
                    }
                }
            ')

            WATER_IDX=$(printf "%s\n" "$water_block" | awk -v off="$N_CORE" '
                NF { printf "%d ", NR + off }
            ')

            if [[ -n "$SOLUTE_OTHER_IDX" ]]; then
                printf "%s0\n" "$SOLUTE_OTHER_IDX"
                echo "$OTHER_BASIS"
                echo "****"
            fi

            if [[ -n "$SOLUTE_S_IDX" ]]; then
                printf "%s0\n" "$SOLUTE_S_IDX"
                emit_basis_body_from_file "$S_BAS_FILE"
                echo "****"
            fi

            if [[ -n "$SOLUTE_SE_IDX" ]]; then
                printf "%s0\n" "$SOLUTE_SE_IDX"
                emit_basis_body_from_file "$SE_BAS_FILE"
                echo "****"
            fi

            if [[ -n "$WATER_IDX" ]]; then
                printf "%s0\n" "$WATER_IDX"
                echo "$WATER_BASIS"
                echo "****"
            fi

            if [[ -n "$AU_IDX" ]]; then
                printf "%s0\n" "$AU_IDX"
                emit_basis_body_from_file "$AU_BAS_FILE"
                echo "****"
            fi
        else
            OTHER_LIGHT_ELEMS=()
            for e in "${LIGHT_ELEMS[@]}"; do
                if [[ "$e" != "S" && "$e" != "Se" && "$e" != "Au" ]]; then
                    OTHER_LIGHT_ELEMS+=("$e")
                fi
            done

            if ((${#OTHER_LIGHT_ELEMS[@]})); then
                printf "%s 0\n" "${OTHER_LIGHT_ELEMS[*]}"
                echo "$OTHER_BASIS"
                echo "****"
            fi

            if (( HAS_S )); then
                echo "S 0"
                emit_basis_body_from_file "$S_BAS_FILE"
                echo "****"
            fi

            if (( HAS_SE )); then
                echo "Se 0"
                emit_basis_body_from_file "$SE_BAS_FILE"
                echo "****"
            fi

            if (( HAS_AU )); then
                echo "Au 0"
                emit_basis_body_from_file "$AU_BAS_FILE"
                echo "****"
            fi
        fi

        echo ""

        if (( HAS_S )); then
            if [[ "$WATER_MODE" == "full_qm" && -n "$water_block" ]]; then
                printf "%s0\n" "$SOLUTE_S_IDX"
            else
                echo "S 0"
            fi
            emit_ecp_body_from_file "$S_ECP_FILE"
            echo ""
        fi

        if (( HAS_SE )); then
            if [[ "$WATER_MODE" == "full_qm" && -n "$water_block" ]]; then
                printf "%s0\n" "$SOLUTE_SE_IDX"
            else
                echo "Se 0"
            fi
            emit_ecp_body_from_file "$SE_ECP_FILE"
            echo ""
        fi

        if (( HAS_AU )); then
            if [[ "$WATER_MODE" == "full_qm" && -n "$water_block" ]]; then
                printf "%s0\n" "$AU_IDX"
            else
                echo "Au 0"
            fi
            emit_ecp_body_from_file "$AU_ECP_FILE"
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