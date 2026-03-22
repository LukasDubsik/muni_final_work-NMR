#!/usr/bin/env python3
from __future__ import annotations

import argparse
import math
import re
from pathlib import Path

VDW = {
    "H": 1.20, "C": 1.70, "N": 1.55, "O": 1.52, "S": 1.80, "P": 1.80,
    "F": 1.47, "Cl": 1.75, "Br": 1.85, "I": 1.98, "Se": 1.90, "B": 1.92,
    "Si": 2.10, "Au": 1.66, "Ag": 1.72, "Pt": 1.75, "Pd": 1.63, "Cu": 1.40,
    "Zn": 1.39, "Hg": 1.55, "Fe": 1.56, "Co": 1.52, "Ni": 1.63, "Mn": 1.61,
    "Mg": 1.73, "Ca": 2.31, "Na": 2.27, "K": 2.75,
}
ATOM_RE = re.compile(r"^([A-Za-z]+)")

def norm_elem(raw: str) -> str:
    m = ATOM_RE.match(raw.strip())
    if not m:
        raise ValueError(f"Cannot parse element from atom name {raw!r}")
    token = m.group(1)
    return token[0].upper() + token[1:].lower()

def vdw_radius(elem: str) -> float:
    return VDW.get(elem, 1.80)

def parse_xyz(path: Path):
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
    return comment, atoms

def write_xyz(path: Path, comment: str, atoms):
    with path.open('w') as fh:
        fh.write(f"{len(atoms)}\n{comment}\n")
        for elem, x, y, z in atoms:
            fh.write(f"{elem:<2s} {x:12.6f} {y:12.6f} {z:12.6f}\n")

def group_waters(solvent_atoms, source: Path):
    waters = []
    i = 0
    while i < len(solvent_atoms):
        if i + 2 >= len(solvent_atoms):
            raise ValueError(f"{source}: solvent tail is not a complete O-H-H water molecule")
        triplet = solvent_atoms[i:i+3]
        elems = [a[0] for a in triplet]
        if elems != ['O', 'H', 'H']:
            raise ValueError(f"{source}: expected O-H-H order after solute, got {elems} at solvent index {i}")
        waters.append(triplet)
        i += 3
    return waters

def min_surface_gap(oxygen_xyz, solute_atoms, use_hydrogens: bool) -> float:
    ox, oy, oz = oxygen_xyz
    best = float('inf')
    for elem, x, y, z in solute_atoms:
        if not use_hydrogens and elem == 'H':
            continue
        dx, dy, dz = ox - x, oy - y, oz - z
        d = math.sqrt(dx*dx + dy*dy + dz*dz) - vdw_radius(elem)
        if d < best:
            best = d
    return best

def parse_bool(x: str) -> bool:
    x = x.strip().lower()
    if x in {'1','true','yes','y','on'}:
        return True
    if x in {'0','false','no','n','off'}:
        return False
    raise argparse.ArgumentTypeError(f"Expected boolean, got {x!r}")

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--frames-dir', required=True)
    ap.add_argument('--solute-atoms', type=int, required=True)
    ap.add_argument('--surface-cutoff', type=float, required=True)
    ap.add_argument('--use-solute-hydrogens', type=parse_bool, default=False)
    args = ap.parse_args()

    files = sorted(Path(args.frames_dir).glob('frame_*.xyz'))
    if not files:
        raise SystemExit(f"No frame_*.xyz files found in {args.frames_dir}")

    summary = ['frame\ttotal_waters\tkept_waters\tmin_gap\tmax_gap_kept']
    for path in files:
        comment, atoms = parse_xyz(path)
        if len(atoms) < args.solute_atoms:
            raise ValueError(f"{path}: fewer atoms than solute-atoms={args.solute_atoms}")
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

        write_xyz(path, comment, solute + kept)
        kept_gaps = [g for g in gaps if g <= args.surface_cutoff]
        ming = min(gaps) if gaps else float('nan')
        maxkg = max(kept_gaps) if kept_gaps else float('nan')
        summary.append(f"{path.stem.replace('frame_','')}\t{len(waters)}\t{len(kept)//3}\t{ming:.6f}\t{maxkg:.6f}")

    Path(args.frames_dir, 'first_shell_summary.tsv').write_text('\n'.join(summary) + '\n')
    return 0

if __name__ == '__main__':
    raise SystemExit(main())