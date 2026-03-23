#!/usr/bin/env python3
"""
Trim cpptraj-preselected solvent to a frame-wise first solvation shell
around the solute surface.

Behavior:
- Waters are identified as O-H-H triplets in the solvent tail.
- Common monatomic ions in the solvent tail are ignored and discarded.
- The first shell is selected using WATER OXYGEN positions.
- For each water, compute the minimum distance between its oxygen and the
  van der Waals surface of the solute:
      d_surface = min_i( |r_O - r_i| - R_vdw(i) )
- Keep the water if d_surface <= surface_cutoff.

Input assumption:
- The first N atoms are the solute.
- After the solute, the tail may contain:
    * waters in O-H-H order
    * monatomic ions (Na, K, Cl, Mg, Ca, ...)
- Ignored ions are removed entirely from the rewritten XYZ and are not passed
  downstream to Gaussian.

The script rewrites each frame file in place and writes:
    frames/first_shell_summary.tsv
"""

from __future__ import annotations

import argparse
import math
import re
from pathlib import Path
from typing import List, Tuple

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

# Common monatomic ions to discard from the solvent tail.
IGNORED_ION_ELEMENTS = {
    "Li", "Na", "K", "Rb", "Cs",
    "Mg", "Ca", "Sr", "Ba",
    "Zn", "Cd",
    "Cl", "Br", "I", "F",
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

def split_solvent_tail(solvent_atoms: List[Tuple[str, float, float, float]], source: Path):
    """
    Parse solvent tail into:
      - waters as O-H-H triplets
      - ignored monatomic ions
    Anything else is treated as an error to avoid silently corrupting the model.
    """
    waters = []
    ignored_ions = []

    i = 0
    n = len(solvent_atoms)

    while i < n:
        elem = solvent_atoms[i][0]

        # Water in O-H-H order
        if elem == "O":
            if i + 2 >= n:
                raise ValueError(f"{source}: incomplete water at solvent index {i}")
            e1 = solvent_atoms[i + 1][0]
            e2 = solvent_atoms[i + 2][0]
            if e1 == "H" and e2 == "H":
                waters.append(solvent_atoms[i:i+3])
                i += 3
                continue
            raise ValueError(
                f"{source}: expected O-H-H water after solute, got ['O', '{e1}', '{e2}'] at solvent index {i}"
            )

        # Monatomic counterion or spectator ion: discard it
        if elem in IGNORED_ION_ELEMENTS:
            ignored_ions.append(solvent_atoms[i])
            i += 1
            continue

        raise ValueError(
            f"{source}: unsupported non-water species in solvent tail starting at solvent index {i}: {elem}"
        )

    return waters, ignored_ions

def parse_box(comment: str):
    """
    Extract orthorhombic box lengths from a cpptraj XYZ comment line of the form:
        ... Box X: Lx 0.000 0.000 Y: 0.000 Ly 0.000 Z: 0.000 0.000 Lz
    Returns (Lx, Ly, Lz) as floats, or None if the comment does not match.
    Only orthorhombic boxes (off-diagonal elements zero) are handled; triclinic
    boxes are not supported and will fall back to no-PBC behaviour.
    """
    import re as _re
    m = _re.search(
        r"Box X:\s*([\d.eE+\-]+)\s+([\d.eE+\-]+)\s+([\d.eE+\-]+)"
        r"\s+Y:\s*([\d.eE+\-]+)\s+([\d.eE+\-]+)\s+([\d.eE+\-]+)"
        r"\s+Z:\s*([\d.eE+\-]+)\s+([\d.eE+\-]+)\s+([\d.eE+\-]+)",
        comment,
    )
    if not m:
        return None
    vals = [float(m.group(i)) for i in range(1, 10)]
    # vals layout: Lx xy xz | yx Ly yz | zx zy Lz
    Lx, Ly, Lz = vals[0], vals[4], vals[8]
    # Require orthorhombic (off-diagonals must be ~0)
    off_diag = [vals[1], vals[2], vals[3], vals[5], vals[6], vals[7]]
    if any(abs(v) > 1e-3 for v in off_diag):
        return None
    return (Lx, Ly, Lz)

def _mic_sq(dx: float, dy: float, dz: float, box) -> float:
    """Squared distance under minimum image convention for orthorhombic box."""
    if box is not None:
        Lx, Ly, Lz = box
        dx -= Lx * round(dx / Lx)
        dy -= Ly * round(dy / Ly)
        dz -= Lz * round(dz / Lz)
    return dx * dx + dy * dy + dz * dz

def min_surface_gap(oxygen_xyz, solute_atoms, use_hydrogens: bool, box=None) -> float:
    ox, oy, oz = oxygen_xyz
    best = float("inf")
    for elem, x, y, z in solute_atoms:
        if not use_hydrogens and elem == "H":
            continue
        dx = ox - x
        dy = oy - y
        dz = oz - z
        d = math.sqrt(_mic_sq(dx, dy, dz, box)) - vdw_radius(elem)
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

    summary_lines = [
        "frame\ttotal_waters\tkept_waters\tignored_ions\tmin_gap\tmax_gap_kept"
    ]

    for path in files:
        _, comment, atoms = parse_xyz(path)
        if len(atoms) < args.solute_atoms:
            raise ValueError(
                f"{path}: contains {len(atoms)} atoms, fewer than solute-atoms={args.solute_atoms}"
            )

        solute = atoms[:args.solute_atoms]
        solvent = atoms[args.solute_atoms:]

        box = parse_box(comment)

        waters, ignored_ions = split_solvent_tail(solvent, path)

        kept = []
        gaps = []
        for water in waters:
            oxygen = water[0]
            gap = min_surface_gap(
                (oxygen[1], oxygen[2], oxygen[3]),
                solute,
                args.use_solute_hydrogens,
                box,
            )
            gaps.append(gap)
            if gap <= args.surface_cutoff:
                kept.extend(water)

        # Ions are intentionally discarded here.
        new_atoms = solute + kept
        write_xyz(path, comment, new_atoms)

        frame_id = path.stem.replace("frame_", "")
        min_gap = f"{min(gaps):.6f}" if gaps else "nan"
        kept_gaps = [g for g in gaps if g <= args.surface_cutoff]
        max_gap_kept = f"{max(kept_gaps):.6f}" if kept_gaps else "nan"

        summary_lines.append(
            f"{frame_id}\t{len(waters)}\t{len(kept)//3}\t{len(ignored_ions)}\t{min_gap}\t{max_gap_kept}"
        )

    (frames_dir / "first_shell_summary.tsv").write_text("\n".join(summary_lines) + "\n")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())