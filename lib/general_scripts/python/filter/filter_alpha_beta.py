#!/usr/bin/env python3
"""
Filter an NMR peak list to only Cα / Cβ hydrogens of an amino acid
and label them as A<id> or B<id> in the 3rd column.

Usage:
    python select_alpha_beta.py avg.dat structure.mol2 avg_ab.dat
"""

from __future__ import annotations

import argparse
from collections import defaultdict
from typing import Dict, List, Tuple, Set


def parse_mol2(mol2_path: str):
    """
    Parse @<TRIPOS>ATOM and @<TRIPOS>BOND sections of a MOL2 file.

    Returns:
        atoms: dict[atom_id] -> {"name": str, "type": str, "element": str}
        neighbors: dict[atom_id] -> list[(neighbor_id, bond_order)]
        bond_orders: dict[(min_id, max_id)] -> bond_order (int)
    """
    atoms: Dict[int, Dict[str, str]] = {}
    neighbors: Dict[int, List[Tuple[int, int]]] = defaultdict(list)
    bond_orders: Dict[Tuple[int, int], int] = {}

    mode = None
    with open(mol2_path, "r") as f:
        for line in f:
            if line.startswith("@<TRIPOS>ATOM"):
                mode = "atom"
                continue
            if line.startswith("@<TRIPOS>BOND"):
                mode = "bond"
                continue
            if line.startswith("@<TRIPOS>"):
                # Some other section
                mode = None
                continue

            stripped = line.strip()
            if not stripped or stripped.startswith("#") or mode is None:
                continue

            parts = stripped.split()
            if mode == "atom":
                if len(parts) < 6:
                    continue
                atom_id = int(parts[0])
                atom_name = parts[1]
                # parts[2:5] are x, y, z (unused here)
                atom_type = parts[5]
                # Element is typically deduced from atom_type or first letter
                # of the type; for your file this is just one letter (C, H, N, O, S).
                element = atom_type[0].upper()
                atoms[atom_id] = {
                    "name": atom_name,
                    "type": atom_type,
                    "element": element,
                }

            elif mode == "bond":
                if len(parts) < 4:
                    continue
                a1 = int(parts[1])
                a2 = int(parts[2])
                bond_type = parts[3]
                try:
                    order = int(bond_type)
                except ValueError:
                    # 'am', 'ar', etc. — treat as single for our purposes
                    order = 1

                neighbors[a1].append((a2, order))
                neighbors[a2].append((a1, order))
                key = (a1, a2) if a1 < a2 else (a2, a1)
                bond_orders[key] = order

    return atoms, neighbors, bond_orders


def find_backbone_and_sidechain(
    atoms: Dict[int, Dict[str, str]],
    neighbors: Dict[int, List[Tuple[int, int]]],
    bond_orders: Dict[Tuple[int, int], int],
):
    """
    Identify Cα carbons, their attached hydrogens (α-H),
    Cβ carbons, and their attached hydrogens (β-H).

    Heuristic:
      1) Carbonyl carbons: C double-bonded to O.
      2) Cα: carbon that has at least one N neighbor and at least one
         carbonyl carbon neighbor.
      3) Cβ: carbon neighbors of Cα that are carbon, but not carbonyl carbons.
    """

    # 1) carbonyl carbons: C double-bonded to O
    carbonyl_carbons: Set[int] = set()
    for (i, j), order in bond_orders.items():
        if order != 2:
            continue
        ei = atoms[i]["element"]
        ej = atoms[j]["element"]
        if ei == "C" and ej == "O":
            carbonyl_carbons.add(i)
        elif ej == "C" and ei == "O":
            carbonyl_carbons.add(j)

    # 2) Cα: C connected to N and a carbonyl C
    alpha_carbons: Set[int] = set()
    for cid, info in atoms.items():
        if info["element"] != "C":
            continue
        has_N = False
        has_carbonyl_C = False
        for nb, _order in neighbors.get(cid, []):
            if atoms[nb]["element"] == "N":
                has_N = True
            if nb in carbonyl_carbons:
                has_carbonyl_C = True
        if has_N and has_carbonyl_C:
            alpha_carbons.add(cid)

    # 3) Cβ neighbors of Cα
    beta_carbons: Set[int] = set()
    for ca in alpha_carbons:
        for nb, _order in neighbors.get(ca, []):
            if (
                atoms[nb]["element"] == "C"
                and nb not in carbonyl_carbons
                and nb not in alpha_carbons
            ):
                beta_carbons.add(nb)

    # α hydrogens: H attached to Cα
    alpha_H: Set[int] = set()
    for ca in alpha_carbons:
        for nb, _order in neighbors.get(ca, []):
            if atoms[nb]["element"] == "H":
                alpha_H.add(nb)

    # β hydrogens: H attached to Cβ
    beta_H: Set[int] = set()
    for cb in beta_carbons:
        for nb, _order in neighbors.get(cb, []):
            if atoms[nb]["element"] == "H":
                beta_H.add(nb)

    # Map H id -> 'A' or 'B' (α wins if ever ambiguous)
    h_kind: Dict[int, str] = {}
    for hid in beta_H:
        h_kind[hid] = "B"
    for hid in alpha_H:
        h_kind[hid] = "A"

    return alpha_carbons, beta_carbons, alpha_H, beta_H, h_kind


def filter_data_file(
    data_in: str,
    data_out: str,
    h_kind: Dict[int, str],
):
    """
    Read NMR peaks from data_in and write only α/β hydrogens to data_out.

    Input format (per line, ignoring comments):
        ppm  weight  atom_id

    Output format:
        ppm  weight  label

    where label is "A<id>" for α and "B<id>" for β.
    """

    with open(data_in, "r") as fin, open(data_out, "w") as fout:
        for line in fin:
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                # copy comments / blank lines
                fout.write(line)
                continue

            parts = stripped.split()
            if len(parts) < 3:
                fout.write(line)
                continue

            # third column of your data is the MOL2 atom index
            try:
                atom_id = int(parts[2])
            except ValueError:
                # third column not an integer -> just copy
                fout.write(line)
                continue

            if atom_id not in h_kind:
                # not α or β hydrogen -> skip
                continue

            kind = h_kind[atom_id]  # "A" or "B"
            label = f"{kind}{atom_id}"

            # keep ppm and weight the same; replace 3rd column by label
            ppm = parts[0]
            weight = parts[1]

            # if there are extra columns, keep them as-is after the label
            extra = parts[3:]
            if extra:
                fout.write(f"{ppm} {weight} {label} {' '.join(extra)}\n")
            else:
                fout.write(f"{ppm} {weight} {label}\n")


def main():
    ap = argparse.ArgumentParser(
        description="Select α/β hydrogens from a MOL2 amino acid and \
filter the NMR data file accordingly."
    )
    ap.add_argument("data_in", help="input NMR data file (e.g. avg.dat)")
    ap.add_argument("mol2", help="MOL2 structure file")
    ap.add_argument(
        "data_out",
        help="output data file with only α/β hydrogens (e.g. avg_ab.dat)",
    )
    args = ap.parse_args()

    atoms, neighbors, bond_orders = parse_mol2(args.mol2)
    _, _, _, _, h_kind = find_backbone_and_sidechain(atoms, neighbors, bond_orders)
    if not h_kind:
        raise SystemExit("No α/β hydrogens detected — check MOL2 file.")

    filter_data_file(args.data_in, args.data_out, h_kind)


if __name__ == "__main__":
    main()
