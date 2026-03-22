#!/usr/bin/env python3
"""
Trim cpptraj-preselected waters to a frame-wise first solvation shell
around the solute surface.

Operational definition used here:
- The first shell is selected using WATER OXYGEN positions.
- For each water, compute the minimum distance between its oxygen and the
  van der Waals surface of the solute:
      d_surface = min_i( |r_O - r_i| - R_vdw(i) )
- Keep the water if d_surface <= surface_cutoff.

This is intentionally surface-based rather than center-based, so it scales
better to larger, non-spherical metal complexes.

Input assumption:
- The first N solute atoms are the solute.
- The remaining atoms are waters in O-H-H order, as written by cpptraj for
  standard waters after the `closest` preselection.

The script rewrites each frame file in place and also writes a summary:
    frames/first_shell_summary.tsv
"""

from __future__ import annotations

import argparse
import math
import re
from pathlib import Path
from typing import List, Tuple

# Pragmatic van der Waals radii in Angstrom.
# The exact "surface" is heuristic anyway; this table is intended to be robust
# for organic/biological solutes and common metal complexes.
VDW = {
    "H": 1.20,
    "C": 1.70,
    "N": 1.55,
    "O": 1.52,
    "S": 1.80,
    "P": 1.80,
    "F": 1.47,
    "Cl": 1.75,
    "Br": 1.85,
    "I": 1.98,
    "Se": 1.90,
    "B": 1.92,
    "Si": 2.10,
    "Au": 1.66,
    "Ag": 1.72,
    "Pt": 1.75,
    "Pd": 1.63,
    "Cu": 1.40,
    "Zn": 1.39,
    "Hg": 1.55,
    "Fe": 1.56,
    "Co": 1.52,
    "Ni": 1.63,
    "Mn": 1.61,
    "Mg": 1.73,
    "Ca": 2.31,
    "Na": 2.27,
    "K": 2.75,
}

ATOM_RE = re.compile(r"^([A-Za-z]+)")

def norm_elem(raw: str) -> str:
    m = ATOM_RE.match(raw.strip())
    if not m:
        raise ValueError(f"Cannot parse element from atom name '{raw}'")
    token = m.group(1)
    return token[0].upper() + token[1:].lower()

def vdw_radius(elem: str) -> float:
    return VDW.get(elem, 1.80)

def parse_xyz(path: Path) -> Tuple[int, str, List[Tuple[str, float, float, float]]]:
    lines = path.read_text().splitlines()
    if len(lines) < 2:
        raise ValueError(f"{path}: not a valid XYZ file")
    natoms = int(lines[0].strip())
    comment = lines[1]
    atoms = []
    for line in lines[2:]:
        if not line.strip():
            continue
        parts = line.split()
        if len(parts) < 4:
            raise ValueError(f"{path}: malformed atom line: {line!r}")
        elem = norm_elem(parts[0])
        x, y, z = map(float, parts[1:4])
        atoms.append((elem, x, y, z))
    if len(atoms) != natoms:
        raise ValueError(f"{path}: header says {natoms} atoms but parsed {len(atoms)}")
    return natoms, comment, atoms

def write_xyz(path: Path, comment: str, atoms: List[Tuple[str, float, float, float]]) -> None:
    with path.open("w") as fh:
        fh.write(f"{len(atoms)}\n")
        fh.write(f"{comment}\n")
        for elem, x, y, z in atoms:
            fh.write(f"{elem:<2s} {x:12.6f} {y:12.6f} {z:12.6f}\n")

def group_waters(solvent_atoms: List[Tuple[str, float, float, float]], source: Path):
    waters = []
    i = 0
    n = len(solvent_atoms)
    while i < n:
        if i + 2 >= n:
            raise ValueError(f"{source}: solvent tail is not a complete OHH water molecule")
        triplet = solvent_atoms[i:i+3]
        elems = [a[0] for a in triplet]
        if elems[0] != "O" or elems[1] != "H" or elems[2] != "H":
            raise ValueError(
                f"{source}: expected solvent atoms in O-H-H order after solute, got {elems} at solvent index {i}"
            )
        waters.append(triplet)
        i += 3
    return waters

def min_surface_gap(oxygen_xyz, solute_atoms, use_hydrogens: bool) -> float:
    ox, oy, oz = oxygen_xyz
    best = float("inf")
    for elem, x, y, z in solute_atoms:
        if not use_hydrogens and elem == "H":
            continue
        dx = ox - x
        dy = oy - y
        dz = oz - z
        d = math.sqrt(dx * dx + dy * dy + dz * dz) - vdw_radius(elem)
        if d < best:
            best = d
    return best

def parse_bool(x: str) -> bool:
    v = x.strip().lower()
    if v in {"1", "true", "yes", "y", "on"}:
        return True
    if v in {"0", "false", "no", "n", "off"}:
        return False
    raise argparse.ArgumentTypeError(f"Expected boolean, got {x!r}")

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--frames-dir", required=True)
    ap.add_argument("--solute-atoms", type=int, required=True)
    ap.add_argument("--surface-cutoff", type=float, required=True)
    ap.add_argument("--use-solute-hydrogens", type=parse_bool, default=False)
    args = ap.parse_args()

    frames_dir = Path(args.frames_dir)
    files = sorted(frames_dir.glob("frame_*.xyz"))
    if not files:
        raise SystemExit(f"No frame_*.xyz files found in {frames_dir}")

    summary_lines = ["frame\ttotal_waters\tkept_waters\tmin_gap\tmax_gap_kept"]

    for path in files:
        _, comment, atoms = parse_xyz(path)
        if len(atoms) < args.solute_atoms:
            raise ValueError(
                f"{path}: contains {len(atoms)} atoms, fewer than solute-atoms={args.solute_atoms}"
            )

        solute = atoms[:args.solute_atoms]
        solvent = atoms[args.solute_atoms:]
        waters = group_waters(solvent, path)

        kept = []
        gaps = []
        for water in waters:
            oxygen = water[0]
            gap = min_surface_gap((oxygen[1], oxygen[2], oxygen[3]), solute, args.use_solute_hydrogens)
            gaps.append(gap)
            if gap <= args.surface_cutoff:
                kept.extend(water)

        new_atoms = solute + kept
        write_xyz(path, comment, new_atoms)

        frame_id = path.stem.replace("frame_", "")
        min_gap = f"{min(gaps):.6f}" if gaps else "nan"
        kept_gaps = [g for g in gaps if g <= args.surface_cutoff]
        max_gap_kept = f"{max(kept_gaps):.6f}" if kept_gaps else "nan"
        summary_lines.append(
            f"{frame_id}\t{len(waters)}\t{len(kept)//3}\t{min_gap}\t{max_gap_kept}"
        )

    (frames_dir / "first_shell_summary.tsv").write_text("\n".join(summary_lines) + "\n")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())