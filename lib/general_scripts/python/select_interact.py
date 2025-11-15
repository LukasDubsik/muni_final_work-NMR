#!/usr/bin/env python3
"""
Given a nc file from cpptraj containing the simulated trajectories, 
it selects hydrogen bonded waters to thebresidue.
"""

import sys

from pathlib import Path

import MDAnalysis as mda

from MDAnalysis.analysis.hydrogenbonds.hbond_analysis import (
    HydrogenBondAnalysis as HBA,
)

TRAJECTORY = "frames.nc"        # decimated traj from cpptraj

SOLUTE_SELECTION = "resid 1"    # solute identification
WATER_RESNAME = "WAT"           # Name of the water residues

DA_CUTOFF = 3.0                 # donor–acceptor distance (Å)
DHA_ANGLE_CUTOFF = 150.0        # D–H–A angle (degrees)

OUTDIR = Path("frames")         # where to write the resulting .xyz files


def main() -> None:
    # Check that correct number of params were provided
    if len(sys.argv) != 3:
        print(f"Usage: python {sys.argv[0]} TOPOLOGY FRAME_START_NUM")
        sys.exit(1)

    # Load the parameters of the script
    TOPOLOGY: str = sys.argv[1]
    frame_start: int = int(sys.argv[2])

    # Make sure the directory exists
    OUTDIR.mkdir(exist_ok=True)

    u = mda.Universe(TOPOLOGY, TRAJECTORY)

    # Define selections for H-bonds: solute vs water
    solute_sel = SOLUTE_SELECTION
    water_sel = f"resname {WATER_RESNAME}"

    # Hydrogen bond analysis between solute (resid 1) and water
    hbonds = HBA(
        universe=u,
        between=[solute_sel, water_sel],
        d_a_cutoff=DA_CUTOFF,
        d_h_a_angle_cutoff=DHA_ANGLE_CUTOFF,
    )
    hbonds.run()

    # What forms hydrogen bonds
    hb_array = hbonds.results.hbonds

    # For each frame prepare set to hold what waters form bonds
    frame_to_water_resids = {i: set() for i in range(len(u.trajectory))}

    # Iterate through the array and fill in the holder
    for frame, donor_ix, hydrogen_ix, acceptor_ix, dist, angle in hb_array:
        frame = int(frame)
        donor_ix = int(donor_ix)
        acceptor_ix = int(acceptor_ix)

        donor_atom = u.atoms[donor_ix]
        acceptor_atom = u.atoms[acceptor_ix]

        # Identify which side is water
        if donor_atom.resname == WATER_RESNAME:
            frame_to_water_resids[frame].add(donor_atom.resid)
        if acceptor_atom.resname == WATER_RESNAME:
            frame_to_water_resids[frame].add(acceptor_atom.resid)

    # Select the solute atoms
    solute = u.select_atoms(solute_sel)

    # Loop over frames, write XYZ file for each frame
    for ts in u.trajectory:
        frame_idx = ts.frame

        water_resids = frame_to_water_resids.get(frame_idx, set())

        if not water_resids:
            write_xyz(solute, OUTDIR / f"frame_{frame_start:05d}.xyz", comment="solute only")
            frame_start+=1
            continue

        # Build selection string for these water residues
        resid_str: str = " ".join(str(rid) for rid in sorted(water_resids))
        water: any = u.select_atoms(f"resid {resid_str} and resname {WATER_RESNAME}")

        # Combine
        cluster = solute | water

        out_file = OUTDIR / f"frame_{frame_start:05d}.xyz"
        write_xyz(
            cluster,
            out_file,
            comment=f"Frame {frame_start}, {len(water_resids)} H-bonding waters",
        )

        frame_start+=1


def write_xyz(atomgroup, filename: Path, comment: str = "") -> None:
    """Write the individual xyz files"""
    with filename.open("w") as f:
        f.write(f"{atomgroup.n_atoms}\n")
        f.write(comment + "\n")
        for atom in atomgroup:
            # Extract the coordinates
            x, y, z = atom.position
            # Write the atom name and its individual positions
            f.write(f"{atom.name:4s} {x:12.6f} {y:12.6f} {z:12.6f}\n")


if __name__ == "__main__":
    main()
