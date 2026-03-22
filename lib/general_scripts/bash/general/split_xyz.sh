#!/bin/bash
set -euo pipefail

num=${1:?Starting frame index required}
prefix="frames/frame_"

while IFS= read -r natoms_line; do
    [[ -z "${natoms_line}" ]] && continue
    echo 1.1
    if [[ ! "$natoms_line" =~ ^[[:space:]]*[0-9]+[[:space:]]*$ ]]; then
        echo "[ERROR] Unexpected XYZ frame header: '$natoms_line'" >&2
        exit 1
    fi
    echo 1.2
    natoms=$(echo "$natoms_line" | awk '{print $1}')
    out="${prefix}${num}.xyz"
    : > "$out"
    echo "$natoms" >> "$out"
    echo 1.3
    if ! IFS= read -r comment_line; then
        echo "[ERROR] Missing XYZ comment line for frame $num" >&2
        exit 1
    fi
    echo "$comment_line" >> "$out"
    echo 1.4
    for ((i=0; i<natoms; i++)); do
        if ! IFS= read -r atom_line; then
            echo "[ERROR] Unexpected EOF while reading frame $num" >&2
            exit 1
        fi
        echo "$atom_line" >> "$out"
    done
    echo 1.5
    ((num++))
done