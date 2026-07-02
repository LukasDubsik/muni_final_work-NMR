# Deep Documentation of the NMR Simulation Pipeline

This document describes the scientific and computational meaning of the pipeline as implemented in the uploaded Bash, Amber, cpptraj, Gaussian, MCPB.py, and Python helper files. It is written as a walk-through of what happens, when it happens, why the step exists scientifically, which files control it, what the important parameters mean, and what is actually being simulated in the example configuration.

The pipeline is best understood as a staged molecular-modelling workflow:

1. **Start from a chemically defined structure** in MOL2 format.
2. **Generate a physically reasonable conformer/geometry** with xTB/CREST, while preserving the original MOL2 connectivity as authoritative.
3. **Assign classical force-field parameters** for the organic part using GAFF2/Amber tools.
4. **Generate metal-center parameters** with MCPB.py and Gaussian where a heavy metal is present.
5. **Build a solvated Amber topology** with tLEaP, explicit OPC3 water, optional custom parameters, and counterions.
6. **Relax and equilibrate the solvated system** through minimization, heating, pressure equilibration, and production MD.
7. **Extract representative frames** from the MD trajectories with cpptraj.
8. **Reduce or embed the solvent environment** for Gaussian NMR calculations, depending on the selected water mode.
9. **Run Gaussian NMR calculations** on the extracted frames.
10. **Convert magnetic shieldings to chemical shifts**, average/smooth them, and plot final spectra.
11. **Archive the complete process directory** into a final results folder.

The example `sim.txt` config describes a calculation for `di_cys_gold1`, with total molecular/system solute charge `-1`, formal metal charge `+1`, 100 Gaussian frames, 5 independent MD iterations, explicit OPC3 water during Amber MD, `cpptraj_solvation` frame extraction, and first-shell waters passed to Gaussian as point charges.

---

## 1. Source File Map

### Main control and shell libraries

| File | Role |
|---|---|
| `nmr.sh` | Main driver. Reads config, runs preparation, simulation, frame extraction, Gaussian NMR, analysis, plotting, and final archiving. |
| `input_handling.sh` | Reads `inputs/sim.txt`, validates expected templates, stores configuration into globals, counts solute atoms from the MOL2 file. |
| `modules.sh` | Optional module/command checks for Amber, Gaussian, Open Babel, CREST, pmemd, cpptraj, etc. |
| `jobs.sh` | Submits jobs to either MetaCentrum/PBS or Wolf/psubmit and waits for completion. |
| `file_modification.sh` | Substitutes names into templates, builds job scripts, patches MD and Gaussian runtime scripts, enforces safe heating settings, and forces cpptraj XYZ output where required. |
| `utilities.sh` | Large chemical/file utility library: MOL2 editing, metal detection, MCPB/tLEaP cleanup, atom typing, charge rebalancing, metal-bond filtering, special Se/Si handling, and Amber topology validation in the fixed version. |
| `preparations.sh` | Preparation-stage workflow: CREST, antechamber, parmchk2, MCPB.py, Open Babel normalization, and tLEaP topology construction. |
| `simulation.sh` | Amber minimization, heating, equilibration, production MD, cpptraj extraction, and frame postprocessing. |
| `simulation_parallel.sh` | Parallelizes repeated simulation/cpptraj runs across `run_0`, `run_1`, etc. |
| `gauss.sh` | Converts extracted XYZ frames into Gaussian inputs and submits one Gaussian NMR job per frame. |
| `data.sh` | Reads Gaussian logs, handles optional automatic TMS reference, produces numerical NMR data and final plots. |
| `output.sh`, `logging.sh`, `info.sh` | Console messages, deprecated no-op logging compatibility, and optional email notification support. |

### Amber/tLEaP/cpptraj/Gaussian templates

| File | Role |
|---|---|
| `tleap.in` | General tLEaP template: loads custom force fields, loads ligand MOL2/frcmod, solvates in OPC3 water, neutralizes, saves Amber topology. |
| `tleap_spec.in` | Similar to `tleap.in`, but explicitly adds a custom selenium atom type. Used by the example `sim.txt`. |
| `mcpb.in` | Simple MCPB.py input template. The current code mostly writes MCPB input dynamically instead of relying only on this file. |
| `opt_water.in` | Amber minimization with solute heavy atoms restrained; intended to relax water around a fixed solute. |
| `opt_all.in` | Amber minimization of the full system without restraints. |
| `opt_temp.in` | Amber heating from low temperature to 300 K under constant volume. |
| `opt_pres.in` | Amber pressure equilibration at 300 K and 1 atm. |
| `md.in` | Main production MD template used by the example configuration. |
| `md_long.in` | Optional 20 ns longer production MD template. Not selected in the example config. |
| `md_gamd.in` | Optional GaMD template for dual-boost accelerated sampling. Not selected in the example config. |
| `md_qmmm.in` | Optional QM/MM MD template using external Gaussian QM. Not selected in the example config. |
| `cpptraj.in` | Extract solute only. |
| `cpptraj_all.in` | Extract residues `:1-2`. Usually useful when the metal is a second residue. |
| `cpptraj_all_di.in` | Extract residues `:1-3`, useful for larger multi-residue complexes. |
| `cpptraj_water.in` | Use cpptraj `closest 20` waters around atom range `@1-${limit}`. |
| `cpptraj_solvation.in` | Write all solvent to XYZ first; exact first-shell selection is later done per frame in Python. Used by the example config. |
| `gau_job.tpl` | Minimal Gaussian route template: B3LYP/6-31G(d,p) with XQC-style SCF stabilization. The actual Gaussian frame input is generated by `xyz_to_gfj.sh`, which was not among the uploaded files. |

### Python postprocessing

| File | Role |
|---|---|
| `select_first_shell_surface.py` | Reads split XYZ frames, identifies waters as O-H-H triplets after the solute atoms, removes ions, and keeps waters whose oxygen lies within a defined van der Waals surface gap of the solute. |
| `select_interact.py` | Alternative MDAnalysis workflow: identifies waters hydrogen-bonded to the solute using geometric H-bond criteria and writes solute + interacting waters. |

---

## 2. What the Example Configuration Is Asking the Pipeline To Simulate

The uploaded `sim.txt` is the concrete experiment definition. In plain language, it asks for:

- Molecule/input name: `di_cys_gold1`.
- Final save folder label: `di_cys_gold1_sh`.
- Input type: `mol2`, meaning the pipeline should do parameter generation rather than assume an existing Amber `parm7/rst7` pair.
- Custom parameters enabled with `params:=yes`, meaning files such as `leaprc.zf`, `gaff.zf`, and `frcmod.si_tms` are expected in `inputs/params` and are copied into the tLEaP work directory.
- Total solute charge: `-1`.
- Metal formal charge: `+1`.
- Metal parameterization: MCPB enabled with `mcpb :=-s 4`, so the intended full MCPB workflow is to proceed through parameter generation.
- Water model for classical MD: OPC3, because the tLEaP templates source `leaprc.water.opc3` and solvate with `OPC3BOX`.
- MD repetition: `md_iterations:=5`, meaning the pipeline creates five independent run directories, `run_0` through `run_4`.
- Gaussian frame count: `num_frames:=100`. Since the driver requires `num_frames` divisible by `md_iterations`, each run contributes `100/5 = 20` frames.
- Production MD template: `md:=md`, i.e. use `md.in`, not the long/GaMD/QM/MM alternatives.
- cpptraj extraction template: `cpptraj:=cpptraj_solvation`, meaning cpptraj writes a full solvent-containing XYZ stream first, and Python later does exact first-shell trimming.
- cpptraj mode: `no_water`. The name is slightly misleading here: in this pipeline branch it means the output is handled as split XYZ frames rather than an MDAnalysis `frames.nc` hydrogen-bond workflow. With `cpptraj_solvation`, waters are present initially and later trimmed by `select_first_shell_surface.py`.
- Solvent treatment in Gaussian: `water_mode:=point_charges`, meaning first-shell waters are not necessarily treated as full QM atoms; their charges can instead be embedded as Gaussian point charges using oxygen/hydrogen charges from config.
- Point-charge water values: oxygen `-0.834`, hydrogen `+0.417`. These are TIP3P-like charges, even though the classical MD solvent is OPC3; that distinction matters scientifically and is discussed below.
- First-shell geometric selector: oxygen-to-solute van der Waals surface gap cutoff `1.8 Å`; solute hydrogens ignored in the surface distance computation.
- NMR reference shift parameter: `sigma:=32.2`, so this run uses a fixed shielding reference rather than automatically computing TMS, unless the config is changed to `sigma:=auto` or left empty.

Scientifically, this is a **snapshot-averaged NMR shielding/chemical-shift workflow** for a gold-containing cysteine-like complex in water. The solute is dynamically sampled in explicit water by Amber. Then selected MD snapshots are converted into Gaussian NMR calculations. The solvent environment around each snapshot is not ignored entirely: the MD water shell can be included as point charges, full QM atoms, or discarded depending on `water_mode`.

---

## 3. Top-Level Execution Logic (`nmr.sh`)

The main script starts in strict Bash mode: `set -Eeuo pipefail` plus `lastpipe`. This is important because missing variables, failed commands, and failed pipeline elements terminate the run. A trap prints the failing line and exit code.

The driver then sources all function libraries and job-generation libraries. The main execution order is:

```text
read_config
load_cfg
check_cfg
get_number_of_atoms
optional module checks
final-result guard
preparation stages if input_type == mol2
create process/spectrum/frames
validate num_frames % md_iterations == 0
parallel opt_water
parallel opt_all
parallel opt_temp
parallel opt_pres
parallel md
parallel cpptraj
Gaussian input preparation
Gaussian NMR jobs
analysis
plotting
archive process/ into data_results/save_as
clean process/
```

The scientific meaning of that ordering is deliberate:

1. **Parameterization must happen before MD.** Amber cannot simulate a new solute unless it has atom types, partial charges, bonded parameters, nonbonded parameters, and a topology.
2. **Water must be relaxed before heating.** A solvated box built by tLEaP can contain steric contacts, poor water orientations, and local strain.
3. **The solute/water system is heated before pressure equilibration.** The temperature is brought to 300 K under a safer initial setup before NPT density/pressure relaxation.
4. **Production sampling happens only after minimization, heating, and pressure stabilization.** Only these production frames feed Gaussian NMR.
5. **Gaussian calculations are independent per frame.** This makes them parallelizable and allows recovery/resume logic.
6. **Final spectra are statistical products.** The output is not one static optimized structure; it is an averaged ensemble of shieldings/chemical shifts from MD snapshots.

The script writes everything intermediate under `process/` and finally copies the entire process tree into `data_results/${save_as}`. That means the final folder is not just a spectrum; it is also a provenance archive containing preparation, topology, MD, cpptraj, Gaussian logs, analysis data, and plots.

---

## 4. Configuration Reading and Meaning (`input_handling.sh`)

The config parser is intentionally simple. It reads `inputs/sim.txt`, ignores blank lines and lines beginning with `#`, and treats every line containing `:=` as a key-value assignment. The key is stripped of whitespace; the value is kept essentially as written.

The most important loaded variables are:

| Variable | Scientific/computational meaning |
|---|---|
| `name` | Base molecule name. All inputs and generated outputs use this prefix. |
| `save_as` | Final results directory label. |
| `input_type` | `mol2` triggers parameterization; `7` would mean a pre-existing Amber topology/restart workflow. |
| `params` | Whether custom parameter files are copied into tLEaP. |
| `num_frames` | Number of Gaussian NMR snapshots to average. |
| `charge` | Net charge of the solute/model used for charge assignment and Gaussian input generation. |
| `metal_charge` | Formal oxidation/charge state of the detected metal ion for MCPB charge bookkeeping. |
| `md_iterations` | Number of independent MD replicas/runs. |
| `tleap`, `opt_water`, `opt_all`, `opt_temp`, `opt_pres`, `md`, `cpptraj` | Names of template files in `inputs/simulation/` without `.in`. |
| `water_mode` | How waters are represented in Gaussian: discarded, point charges, or full QM atoms. |
| `shell_surface_cutoff` | First-shell cutoff measured from water oxygen to solute van der Waals surface. |
| `shell_use_solute_hydrogens` | Whether solute hydrogens participate in the surface-distance calculation. |
| `water_oxygen_charge`, `water_hydrogen_charge` | Point-charge embedding values for Gaussian when `water_mode=point_charges`. |
| `sigma` | Shielding reference value for converting absolute shieldings to chemical shifts, unless automatic TMS reference is requested. |

The pipeline also computes `LIMIT` by reading the atom count from the starting MOL2 file. `LIMIT` is scientifically important because it defines the solute atom range. Later, cpptraj and Python assume that the first `LIMIT` atoms in the XYZ frames are the solute and that everything after those atoms is solvent/counterions.

That assumption is central to the whole solvent-shell workflow. If atom ordering changes so that solvent atoms appear before the solute, or if multiple solute residues are not counted as expected, the first-shell selector will trim the wrong atoms.

---

## 5. Preparation Stage Overview

The preparation phase transforms an input `name.mol2` into a solvated Amber `name.parm7`/`name.rst7` pair. Conceptually, it answers these questions:

1. What geometry/conformer should be simulated?
2. What are the atom types and charges of the organic ligand?
3. If a metal exists, what are the metal-ligand bonded parameters?
4. How should special atoms such as selenium and silicon be represented?
5. How should water and ions be added?
6. Is the final topology internally consistent enough to start MD?

The major steps are:

```text
run_crest
run_antechamber
run_parmchk2
run_mcpb
run_nemesis_fix
run_tleap
```

Each step writes into `process/preparations/<step>/` and uses `.ok` stamps to support resuming. A step is skipped only if its `.ok` marker and required outputs are present.

---

## 6. CREST/xTB Geometry and Conformer Preparation (`run_crest`)

### What it does computationally

`run_crest` starts from `inputs/structures/${name}.mol2` and converts it to XYZ using Open Babel. Since XYZ has coordinates but no bond table, the pipeline later writes the final CREST coordinates back into a MOL2 file using the original MOL2 connectivity as authoritative.

Before CREST proper, the code attempts an xTB pre-optimization:

```text
xtb ${name}.xyz --opt loose --alpb water -c <charge> --T 4
```

The comments explain that this is especially useful for heavy chalcogens such as Se and Te. Raw MOL2 geometries can be too strained for CREST’s internal trial optimization, so a loose xTB relaxation reduces the risk of CREST failing before conformer search begins.

After xTB preoptimization, the pipeline submits a CREST job. CREST output `crest_best.xyz` is then merged with the original MOL2 bond graph. This is a crucial design choice:

- CREST/XYZ gives improved coordinates.
- The original MOL2 gives the intended covalent/coordination connectivity.
- The pipeline refuses to let distance-based XYZ-to-MOL2 perception invent or erase important bonds.

### Scientific meaning

This step is a **semiempirical conformer/geometry preparation step**. xTB/CREST does not define the final force field. It prepares a chemically plausible starting geometry, likely in an implicit water-like environment (`--alpb water`). For flexible cysteine/gold complexes, the local arrangement of cysteine side chains, metal coordination, and hydrogen-bond donors/acceptors can strongly influence later MD and NMR shieldings. CREST helps avoid starting MD from an arbitrary or highly strained structure.

### Important limitation

The CREST result is not treated as final quantum truth. It is only the initial geometry fed into classical force-field parameterization and Amber MD. Once Amber begins, the dynamics follow the Amber/MCPB force field, not xTB.

---

## 7. Antechamber Organic-Ligand Typing (`run_antechamber`)

### What it does

`run_antechamber` prepares GAFF/GAFF2-style ligand atom typing and charges. If the molecule contains a metal, the code first strips the metal from the MOL2 before feeding it to antechamber.

That design exists because antechamber is good for ordinary organic/small-molecule atom types but not for transition-metal coordination chemistry. In a metal complex, the organic ligand and the metal center are parameterized by different tools:

- **Antechamber/GAFF2**: organic ligand atom types.
- **MCPB.py/Gaussian**: metal atom type, metal-ligand bonded parameters, and metal-related charge handling.

When a metal is detected, the code preserves a full metal-containing MOL2 as `${name}_crest_full.mol2`, makes a metal-stripped ligand-only MOL2, and modifies the antechamber command to avoid generating new charges for the metal system:

```text
-c dc -dr no
```

In your config, the user-level antechamber command is:

```text
-c bcc -at gaff2 -dr no
```

but the metal workflow removes the charge-generation part and replaces it with dummy charges where appropriate, because MCPB later controls charge treatment for the metal-containing system.

After antechamber, the script preserves raw typing for `parmchk2`, then applies custom downstream retagging for selenium and silicon analogues. This matters because standard GAFF typing may not preserve the desired custom atom types for selenium-containing cysteine analogues or silicon/TMS reference-like structures.

### Scientific meaning

This stage creates a **classical molecular mechanics description of the organic ligand framework**: atom types, partial charges or placeholders, and connectivity. It is not yet the final complete metal-complex force field.

### Why metal stripping is important

If the metal remained in antechamber, the organic atom typing could fail or generate chemically nonsensical parameters. Transition metals require special treatment because metal-ligand bonds have coordination geometry, partial covalency, nonstandard equilibrium lengths, and force constants not present in ordinary GAFF.

---

## 8. Parmchk2 Missing Parameter Detection (`run_parmchk2`)

`parmchk2` takes the ligand MOL2 and generates an frcmod file containing missing or estimated GAFF/GAFF2 parameters. In the metal workflow, the metal is stripped before parmchk2, while the full metal-containing MOL2 is preserved for MCPB.

The resulting `${name}.frcmod` contains ligand-side bonded/nonbonded corrections required by tLEaP. If parmchk2 produces an empty file, the code creates a minimal frcmod stub with Amber section headers. This avoids downstream MCPB/tLEaP crashes caused by a missing or malformed frcmod.

Scientifically, this step fills gaps in the organic ligand force field. For ordinary bonds/angles/dihedrals, GAFF/GAFF2 can often provide reasonable parameters. For metal-ligand terms, the pipeline relies on MCPB, not parmchk2.

---

## 9. MCPB.py Metal-Center Parameterization (`run_mcpb`)

This is the most chemically specialized part of the pipeline.

### 9.1 Why MCPB is needed

Amber force fields do not automatically know how to represent a gold coordination center. A gold complex may contain Au-C, Au-S, Au-Se, Au-N, or other coordination bonds with equilibrium lengths and stiffnesses that differ strongly from normal organic covalent bonds. MCPB.py is used to derive metal-center parameters, typically through a quantum-mechanical model and Seminario-style bonded parameter extraction.

For the previous Au-Se issue, this is exactly the critical stage: the original MOL2 bond table contained both Au-C and Au-Se connectivity, MCPB recognized it, but the production tLEaP script originally failed to carry the Se-Au bond into the final Amber topology. The fixed generator must preserve all authoritative metal-ligand bonds.

### 9.2 Input preparation

The code detects the first metal atom in the MOL2, extracts:

- metal atom ID,
- element symbol,
- charge,
- coordinates.

It writes an MCPB-friendly PDB where:

- residue 1 is `LIG`, the ligand,
- residue 2 is the metal residue, e.g. `AU`,
- element symbols are right-justified in PDB columns 77-78 because MCPB/pymsmt uses them.

It also writes:

- `LIG.mol2`: ligand-only MOL2,
- `AU.mol2` or equivalent: single-ion metal MOL2,
- `LIG.frcmod`: ligand frcmod from parmchk2.

### 9.3 Charge bookkeeping

The metal charge is resolved in this priority order:

1. explicit `metal_charge` from config,
2. meaningful integer-like charge in the MOL2 metal atom,
3. fallback from total charge minus ligand charge.

Your config explicitly states:

```text
charge := -1
metal_charge := 1
```

Therefore, the ligand model target charge becomes:

```text
ligand charge = total charge - metal charge = -1 - (+1) = -2
```

The code rebalances the ligand MOL2 total charge to that target before MCPB. This is scientifically important because charge inconsistency between ligand, metal, and total system will distort RESP/MK charge fitting, electrostatics, and eventually NMR snapshots.

### 9.4 Authoritative metal-ligand connectivity

The code builds an `add_bonded_pairs` line from the authoritative full MOL2 bond table:

```text
add_bonded_pairs <metal_id>-<ligand_atom_id> ...
```

This is necessary because MCPB sometimes infers metal coordination by distance. Distance-based inference can add unwanted metal bonds, or, if not explicitly guided, fail to represent an intended bond. The pipeline uses the MOL2 connectivity as the single source of truth for which atoms are actually coordinated to the metal.

For a gold-selenium complex, the intended connectivity must include both Au-C and Au-Se if both are present in the starting chemistry.

### 9.5 MCPB stage 1: generate QM inputs

MCPB `-s 1` creates Gaussian input files such as:

- `${name}_small_opt.com`,
- `${name}_small_fc.com`,
- possibly `${name}_large_mk.com`.

The small model is used for geometry optimization and frequency/force-constant information. The large model is commonly used for electrostatic potential / charge-related treatment.

The code dynamically writes an MCPB input using:

```text
original_pdb ${name}_mcpb.pdb
group_name ${name}
cut_off 2.8
force_field ff19SB
ion_ids ${metal_id}
add_bonded_pairs ...
ion_mol2files ${metal_elem}.mol2
naa_mol2files LIG.mol2
frcmod_files LIG.frcmod
large_opt 0
smmodel_chg ${total_charge}
lgmodel_chg ${total_charge}
```

The uploaded standalone `mcpb.in` expresses the same basic MCPB concepts: original PDB, group name, cutoff, ion IDs, ion MOL2, ligand MOL2, ligand frcmod, and `large_opt 0`.

### 9.6 MCPB stage 2: Gaussian quantum calculations

MCPB-generated Gaussian inputs are patched before running. For Au systems, the code modifies Gaussian route lines to use more stable settings, removes solvent SCRF for MCPB RESP/MCPB stage-2 gas-phase ESP treatment, enforces SCF stabilization, and sets up heavy-element basis/ECP handling. In particular, the code includes Au-specific logic to convert route lines to `GenECP`/`Pseudo=Cards` and to add or normalize SDD-like ECP sections.

The stage-2 job runs:

- large-model MK/ESP calculation if present,
- small-model optimization,
- small-model force constant/frequency calculation.

The wrapper monitors Gaussian progress by checking output size, RWF size, checkpoint size, and CPU activity. It can kill apparently hung jobs after repeated idle checks. It does not immediately hard-fail after a problematic small optimization; it attempts the force-constant job as well, then lets the driver decide whether logs are usable.

### 9.7 MCPB stage 3/4: parameter extraction

MCPB then produces:

- `${name}_mcpbpy.frcmod`, containing metal-center force-field parameters,
- `${name}_mcpbpy.pdb`, with MCPB atom naming/typing,
- optional `.lib`, `.off`, `.mol2`, `.dat` helper files,
- MCPB tLEaP input containing metal atom type definitions, parameter loads, and bond commands.

In the Selene/Au-Se context, MCPB may assign atom types such as:

```text
M1 = metal center type, e.g. Au
Y2 = metal-bound carbon atom type
Y3 = metal-bound selenium atom type
```

and parameters such as:

```text
Y2-M1
Y3-M1
M1-Y2-nh
M1-Y3-c3
Y2-M1-Y3
```

Those are the terms that keep Au-C and Au-Se coordination geometrically meaningful during Amber MD.

### 9.8 Scientific meaning of MCPB parameters

MCPB turns quantum-mechanical information about a metal binding site into a classical approximation usable in Amber. It is still classical MD after this point: the metal-ligand bonds are harmonic terms with force constants/equilibrium lengths, not dynamic electronic bonds. But those parameters are derived from QM calculations, so they can approximate the local stiffness and geometry of the metal site better than generic GAFF.

---

## 10. Open Babel Normalization / “Nemesis Fix” (`run_nemesis_fix`)

After antechamber and MCPB preparation, `run_nemesis_fix` runs Open Babel on the charge-fixed MOL2 and then normalizes the result. The comments state that Open Babel can rewrite MOL2 metadata and custom atom types, so the code explicitly restores downstream custom typing for selenium and silicon analogues.

Scientifically, this step is not a new model. It is a file-format stabilization stage. It tries to make the MOL2 acceptable to tLEaP while preserving the chemical identity required by the force-field patches.

Potentially dangerous behavior is also why the pipeline keeps the CREST MOL2 as the authoritative connectivity reference. File conversion tools can perceive bonds from distances, rename atoms, or change atom types. The code therefore tries to distinguish:

- **coordinates**, which may be updated by geometry tools,
- **connectivity**, which should remain chemically authoritative,
- **atom types**, which must match the force field and MCPB parameters.

---

## 11. tLEaP System Construction (`run_tleap` and `tleap*.in`)

### 11.1 Basic tLEaP template behavior

The uploaded tLEaP template does the following:

```text
source ./leaprc.zf
source leaprc.water.opc3
loadAmberParams frcmod.si_tms
loadamberparams ${name}.frcmod
SYS = loadmol2 ${name}_charges_fix.mol2
check SYS
solvatebox SYS OPC3BOX 20.0 iso
addIons SYS Na+ 0
saveamberparm SYS ${name}.parm7 ${name}.rst7
savepdb SYS sys_leap.pdb
quit
```

The `tleap_spec.in` variant also adds a selenium atom type:

```text
addAtomTypes { { "se" "Se" "sp3" } }
```

### 11.2 Scientific meaning of the tLEaP stage

tLEaP constructs the explicit-solvent classical simulation system. It combines:

- solute topology and coordinates,
- ligand parameters from antechamber/parmchk2,
- custom selenium/silicon/TMS parameters,
- MCPB metal-center parameters if present,
- OPC3 water model,
- counterions to neutralize the system,
- periodic box coordinates.

The command:

```text
solvatebox SYS OPC3BOX 20.0 iso
```

places the system in an isotropic OPC3 water box with approximately 20 Å padding around the solute. This means the final Amber `parm7/rst7` describes not just the molecule, but molecule + explicit water + added sodium ions.

The command:

```text
addIons SYS Na+ 0
```

neutralizes the system with sodium ions. Since the solute total charge is `-1`, neutralization should add one `Na+`, unless the existing system or residues already alter net charge.

### 11.3 MCPB import into tLEaP

When MCPB output is present, `run_tleap` imports MCPB-generated loads and bond commands. It extracts:

- `loadAmberParams` / `loadmol2` / `loadpdb` / `loadoff` statements,
- explicit `bond` / `addBond` commands,
- MCPB atom type definitions.

It also filters MCPB-generated metal bonds against the authoritative MOL2 connectivity. This is scientifically important: MCPB can infer coordination from geometry, but the pipeline wants the original MOL2 bond table to define true metal connectivity.

For the Au-Se issue, the fixed generator must perform two things simultaneously:

1. Preserve the intended metal-ligand bonds from the authoritative MOL2, including Au-Se.
2. Avoid carrying over spurious extra metal bonds that MCPB may have inferred only from distance.

### 11.4 Why the Au-Se bug happened

The diagnosed failure mode was:

- The original MOL2 contained an Au-Se bond.
- MCPB saw and parameterized the Au-Se interaction.
- The production tLEaP script only had `bond mol.1.C1 mol.2.AU` and did not include `bond mol.1.SE28 mol.2.AU`.
- The final Amber topology had Au-C but no Au-Se.
- MD therefore allowed selenium to drift far away from gold.

The root technical issue was atom-name mapping across formats. In the authoritative MOL2, selenium could be named something like `Se284`, while PDB/tLEaP atom names are typically limited to four characters, e.g. `SE28`. A naive exact-name comparison misses the match. The fixed logic canonicalizes atom names into tLEaP/PDB-safe four-character names before matching and emits bond commands using the actual PDB/tLEaP atom names.

### 11.5 Topology validation gate in the fixed generator

The fixed generator adds a final validation idea: every metal-ligand bond present in the authoritative MOL2 should also exist in the final Amber `parm7`. This catches silent failures before MD.

Scientifically, this matters because a missing metal-ligand bond does not necessarily crash Amber. Amber will happily simulate the atoms as nonbonded particles, but the chemistry is wrong. A final topology validation gate turns this from a hidden scientific error into an explicit pipeline failure.

---

## 12. Simulation Layout and Replica Logic

After tLEaP, the driver creates multiple independent run directories:

```text
process/run_0/
process/run_1/
process/run_2/
process/run_3/
process/run_4/
```

Each run follows the same sequence:

```text
opt_water → opt_all → opt_temp → opt_pres → md → cpptraj
```

The five runs are parallelized by `simulation_parallel.sh`, with a maximum of 10 concurrent local wrapper processes. Since `md_iterations=5`, all five runs can be launched in parallel from the driver’s perspective, though actual cluster scheduling depends on PBS/psubmit.

Scientifically, the repeated runs are independent or semi-independent samples of the same thermodynamic system. They all start from the same tLEaP system unless additional randomization occurs during heating. The heating step forces `ig=-1`, so the Langevin random seed is randomized, helping replicas diverge.

### Frame allocation

The driver requires:

```text
num_frames % md_iterations == 0
```

For the example:

```text
100 frames / 5 runs = 20 frames per run
```

The production MD template writes coordinates every `ntwx=5000` steps. With `dt=0.001 ps`, that is:

```text
5000 × 0.001 ps = 5 ps per written MD frame
```

The `cpptraj_solvation.in` template reads every 10th trajectory frame:

```text
trajin ${name}_md.mdcrd 1 last 10
```

So Gaussian snapshots are separated by roughly:

```text
10 × 5 ps = 50 ps
```

For a 1 ns production run, this gives about 20 snapshots per run, exactly matching the requested 100 frames across 5 runs.

---

## 13. Amber Minimization Stage 1: Water-Only Relaxation (`opt_water.in`)

### Template parameters

```text
imin=1
maxcyc=2000
ncyc=500
ntb=1
cut=9.0
ntc=1
ntf=1
ntr=1
restraint_wt=10.0
restraintmask=':1 & !@H='
ntpr=25
```

### What it simulates

This is an energy minimization, not dynamics. `imin=1` means Amber minimizes the potential energy. The system is non-periodic/constant-volume style with `ntb=1`, and a 9 Å cutoff is used.

The restraint mask:

```text
:1 & !@H=
```

means heavy atoms of residue 1 are restrained. In your pipeline, residue 1 is expected to be the solute/ligand. Therefore, this stage mainly allows water molecules and ions to move away from bad contacts while keeping the solute heavy-atom scaffold near its starting geometry.

The harmonic restraint weight is `10.0 kcal mol^-1 Å^-2`. This is a fairly strong positional restraint, appropriate for solvent relaxation.

### Scientific purpose

When tLEaP solvates a molecule, it packs water around a static solute. Some waters may be too close to the solute or ions. Direct heating from that geometry can create huge forces and unstable MD. Water-only minimization removes these local clashes while preserving the chemically prepared solute geometry.

---

## 14. Amber Minimization Stage 2: Full-System Relaxation (`opt_all.in`)

### Template parameters

```text
imin=1
maxcyc=2000
ncyc=500
ntb=1
cut=9.0
ntc=1
ntf=1
ntpr=25
```

### What it simulates

This is also energy minimization, but without solute restraints. Now all atoms can move to reduce potential energy.

`maxcyc=2000` gives up to 2000 minimization cycles. `ncyc=500` usually means the first 500 cycles use steepest descent and later cycles use conjugate gradient minimization.

### Scientific purpose

After water clashes are relieved, the solute itself can adjust slightly within the solvent box. This relaxes remaining bad contacts and prepares the system for stable finite-temperature dynamics.

---

## 15. Heating Stage (`opt_temp.in` plus runtime patches)

### Uploaded template

```text
imin=0
nstlim=1000000
dt=0.001
ntb=1
cut=9.0
ntc=2
ntf=2
irest=0
ntx=1
ntt=3
tempi=1.0
temp0=300.0
gamma_ln=2.0
ig=-1
ntpr=500
ntwx=10000
ntwr=1000
iwrap=0
ioutfm=1
```

### Runtime patches

`run_opt_temp` applies:

- `force_first_md_start`: forces `irest=0`, `ntx=1`, meaning the stage starts fresh from coordinates, not from prior velocities.
- `force_safe_heating_start`: forces `ntc=2`, `ntf=2`, `dt=0.001`, `ig=-1`.
- `wrap_pmemd_cuda_fallback`: wraps `pmemd.cuda` so GPU failures can restart or fall back to CPU `pmemd` and then `sander`.

### What it simulates

This is NVT-like heating because `ntb=1` means constant volume periodic boundary conditions. It heats from `tempi=1.0 K` to `temp0=300.0 K` using Langevin dynamics (`ntt=3`) with collision frequency `gamma_ln=2.0 ps^-1`.

The length is:

```text
nstlim × dt = 1,000,000 × 0.001 ps = 1000 ps = 1 ns
```

### Scientific purpose

The system is gently brought from near-zero thermal velocities to room temperature. Starting from 1 K prevents random initial velocities from immediately producing large thermal kicks. The conservative timestep of 1 fs and SHAKE only on H-bonds (`ntc=2`, `ntf=2`) reduce instability risk, especially near metal centers.

---

## 16. Pressure Equilibration (`opt_pres.in`)

### Template parameters

```text
imin=0
nstlim=1000000
dt=0.001
ntb=2
cut=9.0
ntc=2
ntf=2
irest=1
ntx=5
ntp=1
pres0=1.0
taup=5.0
barostat=2
ntt=3
temp0=300.0
gamma_ln=2.0
ig=-1
ntpr=500
ntwx=10000
ntwr=1000
iwrap=0
ioutfm=1
ntxo=2
```

### What it simulates

This is NPT equilibration at 300 K and 1 atm. It continues from the heating restart with positions and velocities (`irest=1`, `ntx=5`). It uses periodic boundary conditions with pressure scaling (`ntb=2`, `ntp=1`). The barostat is Monte Carlo (`barostat=2`) with pressure relaxation time `taup=5.0 ps`.

The length is again 1 ns.

### Scientific purpose

After heating at constant volume, the density/box size may be non-equilibrated. Pressure equilibration allows the solvent box volume to adjust until the water density and pressure are reasonable for production. This is especially important because a solvated box with 20 Å padding can begin with a density/packing state that is not yet physically relaxed.

---

## 17. Production MD (`md.in`)

### Template parameters

```text
imin=0
nstlim=1000000
dt=0.001
ntb=2
cut=8.0
ntc=2
ntf=2
irest=1
ntx=5
ntp=1
barostat=1
pres0=1.0
comp=44.6e-6
taup=2.0
ntt=3
temp0=300.0
gamma_ln=5.0
ntpr=1000
ntwx=5000
ntwr=5000
iwrap=0
ntr=0
ioutfm=1
```

### What it simulates

This is the production molecular dynamics stage. It simulates the solvated molecule at:

- 300 K,
- 1 atm,
- periodic boundary conditions,
- explicit OPC3 water,
- neutralizing ions,
- 1 fs timestep,
- 1 ns per replica.

The production ensemble is NPT-like because `ntb=2`, `ntp=1`, and pressure control are active. The Langevin thermostat has `gamma_ln=5.0 ps^-1`, somewhat stronger coupling than the heating/equilibration template.

The production length per run is:

```text
1,000,000 × 0.001 ps = 1 ns
```

With five replicas, the aggregate sampled production time is:

```text
5 × 1 ns = 5 ns
```

The trajectory output interval is:

```text
ntwx × dt = 5000 × 0.001 ps = 5 ps
```

Since cpptraj later reads every 10th written frame, the final Gaussian snapshots are about 50 ps apart.

### Scientific purpose

This stage samples conformational and solvent configurations that contribute to the NMR spectrum. NMR shieldings are sensitive to local geometry, hydrogen bonding, metal coordination, and solvent polarization/electrostatics. The MD ensemble supplies the conformational distribution from which Gaussian snapshots are drawn.

### What is classical and what is not

During production MD, the system is classical. Bonds, angles, dihedrals, nonbonded interactions, water, ions, and metal-ligand coordination are all represented by the Amber topology. No electronic structure is solved during normal `md.in` production. The later Gaussian stage computes quantum-mechanical magnetic shieldings on extracted static snapshots.

---

## 18. Optional MD Templates Not Used by the Example Config

### 18.1 `md_long.in`

`md_long.in` is a 20 ns production template:

```text
nstlim=20000000
dt=0.001
```

That gives:

```text
20,000,000 × 0.001 ps = 20,000 ps = 20 ns
```

It uses NPT, 300 K Langevin thermostat, Monte Carlo barostat, flexible hydrogen bonds (`ntc=1`, `ntf=1`), binary trajectory output with `ioutfm=0`, and trajectory frames every 20 ps (`ntwx=20000`). It is designed for longer conformational sampling, but it is not selected by the uploaded `sim.txt`.

### 18.2 `md_gamd.in`

`md_gamd.in` is a Gaussian accelerated MD template. It uses:

```text
igamd=3
```

which means dual boost, i.e. total potential boost plus dihedral boost. The parameters include:

```text
ntcmdprep=200000, ntcmd=1000000
ntebprep=200000, nteb=1000000
ntave=50000
iE=2, iEP=2, iED=2
sigma0P=6.0, sigma0D=6.0
irest_gamd=0
```

Scientifically, GaMD is meant to accelerate barrier crossing and improve sampling of conformations that might be rare in normal MD. This can be valuable for flexible ligands, but it changes the sampling distribution and requires careful reweighting/interpretation. It is not selected by the current config.

### 18.3 `md_qmmm.in`

`md_qmmm.in` enables QM/MM:

```text
ifqnt=1
qmmask=':1'
qmcharge=0
spin=1
qm_ewald=0
qm_theory='EXTERN'
&gau
  use_template=1
  num_threads=8
  mem='12GB'
/
```

This means residue 1 is treated as the QM region, and an external QM engine, presumably Gaussian, supplies energies/forces. It runs only 10 ps with 1 fs timestep. This is a separate QM/MM dynamics mode, not the normal snapshot NMR workflow. It is not selected in the uploaded `sim.txt`.

---

## 19. cpptraj Frame Extraction

After production MD, each run enters `run_cpptraj`.

The key inputs are:

- production trajectory `${name}_md.mdcrd`,
- topology `${name}.parm7`,
- selected cpptraj template,
- solute atom count `LIMIT`,
- current frame offset `curr_run`, so frames from different replicas have unique numbering.

### 19.1 The selected template: `cpptraj_solvation.in`

The example config uses:

```text
cpptraj:=cpptraj_solvation
cpptraj_mode:=no_water
```

`cpptraj_solvation.in` does:

```text
parm ${name}.parm7
trajin ${name}_md.mdcrd 1 last 10
autoimage
center :1 mass origin
image origin center
trajout ${name}_frame.xyz xyz ftype namexyz multi
run
```

This means:

- Load the Amber topology.
- Read every 10th frame from production trajectory.
- Reimage molecules across periodic boundaries.
- Center residue 1 at the origin by mass.
- Image the system around the centered solute.
- Write a multi-frame XYZ containing atom names and coordinates.

The comments in the template state that all solvent is written first and exact first-shell trimming is done per frame in Python.

### 19.2 Why not select waters directly in cpptraj?

cpptraj can select closest waters, and you also have `cpptraj_water.in` for `closest 20`. But `cpptraj_solvation.in` deliberately writes the solvent first and delegates exact first-shell selection to Python. This allows a custom criterion:

```text
d_surface = min_i(|r_O - r_i| - R_vdw(i))
```

That criterion is based on distance from water oxygen to the solute van der Waals surface, not merely center-to-center atom distance or water rank.

### 19.3 Alternative cpptraj templates

- `cpptraj.in`: strips everything except residue 1. This gives solute-only Gaussian calculations.
- `cpptraj_all.in`: keeps residues 1-2. Useful when residue 2 is a metal ion or separate linked fragment.
- `cpptraj_all_di.in`: keeps residues 1-3. Useful for di-complexes or multi-residue solute representations.
- `cpptraj_water.in`: uses `closest 20 @1-${limit} oxygen`, selecting the 20 closest waters by oxygen to the solute atom range.

---

## 20. Python First-Shell Surface Selector (`select_first_shell_surface.py`)

This script is central to the solvent representation for Gaussian.

### 20.1 Input assumptions

The script assumes:

1. Each XYZ frame starts with all solute atoms.
2. The number of solute atoms is known from `LIMIT`.
3. Everything after the solute is solvent tail.
4. Waters appear in O-H-H order.
5. Monatomic ions may appear in the tail and are discarded.

### 20.2 Water identification

The script reads the solvent tail and parses it as:

- water triplets: `O H H`,
- ignored ions: Li, Na, K, Mg, Ca, Zn, Cd, Cl, Br, I, F, etc.

If the tail contains anything else, it errors rather than silently producing wrong Gaussian inputs. This is a good scientific-safety design: unexpected residues or malformed atom ordering should not be passed into NMR calculations unnoticed.

### 20.3 Surface-gap selection criterion

For each water, only the oxygen atom is used for shell selection. The script computes:

```text
d_surface = min_i(distance(O_water, atom_i) - vdw_radius(atom_i))
```

where `i` runs over solute atoms, optionally excluding solute hydrogens. The uploaded config sets:

```text
shell_surface_cutoff := 1.8
shell_use_solute_hydrogens := false
```

Thus, a water is kept if its oxygen is within 1.8 Å of the heavy-atom van der Waals surface of the solute.

This is different from a simple O-solute atom cutoff. A large atom such as Se or Au has a larger van der Waals radius, so a water oxygen can be farther from its center but still close to its surface.

### 20.4 Periodic-boundary handling

The script can parse orthorhombic box vectors from cpptraj XYZ comments and apply a minimum-image convention. If the box is not recognized or is triclinic, it falls back to no-PBC behavior. Since cpptraj already `autoimage`s and centers the solute, this fallback is often acceptable, but it is still an assumption.

### 20.5 Output

The script rewrites each frame in place:

```text
solute atoms + kept water atoms
```

Ions are intentionally removed. It also writes:

```text
frames/first_shell_summary.tsv
```

with frame number, total waters, kept waters, ignored ions, minimum gap, and maximum kept gap.

### 20.6 Scientific role

This step defines the **local solvent environment** of the quantum NMR calculation. It attempts to keep waters close enough to directly influence shielding through local electrostatics and hydrogen bonding, while removing distant bulk water that would make Gaussian calculations too large.

---

## 21. Alternative Hydrogen-Bond Water Selector (`select_interact.py`)

If `cpptraj_mode` is not `no_water`, the pipeline expects a `frames.nc` trajectory and runs `select_interact.py`.

This script uses MDAnalysis hydrogen-bond analysis with:

```text
solute selection = resid 1
water selection = resname WAT
donor-acceptor cutoff = 3.0 Å
D-H-A angle cutoff = 150°
```

For each frame, it identifies water residues that participate in hydrogen bonds with the solute. It then writes an XYZ containing:

```text
solute + hydrogen-bonding waters
```

If no waters form hydrogen bonds in a frame, it writes solute only.

Scientifically, this is a more chemically specific selection criterion than surface distance. It emphasizes hydrogen-bond partners rather than all close waters. That can be useful for amino acids, zwitterions, and strongly H-bonded solvation patterns, but it may miss waters that affect NMR electrostatically without satisfying the H-bond angle/distance threshold.

---

## 22. Gaussian Input Preparation (`run_gauss_prep`)

`run_gauss_prep` copies all processed XYZ frames from:

```text
process/spectrum/frames/
```

to:

```text
process/spectrum/gauss_prep/frames/
```

It then copies/generates `xyz_to_gfj.sh` from the general script library and substitutes:

- solute atom limit,
- charge,
- water mode,
- water point-charge values.

The uploaded `xyz_to_gfj.sh` itself was not included, so the exact Gaussian input body for frame calculations cannot be fully audited here. However, from the surrounding code and config, its intended role is clear: it turns each selected XYZ cluster into a Gaussian `.gjf` file.

### Water modes

The pipeline supports three water representations:

| `water_mode` | Gaussian model |
|---|---|
| `discard` | Remove waters from Gaussian input. Solvent influence comes only from implicit solvent if the Gaussian route includes it. |
| `point_charges` | Replace selected water atoms with Gaussian point charges, usually `Bq`/external charge embedding. This keeps electrostatic influence without adding QM basis functions. |
| `full_qm` | Keep selected waters as real QM atoms. This is most explicit but much more expensive. |

The example uses:

```text
water_mode := point_charges
water_oxygen_charge := -0.834
water_hydrogen_charge := 0.417
```

### Scientific meaning

This stage defines the **QM cluster and electrostatic embedding model** for NMR. The classical MD generated many solvated frames; Gaussian cannot cheaply compute NMR for the whole periodic water box. The pipeline therefore extracts a local cluster and optionally embeds nearby waters as charges.

The point-charge mode is a compromise:

- It keeps frame-specific solvent electrostatics.
- It avoids the large cost of treating every water electron quantum mechanically.
- It cannot represent water polarization, charge transfer, or explicit water orbital effects.

One caveat: the MD water model is OPC3, but the example point charges are TIP3P-like. That may be acceptable as a pragmatic embedding approximation, but if strict consistency is desired, the point-charge values should be matched to OPC3 charges.

---

## 23. Gaussian NMR Jobs (`run_gaussian`)

After `.gjf` files are prepared, `run_gaussian` submits one Gaussian job per frame.

### 23.1 Resource model

Defaults are:

```text
GAUSS_MEM_GB = 32
GAUSS_NCPUS = 8
```

unless overridden by environment variables. On MetaCentrum, the script also requests:

```text
host_licenses=g16:scratch_local=50gb
```

This is necessary because Gaussian writes large scratch/RWF files and may require licensed nodes.

### 23.2 Input/resource patching

Before submitting each frame, the code patches the Gaussian input file to include:

```text
%mem=32GB
%nprocshared=8
```

or corresponding override values. It also patches the job script so Gaussian runtime environment variables are sane:

```text
OMP_NUM_THREADS
MKL_NUM_THREADS
OPENBLAS_NUM_THREADS
GAUSS_SCRDIR
```

It also wraps the Gaussian invocation so the job fails if the log does not contain normal termination.

### 23.3 Resume behavior

The Gaussian stage is designed to resume partially completed frame sets. It keeps `finished_jobs.log` and also rescans existing output directories/logs. Valid logs are those containing:

```text
Normal termination of Gaussian
```

and not containing explicit error termination. Broken logs are removed or requeued.

### 23.4 Scientific meaning

Each Gaussian job computes NMR magnetic shieldings for one static MD-derived snapshot. These shieldings depend on:

- instantaneous solute conformation,
- metal coordination geometry,
- hydrogen-bonding state,
- local electric field from selected waters/point charges,
- chosen DFT functional/basis/route,
- implicit solvent model if included by the generated `.gjf`.

The uploaded `gau_job.tpl` contains:

```text
#p B3LYP/6-31G(d,p) SCF(XQC,MaxConventionalCycles=70)
```

but the full production frame route is ultimately controlled by the not-uploaded `xyz_to_gfj.sh`. Therefore, this documentation can describe the pipeline’s NMR job orchestration and embedding logic, but not the exact final Gaussian route for every frame unless that converter is also inspected.

---

## 24. NMR Analysis and Chemical Shifts (`run_analysis`)

`run_analysis` copies all Gaussian NMR logs into:

```text
process/spectrum/analysis/nmr/
```

It then generates a log-processing script from `log_to_plot.sh` and runs it with a shielding reference value.

### 24.1 Manual sigma mode

Your config uses:

```text
sigma := 32.2
```

So the analysis uses 32.2 as the shielding reference. The usual NMR relation is:

```text
chemical shift δ = σ_reference - σ_sample
```

The exact algebra is implemented in `log_to_plot.sh`, which was not uploaded, but the variable name `SIGMA_TMS` and the TMS-reference logic strongly indicate that the script converts absolute shieldings into shifts relative to TMS or a fixed reference.

### 24.2 Automatic TMS mode

If `sigma` is empty or set to `auto`, the code creates and runs a TMS reference Gaussian job:

- Geometry: tetramethylsilane coordinates embedded directly in `data.sh`.
- First Link1 job: optimization.
- Second Link1 job: GIAO NMR shielding calculation.
- Method shown in code: `wB97XD/aug-cc-pVTZ` with `SCRF=(IEFPCM,Solvent=Water)`, tight/XQC SCF, ultrafine grid.

It extracts the average isotropic hydrogen shielding from the TMS log and uses that as `SIGMA_TMS`.

### 24.3 Outputs

The analysis step expects:

```text
avg.dat
all_peaks.dat
```

`avg.dat` is the averaged/smoothed spectral data used for the normal spectrum plot. `all_peaks.dat` is the all-peaks/stick-style data preserving individual frame/atom contributions.

Scientifically, this is the ensemble-averaging stage: Gaussian gives individual snapshot shieldings; the analysis converts those into a spectrum representing the sampled MD ensemble.

---

## 25. Plotting (`run_plotting`)

The plotting stage copies:

```text
avg.dat
all_peaks.dat
```

and then runs gnuplot templates.

If:

```text
filter := none
```

then it produces:

```text
${save_as}.png
${save_as}_all_peaks.png
```

If:

```text
filter := alpha_beta
```

then it also runs a Python filter to isolate alpha/beta hydrogens, useful for amino-acid-like systems.

Scientifically, this is a reporting stage. It does not change the underlying shieldings; it filters, broadens, averages, and plots them.

---

## 26. Job Submission and HPC Behavior

The pipeline supports two execution modes:

- `meta=true`: MetaCentrum/PBS with `qsub`.
- `meta=false`: Wolf/psubmit with `psubmit`.

In the uploaded `sim.txt`, `meta=true`, so jobs are submitted to PBS. The job submission wrapper builds a resource selector such as:

```text
select=1:ncpus=<N>:ngpus=<G>:mem=<MEM>gb
```

and optionally appends `JOB_META_SELECT_EXTRA`, for example Gaussian license and scratch requirements.

The job system is synchronous at the wrapper level: `submit_job` submits and then calls `wait_job`, which loops on `qstat` until the job is gone. Parallelization happens because the driver launches several `submit_job` calls in background subshells.

The pipeline uses `.jobid` files to avoid duplicate submissions after disconnection. If a job ID exists and is still present in `qstat`, the driver waits rather than resubmitting.

---

## 27. The Actual Scientific Model in One Sentence

For the example config, the pipeline simulates a **formally anionic gold-cysteine complex in an explicit OPC3 water box neutralized by sodium, parameterized with GAFF2 plus MCPB-derived metal-center terms, equilibrated and sampled by five 1 ns classical Amber NPT MD replicas at 300 K/1 atm, reduced to 100 MD snapshots with first-shell solvent selected by water oxygen proximity to the solute van der Waals surface, and evaluated by Gaussian NMR calculations using either point-charge solvent embedding or other selected water modes, then converted into averaged proton NMR spectra.**

---

## 28. Important Assumptions and Caveats

### 28.1 Residue and atom ordering assumptions

Many parts assume residue 1 is the solute:

- minimization restraint mask `:1 & !@H=`,
- cpptraj centering `center :1 mass origin`,
- MDAnalysis `resid 1`,
- first `LIMIT` atoms are solute in XYZ.

If tLEaP changes residue ordering, or if the metal is residue 2 but should be treated as part of the solute in Gaussian, templates must be chosen accordingly (`cpptraj_all.in` or MCPB PDB-based handling).

### 28.2 Metal-center topology must be validated

A missing Au-Se or Au-S bond in Amber topology is scientifically catastrophic but may not crash the run. The atoms simply become nonbonded. Therefore, the final topology must be checked for all intended metal-ligand bonds.

The fixed generator should reject a topology where the authoritative MOL2 contains Au-Se but `parm7` lacks it.

### 28.3 Classical MD cannot break or form bonds realistically

If Au-Se is bonded in the topology, Amber treats it as a harmonic bonded interaction. It will not naturally form or break with electronic rearrangement. If Au-Se is absent, Amber treats it as nonbonded and may drift apart. Neither case is reactive chemistry. It is a fixed-topology force-field model.

### 28.4 Solvent treatment mismatch

Amber MD uses OPC3 water. The example Gaussian point-charge embedding uses `-0.834/+0.417`, which are common TIP3P-like charges. For strict consistency, consider matching point charges to the same water model used in MD, or document the intentional use of TIP3P charges for embedding.

### 28.5 First-shell cutoff interpretation

`shell_surface_cutoff=1.8` is not a center-to-center cutoff. It is oxygen-to-VDW-surface gap. This can keep waters farther from large atoms and reject waters near small atoms depending on van der Waals radii. That is chemically more surface-aware but requires correct element identification.

### 28.6 Gaussian route uncertainty

The exact production Gaussian frame route is produced by `xyz_to_gfj.sh`, which was not included. The code clearly orchestrates Gaussian NMR jobs and includes a minimal `gau_job.tpl`, but complete documentation of the DFT method/basis/solvent model for frame NMR requires inspecting that converter.

### 28.7 Sampling length

The current production setting is 5 ns total across replicas. For flexible molecules or slow metal-ligand conformational rearrangements, this may be short. It may still be appropriate for a first-pass NMR workflow, but convergence should be checked by comparing spectra from `run_0`...`run_4` separately.

---

## 29. Practical Validation Checklist

Before trusting a final spectrum, check these:

1. **CREST output exists**: `process/preparations/crest/${name}_crest.mol2`.
2. **Metal-containing full MOL2 exists** if metal complex: `${name}_charges_full.mol2` or equivalent.
3. **MCPB completed**: `${name}_mcpbpy.frcmod`, `${name}_mcpbpy.pdb`, and MCPB tLEaP input exist.
4. **tLEaP final topology contains all metal bonds**: especially Au-C and Au-Se/Au-S/Au-N as intended.
5. **No old cached tLEaP topology is reused** after changing connectivity or atom names.
6. **MD energies are stable** through minimization, heating, pressure equilibration, and production.
7. **Trajectory imaging is sane**: solute centered, waters near solute not split across periodic boundaries.
8. **First-shell summary is plausible**: water counts should not be zero for all frames unless intentionally using no water.
9. **Gaussian logs normally terminate** for all 100 frames.
10. **Chemical shifts are referenced consistently**: fixed `sigma=32.2` or automatic TMS, not an accidental mix.
11. **Replicas agree reasonably**: compare spectra/shift distributions by run before final averaging.

---

## 30. Where Each Scientific Artifact Comes From

| Artifact | Produced by | Meaning |
|---|---|---|
| `${name}_crest.mol2` | CREST + MOL2 coordinate merge | Optimized/conformer geometry with original connectivity preserved. |
| `${name}_charges.mol2` | antechamber | Organic ligand atom types/charges or dummy charges for metal workflow. |
| `${name}.frcmod` | parmchk2 | Missing ligand GAFF/GAFF2 parameters. |
| `${name}_mcpb.pdb` | utility conversion | MCPB-friendly ligand+metal PDB. |
| `${name}_mcpbpy.frcmod` | MCPB.py | Metal-center bonded/nonbonded parameter corrections. |
| `${name}_mcpbpy.pdb` | MCPB.py | MCPB-typed structure for tLEaP. |
| `${name}.parm7` | tLEaP | Final Amber topology: atoms, charges, masses, bonds, angles, dihedrals, nonbonded terms, water, ions. |
| `${name}.rst7` | tLEaP | Initial coordinates and box. |
| `${name}_opt_water.rst7` | Amber minimization | Solvent-relaxed restart. |
| `${name}_opt_all.rst7` | Amber minimization | Whole-system minimized restart. |
| `${name}_opt_temp.rst7` | Amber MD | Heated restart at 300 K. |
| `${name}_opt_pres.rst7` | Amber MD | Pressure-equilibrated restart. |
| `${name}_md.mdcrd` | Amber production MD | Production trajectory. |
| `${name}_frame.xyz` | cpptraj | Multi-frame extracted XYZ stream. |
| `frames/frame_*.xyz` | split + Python selector | Individual Gaussian-ready frame geometries/clusters. |
| `frame_*.gjf` | Gaussian prep | Gaussian NMR input per snapshot. |
| `frame_*.log` | Gaussian | Magnetic shielding output per snapshot. |
| `avg.dat` | analysis | Averaged/smoothed spectrum data. |
| `all_peaks.dat` | analysis | All individual peaks/stick-spectrum data. |
| `${save_as}.png` | plotting | Final averaged spectrum plot. |
| `${save_as}_all_peaks.png` | plotting | Final all-peaks plot. |

---

## 31. Suggested “Methods” Paragraph Derived From the Pipeline

A concise methods-style description of what this pipeline does would be:

> Starting MOL2 structures were pre-relaxed using xTB and CREST in an implicit aqueous environment, after which CREST coordinates were transferred back onto the original MOL2 connectivity. Organic ligand atom types were assigned with AmberTools/antechamber using GAFF2, while metal-containing systems were handled by stripping the metal for ligand typing and deriving metal-center parameters with MCPB.py. MCPB small-model quantum calculations were run with Gaussian, and the resulting metal-ligand bonded parameters were imported into tLEaP together with the ligand frcmod files and custom selenium/silicon patches. Systems were solvated in an OPC3 water box with 20 Å isotropic padding and neutralized with sodium ions. After water-restrained minimization, full-system minimization, 1 ns heating to 300 K, and 1 ns NPT pressure equilibration, production MD was run for 1 ns per replica at 300 K and 1 atm. Five replicas were used, and every tenth saved production frame was extracted, giving 100 Gaussian snapshots in total. Solvent-shell waters were selected per frame by water oxygen distance to the solute van der Waals surface and included in Gaussian NMR calculations either as point charges or according to the configured water mode. Gaussian magnetic shieldings were converted to chemical shifts using a fixed or automatically computed TMS reference and averaged to produce final NMR spectra.

---

## 32. Final Interpretation

The code is not merely a set of job wrappers. It encodes a specific scientific model:

- **Geometry source:** xTB/CREST-relaxed structure, but original MOL2 connectivity preserved.
- **Classical force field:** GAFF2-like ligand model plus MCPB-derived metal-center corrections.
- **Solvent model in MD:** explicit OPC3 water with periodic boundary conditions and sodium neutralization.
- **Dynamics ensemble:** staged minimization → NVT heating → NPT equilibration → NPT production MD.
- **Sampling strategy:** multiple short replicas, then evenly spaced snapshots.
- **NMR electronic-structure model:** static Gaussian NMR calculations on MD snapshots, with optional local solvent point-charge/full-QM/discarded treatment.
- **Spectrum model:** chemical shifts from shieldings, ensemble-averaged and plotted.

The most scientifically sensitive parts are the metal-center topology, charge consistency, water-shell representation, Gaussian route, and convergence of the MD snapshot ensemble. The Au-Se failure you diagnosed belongs exactly to the first category: if the final Amber topology does not contain the intended metal-ligand bond, the MD ensemble no longer represents the intended gold complex, and all downstream Gaussian NMR results are chemically invalid for that target system.