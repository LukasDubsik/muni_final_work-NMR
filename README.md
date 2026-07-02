# Exhaustive Scientific and Technical Documentation of the NMR Simulation Pipeline

**Document purpose.** This document describes, in ordered form, what the pipeline does scientifically and computationally, how the individual scripts interact, what physical model is being built, what parameters control that model, what data is produced at each stage, and where the main scientific assumptions enter. It is written as documentation of the workflow itself, not as a narrative of one example run.

The pipeline is a multi-stage automated workflow for generating solution-phase proton NMR spectra from molecular structures. It combines conformer preparation, classical force-field parameterization, optional metal-center parameterization, explicit-solvent Amber molecular dynamics, frame selection, Gaussian GIAO NMR calculations, chemical-shift referencing, and final plotting.

The scientific chain is:

```text
starting structure
  -> conformer/geometry preparation
  -> atom typing and force-field parameter generation
  -> optional MCPB.py metal-center bonded model
  -> tLEaP system assembly, solvation, neutralization
  -> restrained minimization of solvent
  -> full minimization
  -> heating
  -> pressure equilibration
  -> production MD replicas
  -> frame extraction and solvent-shell reduction
  -> Gaussian GIAO NMR inputs
  -> Gaussian shielding calculations
  -> TMS referencing / chemical-shift conversion
  -> averaged and all-frame spectra
  -> archived final result directory
```

---

## 1. Scope of the pipeline

The pipeline is designed for molecular systems whose NMR spectrum is to be estimated in water or an implicit/explicit hybrid aqueous environment. It can work from two broad kinds of input:

1. **A MOL2 structure**: the pipeline must build parameters, charges, Amber topology/restart files, then run MD and Gaussian.
2. **Existing Amber `parm7`/`rst7` input**: the parameterization phase can be skipped or shortened, and the MD/spectrum phase can be run from prepared Amber files. The uploaded main driver currently shows the full MOL2 route as the major implemented path.

The pipeline is especially adapted for difficult systems containing:

- ordinary organic atoms handled by GAFF/GAFF2-like parameters,
- amino-acid-like or zwitterionic molecules,
- selenium analogues of sulfur-containing groups,
- silicon/TMS-like atoms,
- heavy-metal complexes such as gold complexes that require MCPB.py-style metal-center parameterization,
- explicit water around the solute, later reduced to either no explicit water, point-charge water, or full-QM water for Gaussian NMR.

The workflow is not a pure quantum-mechanical molecular dynamics method. Most sampling is classical Amber MD; quantum chemistry enters during MCPB parameterization and during final Gaussian NMR calculations.

---

## 2. High-level architecture and file groups

The project is organized into four logical layers.

### 2.1 Driver layer

The top-level `nmr.sh` script is the orchestration layer. It:

- enables strict Bash error handling,
- sources all helper libraries,
- parses command-line overrides,
- reads `inputs/sim.txt`,
- checks expected input templates,
- decides which preparation steps are needed,
- launches parallel MD replicas,
- launches cpptraj frame extraction,
- launches Gaussian preparation and Gaussian NMR jobs,
- performs NMR analysis and plotting,
- archives the final `process/` tree into `data_results/<save_as>`.

The main execution order is linear at the stage level, but several stages launch multiple independent jobs in parallel.

### 2.2 Bash function libraries

The `lib/general_scripts/bash/functions/` layer contains small utility functions used by all stages:

- `input_handling.sh`: configuration reading, optional/default settings, input validation, atom-count extraction.
- `output.sh`: user-facing logging, warnings, fatal errors.
- `modules.sh`: environment/module checks.
- `jobs.sh`: cluster submission and waiting.
- `file_modification.sh`: template substitution and runtime patching of generated job scripts or Amber input files.
- `utilities.sh`: chemistry/file-format helpers, especially MOL2/PDB/Amber/MCPB handling.
- `logging.sh`: deprecated compatibility stubs.

### 2.3 Job-generation layer

The `lib/general_scripts/bash/job_creation/` layer contains scientific stages:

- `preparations.sh`: CREST, antechamber, parmchk2, MCPB.py, Open Babel normalization, tLEaP.
- `simulation.sh`: Amber minimization, heating, pressure equilibration, production MD, cpptraj post-processing.
- `simulation_parallel.sh`: launches per-replica copies of the simulation steps.
- `gauss.sh`: converts selected XYZ frames into Gaussian inputs and runs Gaussian.
- `data.sh`: extracts shieldings, computes or uses the TMS reference, averages peaks, launches plotting.
- `info.sh`: optional notification helper.

### 2.4 Scientific input templates

The `inputs/` tree supplies scientific parameters. The uploaded files represent the relevant template types:

- `sim.txt`: pipeline configuration.
- `tleap.in`, `tleap_spec.in`: tLEaP assembly templates.
- `mcpb.in`: MCPB.py template concept.
- `opt_water.in`, `opt_all.in`, `opt_temp.in`, `opt_pres.in`, `md.in`, `md_long.in`, `md_gamd.in`, `md_qmmm.in`: Amber control templates.
- `cpptraj.in`, `cpptraj_water.in`, `cpptraj_all.in`, `cpptraj_all_di.in`, `cpptraj_solvation.in`: cpptraj extraction templates.
- `xyz_to_gfj.sh`: XYZ-to-Gaussian-input generator.
- `split_xyz.sh`, `select_first_shell_surface.py`, `select_interact.py`: frame splitting and solvent-shell selection.
- `gjf_to_plot.awk`, `ref_sigma.awk`, `log_to_plot.sh`, `average_plot.sh`: shielding extraction and peak averaging.

---

## 3. Ordered execution tree

The actual order of the pipeline is the following. This is the documentation spine for the rest of the file.

```text
0.  Shell setup and library loading
1.  Configuration parsing
2.  Input validation and atom-count extraction
3.  Optional module/command validation
4.  Final-result resume guard
5.  Preparation phase, when input_type = mol2
    5.1 CREST/xTB preparation
    5.2 antechamber atom typing and charge handling
    5.3 parmchk2 missing parameter generation
    5.4 MCPB.py metal-center parameterization, if metal exists and MCPB is enabled
    5.5 Open Babel / MOL2 normalization step
    5.6 tLEaP assembly, solvation, ion addition, topology writing
6.  MD replica allocation and frame-count distribution
7.  Amber simulations, repeated for each replica
    7.1 water-only/solute-restrained minimization
    7.2 full-system minimization
    7.3 heating
    7.4 pressure equilibration
    7.5 production MD
8.  cpptraj sampling and frame post-processing, repeated for each replica
    8.1 trajectory imaging/centering/stripping/preselection
    8.2 splitting multi-frame XYZ outputs
    8.3 solvent-shell selection or H-bonding water selection
    8.4 collection into process/spectrum/frames
9.  Gaussian input generation
    9.1 split solute and solvent tail by atom count
    9.2 choose water mode: discard / point_charges / full_qm
    9.3 choose Gen vs GenECP basis strategy
    9.4 write GIAO NMR Gaussian input
10. Gaussian execution
    10.1 one independent Gaussian job per frame
    10.2 resource patching and scratch allocation
    10.3 completion validation and resume
11. Analysis
    11.1 copy valid Gaussian logs
    11.2 obtain TMS reference shielding
    11.3 parse Gaussian shieldings
    11.4 convert shieldings to chemical shifts
    11.5 average frame-wise peaks by atom id
12. Plotting
    12.1 plot averaged spectrum
    12.2 plot all-frame/all-peak spectrum
    12.3 optional atom subset filtering
13. Final archive and cleanup
```

---

## 4. Configuration model

### 4.1 Syntax

The configuration file is `inputs/sim.txt`. It is parsed line by line. Empty lines and lines starting with `#` are ignored. Configuration assignments use:

```text
key:=value
```

The parser removes whitespace from the key but preserves the value string after `:=`. The code expects no spaces around the `:=` marker in normal usage.

### 4.2 Required conceptual groups

The configuration defines:

#### Identification

- `name`: base name of input structure and all intermediate files.
- `save_as`: final result directory and output-plot prefix.

#### Execution environment

- `check_modules`: if true, check modules and required commands before running.
- `meta`: whether the run is on MetaCentrum.
- `directory`: base directory used in generated MetaCentrum job scripts.
- `amber`: Amber module suffix/version.
- `mamba`: path to the conda environment containing CREST/xTB/Python dependencies.
- `gpu`: intended GPU mode flag; actual job scripts still decide which executable is used.

#### Input type

- `input_type=mol2`: full preparation route from structure.
- `input_type=7`: intended route for already prepared Amber topology/restart.

#### Scientific system parameters

- `charge`: total charge of the molecular solute / QM region as used by antechamber/Gaussian and MCPB bookkeeping.
- `metal_charge`: formal metal oxidation/charge override for MCPB.py charge handling.
- `params`: whether to use custom force-field parameter files from `inputs/params`.

#### Stage template names

These choose which templates under `inputs/simulation/` are used:

- `tleap`
- `opt_water`
- `opt_all`
- `opt_temp`
- `opt_pres`
- `md`
- `cpptraj`

The code checks that each selected `.in` file exists before running.

#### Sampling and spectrum controls

- `md_iterations`: number of independent MD replicas.
- `num_frames`: total number of Gaussian frames over all replicas.
- `sigma`: proton reference shielding value, or `auto`/empty in the analysis code path.
- `filter`: plotting subset filter, currently `none` or `alpha_beta`.

The pipeline requires:

```text
num_frames % md_iterations == 0
```

because each replica contributes the same number of frames.

#### Solvent handling for Gaussian

- `cpptraj_mode`: broad post-processing mode.
- `water_mode`: how selected waters are passed to Gaussian.
- `shell_surface_cutoff`: first-shell selection distance from solute van der Waals surface.
- `shell_use_solute_hydrogens`: whether solute H atoms participate in the surface selection.
- `water_oxygen_charge`, `water_hydrogen_charge`: charges used when selected water is represented as background point charges.
- `deuterium_water`: if true, water H atoms are treated as D in full-QM Gaussian water mode and water H mass is patched in tLEaP.

### 4.3 The atom-count boundary: `LIMIT`

The pipeline computes `LIMIT` by reading the atom count from the starting MOL2 molecule-count line. This integer is central because it defines the solute boundary in later XYZ files:

```text
first LIMIT atoms = solute / molecule / core
atoms after LIMIT = selected solvent tail
```

This is used by:

- cpptraj post-processing,
- `select_first_shell_surface.py`,
- `xyz_to_gfj.sh`,
- `gjf_to_plot.awk`, which ignores hydrogen atoms beyond `LIMIT` so that water hydrogens are not treated as solute NMR targets.

This design assumes that atom order is preserved through trajectory export: solute first, solvent after.

---

## 5. Stage 0: shell setup, strict error mode, and library loading

The driver begins with:

```bash
set -Eeuo pipefail
shopt -s lastpipe
```

This matters scientifically only indirectly: failed parameterization or failed Gaussian jobs should not silently produce partial spectra. The strict mode means:

- use of unset variables fails,
- failed commands abort the script,
- failures inside pipelines propagate,
- the error trap reports the failing line.

The driver then sources all function libraries and job-creation scripts. The pipeline is therefore not one monolithic script; it is a stage dispatcher.

The error trap prints:

```text
[FATAL] nmr.sh:<line>: command failed (rc=<code>)
```

This is important for debugging because many stages are themselves generated scripts run inside job directories.

---

## 6. Stage 1: reading and validating the configuration

`read_config` parses `inputs/sim.txt` into an associative array. `load_cfg` then moves values from that array into global variables used by the rest of the pipeline.

The important scientific defaults are:

- `water_mode` defaults to `discard` if omitted.
- `shell_surface_cutoff` defaults to `1.8 Å`.
- `shell_use_solute_hydrogens` defaults to `false`.
- `water_oxygen_charge` defaults to `-0.834`.
- `water_hydrogen_charge` defaults to `0.417`.
- `deuterium_water` defaults to `false`.

Those defaults mean that, unless explicitly requested, Gaussian receives only the solute coordinates and models water by continuum solvent only. If point-charge water mode is enabled, selected water is not part of the QM atom list; it enters as fixed external charges.

The validation step checks that all named input templates exist under `inputs/simulation/`. The code does not deeply validate whether the chosen templates are scientifically compatible; it validates their presence and later stages validate outputs.

---

## 7. Stage 2: input molecule and atom count

For MOL2 input, the expected structure file is:

```text
inputs/structures/<name>.mol2
```

The molecule count line is read to obtain the number of solute atoms. This atom count becomes the atom boundary between solute and solvent for all later spectrum generation.

This is a strong assumption. It means that if a later step reorders atoms, inserts atoms into the solute, deletes atoms, or moves the metal into a separate residue while preserving it within the first `LIMIT` atoms, the Gaussian conversion remains valid only if the first `LIMIT` exported XYZ atoms still correspond to the solute atoms whose proton NMR spectrum is desired.

---

## 8. Stage 3: module and command checking

If `check_modules=true`, the pipeline checks:

- CREST module on non-MetaCentrum mode,
- `pmemd-cuda` on non-MetaCentrum mode,
- Open Babel module (`openbabel` on MetaCentrum, `obabel` elsewhere),
- Amber module,
- Gaussian module,
- commands such as `antechamber`, `parmchk2`, `pmemd`, `pmemd.cuda`, `cpptraj`, `g16`, and `qstat`.

This is an operational guard. It does not change the scientific model, but it ensures that the selected computational engine stack is available before the job tree is constructed.

---

## 9. Stage 4: final result resume guard

Before doing work, the driver checks:

```text
data_results/<save_as>/.ok
```

If that marker exists, the whole pipeline exits early. This prevents accidental recomputation and accidental overwriting of a completed result directory.

Individual stages have their own `.ok` markers under `process/`. A stage is treated as complete only if both its marker and expected output files exist.

---

# Part I — Molecular preparation and parameterization

---

## 10. Stage 5.1: CREST/xTB preparation

### 10.1 Purpose

The CREST stage prepares a chemically reasonable geometry/conformer before classical and quantum parameterization. CREST itself works with XYZ geometry, so the pipeline first converts the input MOL2 structure to XYZ using Open Babel. The goal is not to generate the final MD trajectory; the goal is to obtain a relaxed starting geometry suitable for downstream force-field construction.

### 10.2 xTB pre-optimization

Before CREST, the code optionally runs xTB with:

```text
--opt loose
--alpb water
-c <charge>
--T 4
```

Interpretation:

- `--opt loose`: performs a relatively permissive geometry optimization.
- `--alpb water`: uses an implicit water solvation model during xTB relaxation.
- `-c <charge>`: uses the total charge from configuration.
- `--T 4`: uses four threads.

This pre-optimization exists because raw MOL2 structures, especially for selenium, tellurium, or metal-containing systems, can be far enough from xTB minima that CREST safety checks fail.

### 10.3 Connectivity preservation

XYZ does not contain bond information. Therefore, after CREST produces `crest_best.xyz`, the pipeline does **not** simply convert XYZ back to MOL2 by perceived distances. Instead, it writes a new MOL2 whose coordinates come from the optimized XYZ but whose bond table comes from the original input MOL2.

Scientifically this is crucial. For metal complexes, distance-based bond perception can invent or delete metal-ligand bonds. The pipeline treats the starting MOL2 connectivity as authoritative.

### 10.4 Output

The main output is:

```text
process/preparations/crest/<name>_crest.mol2
```

This file is the geometry-relaxed but connectivity-preserving MOL2 used by later stages.

---

## 11. Stage 5.2: antechamber atom typing and charge handling

### 11.1 Purpose

The antechamber stage assigns GAFF/GAFF2-style atom types and, when appropriate, ligand charges. It is used for the organic ligand part of the system.

### 11.2 Metal stripping before antechamber

If a metal is detected in the CREST MOL2, the pipeline preserves the full metal-containing MOL2, then strips the metal before feeding the ligand to antechamber.

This is done because antechamber/GAFF are not meant to type arbitrary transition-metal coordination centers. Treating the metal as a normal GAFF atom would often lead to invalid atom types, invalid charges, or wrong metal-ligand connectivity.

The preserved full file is later used by MCPB.py and by tLEaP connectivity reconstruction.

### 11.3 Charge model behavior

For non-metal systems, the user-provided antechamber parameters can request a charge model such as AM1-BCC:

```text
-c bcc -at gaff2 -dr no
```

For metal systems, the code removes existing `-c ...` and `-dr ...` options and forces:

```text
-c dc -dr no
```

This means antechamber does not try to compute new charges for the metal-containing system. Instead, charges for the metal-center model are later handled by MCPB.py / RESP-style outputs where available.

### 11.4 Selenium and silicon retagging

After antechamber, the pipeline preserves the raw antechamber MOL2 for parmchk2, then applies downstream custom typing for special analogues:

- selenium analogues are retagged so that selenium is not accidentally treated as ordinary sulfur or as a malformed generic atom,
- silicon/TMS-like atom types are retagged where relevant.

The raw copy remains useful because parmchk2 expects standard GAFF-like typing; the patched copy is used later by tLEaP.

### 11.5 Output

Important outputs:

```text
process/preparations/antechamber/<name>_charges.mol2
process/preparations/antechamber/<name>_charges_antechamber_raw.mol2
process/preparations/antechamber/<name>_charges_full.mol2     # metal systems
```

The `_charges_full.mol2` file contains the reassembled ligand plus metal and is the principal input for MCPB.py when a metal is present.

---

## 12. Stage 5.3: parmchk2 missing force-field parameters

### 12.1 Purpose

`parmchk2` scans the typed ligand MOL2 and creates an frcmod file containing missing or estimated GAFF/GAFF2 parameters.

It fills gaps such as:

- bond force constants/equilibrium distances,
- angle force constants/equilibrium angles,
- dihedral terms,
- improper torsions,
- nonbonded parameters.

### 12.2 Metal treatment

If a metal is still present in the MOL2 intended for parmchk2, it is stripped before parmchk2 runs. The full metal-containing MOL2 is carried separately for MCPB.py.

### 12.3 Empty frcmod protection

If parmchk2 produces an empty frcmod, the pipeline writes a minimal frcmod stub with all major section headers:

```text
MASS
BOND
ANGLE
DIHE
IMPROPER
NONBON
```

This avoids later crashes in MCPB.py or tLEaP caused by an expected frcmod file being absent or syntactically incomplete.

### 12.4 Output

```text
process/preparations/parmchk2/<name>.frcmod
```

For metal systems, the full MOL2 is also carried forward:

```text
process/preparations/parmchk2/<name>_charges_full.mol2
```

---

## 13. Stage 5.4: MCPB.py metal-center parameterization

### 13.1 Purpose

MCPB.py is used when the molecule contains a metal and MCPB is enabled in the configuration. Its role is to create an Amber-compatible bonded model for the metal center.

For a metal complex, ordinary nonbonded Lennard-Jones/electrostatic interactions are often not enough to preserve coordination geometry. MCPB.py builds explicit metal-ligand bonded terms such as:

- metal-ligand bonds,
- metal-ligand-ligand angles,
- ligand-metal-ligand angles,
- metal-centered atom types,
- charge models and library files where supported.

This is the stage responsible for making a classical MD model where the metal center remains bound in a fixed coordination topology.

### 13.2 Metal detection

The code detects the first metal atom in the MOL2 by atom name and residue name, not by GAFF atom type. This matters because GAFF atom types like `ca`, `cd`, or `c` are not element symbols.

Supported metal recognition includes elements such as:

```text
Au, Ag, Hg, Zn, Fe, Cu, Ni, Co, Mn, Mg, Ca, Cd, Pt, Pd, Ir, Ru, Rh, Os, Pb, Sn
```

Only the first detected metal is treated as the central ion in this pipeline branch.

### 13.3 MCPB stage directories

MCPB work is split into three directories:

```text
process/preparations/mcpb/01_step1
process/preparations/mcpb/02_qm
process/preparations/mcpb/03_params
```

Each stage has an `.ok` marker. Cached stages are invalidated if the input MOL2 hash changes. This prevents stale metal connectivity or stale charges from being reused after the input structure changes.

### 13.4 Stage 1: MCPB input construction

The pipeline constructs:

- an MCPB-friendly PDB,
- a ligand MOL2 named `LIG.mol2`,
- a single-ion MOL2 for the metal residue,
- a ligand frcmod file,
- an MCPB input file.

The PDB is written so that:

- residue 1 is the ligand (`LIG`),
- residue 2 is the metal residue,
- the element symbol is placed in the correct PDB element columns.

This fixed residue separation helps MCPB.py identify the metal ion and the non-standard ligand.

### 13.5 Explicit metal-bond information

The pipeline extracts atoms bonded to the metal from the authoritative MOL2 bond table and writes `add_bonded_pairs` into the MCPB input.

This is scientifically and technically important. MCPB.py can otherwise infer bonds from distances, which may be wrong for crowded metal complexes or may omit intended bonds when naming changes occur. The intended coordination topology should come from the authoritative MOL2 connectivity.

### 13.6 Metal charge and ligand charge bookkeeping

The formal metal charge is resolved in this order:

1. explicit `metal_charge` from the configuration,
2. meaningful integer-like charge already present on the metal atom in MOL2,
3. fallback derived from total system charge minus ligand charge.

After this, the ligand net charge is forced to:

```text
ligand_charge = total_charge - metal_charge
```

The ligand charges are rebalanced so that MCPB.py sees consistent charge bookkeeping.

This is not the same as saying the final electrostatic model is exact. It is a bookkeeping step so that MCPB.py receives chemically sensible formal charges instead of placeholder zeros.

### 13.7 Stage 2: Gaussian jobs for MCPB.py

MCPB.py generates Gaussian input files such as:

- small-model optimization,
- small-model frequency/force-constant job,
- large-model electrostatic-potential / MK charge job.

The pipeline patches these Gaussian inputs before submission:

- `%Mem` and `%NProcShared` are aligned with the job allocation,
- broken `%RWF=...,0MB` directives are replaced with real scratch sizes,
- for gold, route lines are stabilized and converted to appropriate ECP/basis handling,
- continuum solvation is removed from RESP/MCPB stage-2 jobs,
- SCF and grid settings are tightened,
- route sections are normalized to avoid duplicated `Integral`, `Pop`, or `IOp` directives.

The purpose is not to alter the desired physical target of MCPB.py, but to make the generated Gaussian jobs robust on the cluster.

### 13.8 Stage 3: MCPB parameter generation

After Gaussian jobs finish, MCPB.py generates final parameters. Typical outputs include:

```text
<name>_mcpbpy.frcmod
<name>_tleap.in
<name>_mcpbpy.pdb
<name>_mcpbpy.lib / .off, when generated
```

The frcmod contains metal-center atom types and bonded terms such as `Y*-M1` bonds and `Y*-M1-Y*` angles. In gold complexes, the metal type is commonly `M1`, while directly coordinated ligand atoms may be assigned `Y1`, `Y2`, `Y3`, etc.

### 13.9 Seminario-style bonded terms

MCPB.py’s bonded parameters are generally derived from the quantum-mechanical Hessian of the small model using a Seminario-type procedure. In this pipeline context, the consequence is:

- the equilibrium bond lengths/angles reflect the optimized QM metal-center geometry,
- force constants reflect local QM curvature around that geometry,
- the resulting Amber model is a fixed-topology bonded approximation to the metal coordination environment.

This is suitable for sampling around a chosen coordination state. It is not a reactive model and will not describe bond breaking or ligand exchange unless the topology is changed externally.

---

## 14. Stage 5.5: Open Babel normalization / `nemesis_fix`

After antechamber and MCPB preparation, the pipeline runs an Open Babel normalization step producing:

```text
process/preparations/nemesis_fix/<name>_charges_fix.mol2
```

This exists because MOL2 files can contain metadata, atom naming, or formatting that downstream tLEaP handles poorly. The stage:

- converts MOL2 to MOL2 again via Open Babel,
- normalizes Open Babel output,
- reapplies selenium analogue retagging,
- reapplies silicon analogue retagging.

This is a file-format stabilization step, not a scientific simulation step. It attempts to make the ligand file accepted by tLEaP without losing custom atom-type intent.

---

## 15. Stage 5.6: tLEaP assembly, solvation, ions, topology

### 15.1 Purpose

tLEaP builds the Amber system:

- loads force-field definitions,
- loads ligand/metal parameters,
- loads the solute structure,
- checks the unit,
- solvates it in explicit water,
- adds counterions,
- writes Amber topology and coordinates.

Final outputs:

```text
process/preparations/tleap/<name>.parm7
process/preparations/tleap/<name>.rst7
process/preparations/tleap/sys_leap.pdb
```

### 15.2 Base tLEaP templates

The generic tLEaP templates do the following:

```text
source leaprc.zf or ./leaprc.zf
source leaprc.water.opc3
loadAmberParams frcmod.si_tms, where relevant
loadamberparams <name>.frcmod
SYS = loadmol2 <name>_charges_fix.mol2
check SYS
solvatebox SYS OPC3BOX 20.0 iso
addIons SYS Na+ 0
saveamberparm SYS <name>.parm7 <name>.rst7
savepdb SYS sys_leap.pdb
quit
```

The scientific meaning is:

- use a custom force-field base (`leaprc.zf`) plus OPC3 water,
- define a solute unit from MOL2,
- place it in an isotropic water box extending 20 Å around the solute,
- add sodium ions until the system is neutral,
- write the Amber parameter topology and coordinate restart.

### 15.3 OPC3 explicit solvent

The water model is OPC3. tLEaP uses `OPC3BOX` for solvation. This creates an explicit periodic water box for Amber MD.

### 15.4 Ion addition

The template uses:

```text
addIons SYS Na+ 0
```

This neutralizes the system by adding sodium ions until net charge is zero. It does not set a specific salt concentration; it neutralizes charge.

### 15.5 Selenium parameter patch

If the ligand contains the custom selenium atom type, the code injects:

```text
addAtomTypes { { "SE" "Se" "sp3" } }
loadamberparams <name>_malbecc_se_patch.frcmod
```

This prevents tLEaP from treating selenium as an unknown or wrongly typed atom. The patch provides selenium-specific mass, nonbonded, bond, angle, torsion, or related parameter sections derived/adapted for selenium analogues.

### 15.6 Silicon/TMS parameter patch

If silicon-aware custom types are present, the code injects:

```text
loadamberparams frcmod.si_tms
```

This supports systems containing silicon/TMS-like groups.

### 15.7 D2O mass patch

If `deuterium_water=true`, the code writes and loads:

```text
frcmod.d2o
```

with:

```text
MASS
HW  2.014
```

This changes water hydrogen mass to deuterium mass in the Amber topology. It is a mass override, not a change of water geometry or water partial charges.

### 15.8 MCPB integration inside tLEaP

When MCPB outputs exist, tLEaP assembly becomes more complex. The code imports MCPB-generated:

- frcmod files,
- residue libraries/off files,
- MOL2 templates,
- MCPB PDB,
- explicit bond commands.

The goal is to ensure that the final Amber topology contains the intended metal-center bonded model, not a purely nonbonded metal ion.

Key operations include:

1. Copy MCPB outputs into the tLEaP work directory.
2. Extract MCPB load statements from `<name>_tleap.in`.
3. Extract MCPB bond commands.
4. Filter metal bond commands against authoritative MOL2 connectivity.
5. Remove duplicate bond commands.
6. Strip PDB `CONECT` records to avoid duplicate bond creation.
7. Rewrite PDB residue names to match loaded templates.
8. Apply MCPB `Y*` atom types to ligand atoms directly coordinated to the metal.
9. Load MCPB `frcmod` after base ligand parameters so metal-specific terms are available.
10. Use the MCPB PDB unit as `SYS` when MCPB templates/PDB are usable.

### 15.9 Scientific meaning of explicit metal bonds

For metal complexes, the final Amber topology must contain actual bonded entries between the metal and its coordinated atoms. If a metal-ligand bond is missing from `parm7`, Amber will treat that interaction as nonbonded only. During MD, the ligand can drift away, giving a chemically broken complex.

A correct MCPB/tLEaP result therefore requires:

- the metal atom has the correct MCPB metal type, e.g. `M1`,
- coordinated atoms have matching MCPB ligand-side types, e.g. `Y2`, `Y3`,
- bond parameters exist for each metal-ligand pair,
- the final topology includes actual bond entries for each intended metal-ligand bond,
- corresponding angles around the metal exist where needed.

This is one of the most important validation targets in the whole pipeline.

---

# Part II — Amber molecular dynamics

---

## 16. Replica structure

After preparation, the pipeline creates multiple independent simulation branches:

```text
process/run_0
process/run_1
...
process/run_<md_iterations-1>
```

Each replica goes through the same sequence:

```text
opt_water -> opt_all -> opt_temp -> opt_pres -> md -> cpptraj
```

The replica model is not a replica-exchange method. Replicas are independent repeated simulations of the same starting system, used to sample more frames for the final averaged NMR estimate.

The total number of Gaussian frames is split evenly:

```text
frames per replica = num_frames / md_iterations
```

---

## 17. Amber input concepts used throughout

### 17.1 `imin`

- `imin=1`: minimization.
- `imin=0`: molecular dynamics.

### 17.2 `ntb`

- `ntb=1`: constant volume periodic boundary conditions, typically NVT or minimization with periodic box.
- `ntb=2`: constant pressure periodic boundary conditions, NPT.

### 17.3 `cut`

The cutoff controls direct-space nonbonded interactions. PME handles long-range electrostatics for periodic simulations.

Templates use `cut=8.0` or `cut=9.0 Å`.

### 17.4 `ntc` and `ntf`

- `ntc=1`, `ntf=1`: no SHAKE constraints; all bonds, including hydrogen bonds, are flexible and force-evaluated.
- `ntc=2`, `ntf=2`: constrain bonds involving hydrogen and omit force evaluation for constrained bonds.

The main production template uses constraints on hydrogen bonds (`ntc=2`, `ntf=2`), allowing 1 fs time steps safely.

### 17.5 Thermostat

The templates use Langevin dynamics:

```text
ntt=3
temp0=300.0
gamma_ln=<2.0 or 5.0>
```

This maintains the target temperature around 300 K. `gamma_ln` is the collision frequency; larger values damp dynamics more strongly.

### 17.6 Barostat

Pressure equilibration and production use NPT:

```text
ntp=1
pres0=1.0
taup=<2.0 or 5.0>
barostat=1 or 2
```

`barostat=1` and `barostat=2` select different Amber barostat algorithms depending on template. The pressure target is 1 bar/atm-class production pressure as interpreted by Amber.

### 17.7 Output frequencies

Common fields:

- `ntpr`: energy/thermodynamic print frequency.
- `ntwx`: trajectory write frequency.
- `ntwr`: restart write frequency.
- `ioutfm=1`: NetCDF trajectory/restart output.
- `ioutfm=0`: older formatted/binary trajectory behavior depending on Amber executable.

The NMR pipeline ultimately needs snapshots, not necessarily every MD step. The chosen `ntwx` controls how dense the candidate frame pool is.

---

## 18. Stage 7.1: solvent/box minimization (`opt_water`)

### 18.1 Purpose

The first minimization relaxes water and ions while restraining the solute heavy atoms. This removes bad solvent contacts introduced by solvation while preserving the initial solute conformation and metal coordination geometry.

### 18.2 Template parameters

The uploaded `opt_water.in` uses:

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

Interpretation:

- 2000 minimization cycles.
- First 500 cycles are steepest descent, remaining cycles conjugate gradient, according to Amber convention.
- Periodic constant-volume setup.
- 9 Å cutoff.
- no SHAKE constraints during minimization.
- positional restraints active.
- restraint mask selects residue 1 non-hydrogen atoms, i.e. the solute heavy atoms.
- force constant is 10 kcal mol⁻¹ Å⁻² in Amber units.

### 18.3 Scientific effect

Water molecules are allowed to move away from steric clashes and unreasonable electrostatic contacts while the solute remains nearly fixed. This is important because a solvated box generated by tLEaP can contain locally strained water placement.

---

## 19. Stage 7.2: full-system minimization (`opt_all`)

### 19.1 Purpose

The second minimization relaxes the entire system without positional restraints.

### 19.2 Template parameters

`opt_all.in` uses:

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

### 19.3 Scientific effect

After solvent relaxation, the solute, solvent, ions, and metal-center bonded model can all relax together into a local classical minimum. This is the immediate starting point for heating.

---

## 20. Stage 7.3: heating (`opt_temp`)

### 20.1 Purpose

Heating turns the minimized structure into a finite-temperature ensemble. The system is heated from near 0 K / 1 K to 300 K.

### 20.2 Template parameters

`opt_temp.in` uses:

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

### 20.3 Effective time

With:

```text
nstlim = 1,000,000
dt = 0.001 ps
```

the stage length is:

```text
1,000,000 × 0.001 ps = 1000 ps = 1 ns
```

### 20.4 Runtime patching

The pipeline explicitly patches the first MD/heating input to force:

```text
irest=0
ntx=1
```

This is correct because the first MD stage starts from a minimization restart, which contains positions but not thermal velocities.

It also patches heating to conservative settings:

```text
ntc=2
ntf=2
dt=0.001
ig=-1
```

This reduces instability risk, especially in metal systems.

### 20.5 Scientific effect

The system is brought to 300 K under NVT conditions with Langevin thermostatting. The box size is not yet pressure-equilibrated; only thermal velocities and temperature distribution are established.

---

## 21. Stage 7.4: pressure equilibration (`opt_pres`)

### 21.1 Purpose

This stage adjusts the water box density and pressure under NPT conditions before production sampling.

### 21.2 Template parameters

`opt_pres.in` uses:

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

### 21.3 Effective time

Again:

```text
1,000,000 × 0.001 ps = 1 ns
```

### 21.4 Scientific effect

The system is now allowed to change volume to approach the desired pressure. This improves water density and box dimensions before the production trajectory.

---

## 22. Stage 7.5: production MD (`md`)

### 22.1 Purpose

The production MD stage samples the conformational and solvation ensemble from which NMR frames are extracted.

### 22.2 Default production template

`md.in` uses:

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

### 22.3 Effective time

```text
1,000,000 × 0.001 ps = 1 ns per replica
```

If `md_iterations=5`, total aggregate sampling is 5 ns, though it is split into five independent branches.

### 22.4 Snapshot spacing

With `ntwx=5000` and `dt=0.001 ps`, frames are written every:

```text
5000 × 0.001 ps = 5 ps
```

cpptraj then reads every 10th trajectory frame using:

```text
trajin <name>_md.mdcrd 1 last 10
```

so the extracted candidate spacing is approximately:

```text
5 ps × 10 = 50 ps
```

assuming the trajectory file contains frames at every `ntwx` interval.

### 22.5 Scientific effect

The production run samples solute conformations, water configurations, ion positions, and metal-center fluctuations under the chosen classical force field. The NMR calculation later samples frames from this classical ensemble.

---

## 23. Alternative MD templates

### 23.1 Long production MD (`md_long.in`)

The long template uses:

```text
nstlim=20000000
dt=0.001
```

This corresponds to:

```text
20,000,000 × 0.001 ps = 20 ns
```

It uses NPT, Langevin thermostat at 300 K, Monte Carlo barostat, no SHAKE (`ntc=1`, `ntf=1`), and trajectory output every 20,000 steps.

This template is useful when longer conformational sampling is needed but is more expensive.

### 23.2 GaMD template (`md_gamd.in`)

The GaMD template enables dual-boost Gaussian accelerated MD:

```text
igamd=3
```

with boost parameters:

```text
ntcmdprep=200000
ntcmd=1000000
ntebprep=200000
nteb=1000000
ntave=50000
iE=2
iEP=2
iED=2
sigma0P=6.0
sigma0D=6.0
irest_gamd=0
```

This is intended for enhanced sampling by adding boost potentials to both total and dihedral potential energy surfaces. It is not the default equilibrium MD model and requires more careful interpretation of ensemble averages.

### 23.3 QM/MM MD template (`md_qmmm.in`)

The QM/MM template enables Amber QM/MM:

```text
ifqnt=1
qmmask=':1'
qmcharge=0
spin=1
qm_ewald=0
qm_theory='EXTERN'
```

and a Gaussian interface block:

```text
&gau
  use_template=1
  num_threads=8
  mem='12GB'
/
```

Scientifically this means residue 1 is treated as a QM region, with the rest classical. `qm_theory='EXTERN'` indicates an external QM engine. This template is uploaded but not part of the main default NMR route unless selected in the configuration.

---

# Part III — Trajectory extraction and solvent selection

---

## 24. cpptraj role

cpptraj converts Amber trajectories into frame files suitable for Gaussian preparation.

The pipeline does not send the whole explicit-solvent periodic box to Gaussian. Instead, it extracts a reduced cluster or solute-only frame from MD.

The uploaded cpptraj templates all use the pattern:

```text
parm <name>.parm7
trajin <name>_md.mdcrd 1 last 10
autoimage
...
trajout <name>_frame.xyz xyz ftype namexyz multi
run
```

### 24.1 `autoimage`

`autoimage` rebuilds molecules across periodic boundaries so that molecular fragments are not split by box wrapping.

### 24.2 `center :1 mass origin`

This centers residue 1, the solute, by mass at the origin.

### 24.3 `image origin center`

This images surrounding molecules around the centered solute.

### 24.4 `trajout ... xyz ftype namexyz multi`

This writes a multi-frame XYZ file using atom names/elements.

---

## 25. cpptraj extraction templates

### 25.1 Solute-only template (`cpptraj.in`)

```text
strip !:1
```

This keeps only residue 1. It is appropriate when Gaussian should receive only the solute, with water represented by continuum solvent.

### 25.2 Solute plus metal/second residue (`cpptraj_all.in`)

```text
strip !:1-2
```

This keeps residues 1 and 2, useful when a metal has been separated into its own residue.

### 25.3 Solute plus more residues (`cpptraj_all_di.in`)

```text
strip !:1-3
```

This keeps residues 1 through 3, useful for systems whose chemically relevant solute is distributed over three residues.

### 25.4 Distance-preselected water template (`cpptraj_water.in`)

```text
closest 20 @1-${limit} oxygen closestout closest.dat
```

This selects the 20 waters closest to solute atoms by water oxygen distance. This is a simpler water-shell approach than the later surface-based selector.

### 25.5 Full solvent output for Python trimming (`cpptraj_solvation.in`)

This template writes all solvent after imaging/centering. It intentionally does not perform exact first-shell selection in cpptraj. Instead, the multi-frame XYZ is split into single-frame XYZ files and passed to `select_first_shell_surface.py`.

This is the currently more rigorous shell-selection path.

---

## 26. Frame splitting with `split_xyz.sh`

cpptraj writes a multi-frame XYZ. `split_xyz.sh` reads it from standard input and writes:

```text
frames/frame_<number>.xyz
```

It starts numbering at the offset assigned to the current replica. This prevents frame-number collisions across replicas.

The script validates:

- each frame has an integer atom-count header,
- each frame has a comment line,
- the expected number of atom lines is present.

---

## 27. First solvation shell selection by molecular surface

### 27.1 Purpose

`select_first_shell_surface.py` trims the solvent tail to waters that are close to the solute molecular surface. This is more physically meaningful than selecting waters by distance to atom centers only, because large atoms such as Au, Se, S, I, or Si have larger van der Waals radii.

### 27.2 Input assumption

Each frame must have:

```text
first N atoms = solute
remaining atoms = solvent tail
```

The solvent tail may contain:

- waters in O-H-H order,
- monatomic ions such as Na, K, Cl, Mg, Ca.

Ions are discarded from the rewritten XYZ and are not passed to Gaussian.

### 27.3 Van der Waals surface gap

For each water oxygen, the script computes:

```text
d_surface = min_i( |r_O - r_i| - R_vdw(i) )
```

where:

- `r_O` is the water oxygen position,
- `r_i` is a solute atom position,
- `R_vdw(i)` is the van der Waals radius assigned to solute atom `i`,
- the minimum runs over solute atoms.

The water is kept if:

```text
d_surface <= shell_surface_cutoff
```

The default cutoff is 1.8 Å.

### 27.4 Hydrogen inclusion/exclusion

If `shell_use_solute_hydrogens=false`, solute hydrogens are ignored in surface-distance calculations. This avoids very small hydrogen van der Waals spheres dominating the surface definition.

If true, solute hydrogens are included, which can retain waters close to polar hydrogens more directly.

### 27.5 Periodic minimum image convention

If the XYZ comment line contains an orthorhombic box description from cpptraj, the script applies minimum-image distance calculations. If no usable box is found, it falls back to ordinary Euclidean distance.

### 27.6 Output

The script rewrites each frame in place so that it contains:

```text
solute atoms + kept water atoms
```

and writes:

```text
frames/first_shell_summary.tsv
```

with columns:

```text
frame    total_waters    kept_waters    ignored_ions    min_gap    max_gap_kept
```

---

## 28. Hydrogen-bonded water selection mode

`select_interact.py` is used when the cpptraj mode is not `no_water` in the main script branch. It expects cpptraj to write `frames.nc` rather than direct XYZ files.

It uses MDAnalysis hydrogen-bond analysis between:

```text
solute selection = resid 1
water selection  = resname WAT
```

with:

```text
D-A cutoff = 3.0 Å
D-H-A angle cutoff = 150 degrees
```

For each frame, it selects waters that participate in hydrogen bonds with the solute and writes an XYZ containing:

```text
solute + H-bonding waters
```

If no waters are hydrogen-bonded in a frame, it writes solute only.

This mode selects chemically interacting waters rather than a full first solvation shell.

---

# Part IV — Gaussian input generation

---

## 29. Stage 9: XYZ to Gaussian input conversion

The script `xyz_to_gfj.sh` converts the selected XYZ frames into Gaussian `.gjf` files. It writes one Gaussian input per frame:

```text
process/spectrum/gauss_prep/gauss/frame_<n>.gjf
```

### 29.1 Solute/solvent split

The script defines:

```text
N_CORE = LIMIT
```

Then:

```text
solute_block = first N_CORE atoms from XYZ
water_block  = atoms after N_CORE
```

This is why preserving atom order and the `LIMIT` boundary is essential.

### 29.2 Water handling modes

The script supports three water modes.

#### `discard`

Only the solute block is written as QM atoms. Selected waters are ignored. Solvent enters only through Gaussian continuum solvation:

```text
SCRF=(IEFPCM,Solvent=Water)
```

#### `point_charges`

Only the solute is part of the QM atom list. Selected waters are written immediately after the molecular coordinate block as fixed background point charges using Gaussian’s `Charge` keyword.

Default charges:

```text
O  = -0.834
H  =  0.417
```

This approximates the electrostatic field of first-shell waters without paying the QM cost of treating water atoms explicitly.

#### `full_qm`

The solute and selected waters are all written as QM atoms. This is the most expensive but most explicit local cluster model.

If `deuterium_water=true`, water H atoms are renamed to D before Gaussian input generation.

### 29.3 Gaussian route section

The generated route is:

```text
#P wB97XD/<basis> NMR=(GIAO,ReadAtoms)<extra> SCRF=(IEFPCM,Solvent=Water) SCF=(XQC,Tight) Int=UltraFine CPHF=Grid=UltraFine
```

Scientific meaning:

- `wB97XD`: range-separated hybrid density functional with empirical dispersion.
- `NMR=(GIAO,ReadAtoms)`: compute NMR shieldings using gauge-including atomic orbitals and restrict reported/targeted atoms with a later `atoms=` list.
- `SCRF=(IEFPCM,Solvent=Water)`: implicit water continuum surrounds the QM system.
- `SCF=(XQC,Tight)`: robust/tight SCF convergence.
- `Int=UltraFine`: finer integration grid.
- `CPHF=Grid=UltraFine`: high-quality CPHF grid for response properties.
- `Charge`: used only when point-charge waters are present.
- `NoSymm`: used with point charges to avoid symmetry assumptions inconsistent with external charges.

### 29.4 Basis strategy

The script decides between:

```text
Gen
GenECP
```

If the QM atom set contains Au, S, or Se, it uses `GenECP` and emits custom basis/ECP sections from files under `inputs/bases`:

```text
Au_bas, Au_pot
S_bas,  S_pot
Se_bas, Se_pot
```

Other light elements use:

```text
6-311++G(2df,2pd)
```

Full-QM water uses a smaller water basis:

```text
6-31G(d)
```

when explicit water atoms are present.

### 29.5 Supported elements

The script recognizes these light/QM elements:

```text
H, D, C, N, O, S, Se, Si, P, F, Cl, Br, I
```

Au is handled separately. Any unsupported element in the QM region aborts input generation, forcing the user to add a basis/ECP mapping rather than silently producing invalid Gaussian input.

### 29.6 Proton target list

At the end of each `.gjf`, the script writes:

```text
atoms=<comma-separated solute hydrogen atom indices>
```

Only hydrogens in the solute block are selected. Water hydrogens are not selected as NMR target peaks because they are beyond the `LIMIT` boundary.

This is critical: even if full-QM water is present, the final plotted spectrum is intended to represent solute protons, not water protons.

---

# Part V — Gaussian execution

---

## 30. Stage 10: one Gaussian NMR job per frame

The Gaussian stage creates one job directory per frame:

```text
process/spectrum/gaussian/job_0
process/spectrum/gaussian/job_1
...
```

Each job receives one `.gjf` and produces one `.log`.

### 30.1 Parallelism

The driver submits up to 10 Gaussian frame jobs at once. Each individual Gaussian job requests:

```text
mem = GAUSS_MEM_GB, default 32 GB
ncpus = GAUSS_NCPUS, default 8
walltime = 20 hours
```

On MetaCentrum, it requests:

```text
host_licenses=g16
scratch_local=50gb
```

### 30.2 Link0 resource patching

Before submission, each `.gjf` is patched so that `%mem` and `%nprocshared` match the scheduler allocation.

This prevents inconsistent situations where the PBS job requests one amount of memory/CPU but Gaussian uses another.

### 30.3 Runtime wrapper patching

Generated Gaussian job scripts are patched to:

- use strict shell mode,
- set `OMP_NUM_THREADS`, `MKL_NUM_THREADS`, and `OPENBLAS_NUM_THREADS`,
- unset cluster CPU-binding variables that can harm Gaussian,
- set `GAUSS_SCRDIR`,
- run `g16-prepare` if available,
- fail if Gaussian does not produce normal termination.

### 30.4 Completion validation

A Gaussian log is accepted only if:

```text
contains "Normal termination of Gaussian"
and does not contain "Error termination"
```

Broken logs are not used for NMR extraction.

### 30.5 Resume behavior

The stage keeps:

```text
process/spectrum/gaussian/finished_jobs.log
```

and scans both the final `nmr/` directory and per-job directories for valid logs. Finished jobs are not resubmitted. Broken or stale job directories are removed unless still queued/running.

---

# Part VI — NMR shielding analysis

---

## 31. Stage 11: analysis overview

The analysis stage consumes valid Gaussian logs and produces numerical peak data:

```text
process/spectrum/analysis/plots/plot_frame_<n>.dat
process/spectrum/analysis/avg.dat
process/spectrum/analysis/all_peaks.dat
```

The conversion is from absolute magnetic shielding to chemical shift.

For each solute hydrogen:

```text
chemical_shift = sigma_TMS - sigma_sample
```

Optionally, the AWK extraction supports a linear correction:

```text
chemical_shift = A * (sigma_TMS - sigma_sample) + B
```

with default:

```text
A = 1
B = 0
```

### 31.1 Why TMS is used

NMR experiments report chemical shifts relative to a reference. For proton NMR, TMS is a common reference. Gaussian computes absolute shieldings, so the pipeline converts shieldings to shifts by subtracting sample shielding from TMS shielding.

---

## 32. Manual versus automatic TMS reference

### 32.1 Manual sigma

If `sigma` is a numeric value, the analysis uses it as `SIGMA_TMS`.

### 32.2 Automatic sigma

If `sigma` is empty or `auto`, the pipeline builds and runs a TMS Gaussian job:

1. optimize TMS with:

```text
wB97XD/aug-cc-pVTZ Opt SCRF=(IEFPCM,Solvent=Water)
```

2. run an NMR Link1 job with:

```text
wB97XD/aug-cc-pVTZ NMR=GIAO SCRF=(IEFPCM,Solvent=Water) Geom=AllCheck Guess=Read
```

3. parse all hydrogen isotropic shieldings,
4. average them to obtain `SIGMA_TMS`.

This makes the reference internally consistent with the chosen functional/solvent model for the spectrum, though note that the sample route may use GenECP/custom basis while the TMS reference uses aug-cc-pVTZ.

---

## 33. Gaussian shielding extraction

### 33.1 `gjf_to_plot.awk`

This script scans the Gaussian log for the `Magnetic shielding tensor` section. For each line containing an isotropic shielding record, it extracts:

```text
atom index
element
isotropic shielding
```

It keeps only:

```text
element == H
atom <= LIMIT
```

Thus only solute hydrogens are converted to peaks.

### 33.2 Output format

Each per-frame file has rows:

```text
ppm    intensity    atom_id
```

where intensity is currently fixed to `1.0` per proton record.

### 33.3 `log_to_plot.sh`

This wrapper:

- checks Gaussian normal termination,
- skips bad logs,
- runs `gjf_to_plot.awk` on each valid frame log,
- deletes empty plot files,
- runs `average_plot.sh`,
- concatenates all per-frame peaks into `all_peaks.dat`.

### 33.4 `average_plot.sh`

This script averages by atom index, not by line number. That means each proton atom receives its own average chemical shift over frames.

For atom id `i`:

```text
avg_ppm(i) = mean_frame ppm(i, frame)
avg_intensity(i) = mean_frame intensity(i, frame)
```

The result is sorted by atom id.

---

## 34. Plotting stage

The plotting stage reads:

```text
avg.dat
all_peaks.dat
```

and uses gnuplot scripts to generate:

```text
<save_as>.png
<save_as>_all_peaks.png
```

### 34.1 Averaged spectrum

The averaged plot represents one averaged peak position per tracked proton atom. Depending on the gnuplot script, this may be broadened or smoothed into a spectrum-like curve.

### 34.2 All-peaks plot

The all-peaks plot preserves every frame-level peak. It shows the distribution of chemical shifts over the sampled MD ensemble.

### 34.3 Optional filtering

If `filter=alpha_beta`, a Python filter is applied to keep alpha/beta hydrogens. This requires the original MOL2 file so atom identities can be mapped to chemical roles.

---

# Part VII — Output directory semantics

---

## 35. `process/` tree during a run

The pipeline writes all intermediate work under:

```text
process/
```

Major branches:

```text
process/preparations/
process/run_0/
process/run_1/
...
process/spectrum/
```

### 35.1 Preparation outputs

```text
process/preparations/crest/
process/preparations/antechamber/
process/preparations/parmchk2/
process/preparations/mcpb/
process/preparations/nemesis_fix/
process/preparations/tleap/
```

### 35.2 Per-replica MD outputs

Each replica has:

```text
process/run_i/opt_water/
process/run_i/opt_all/
process/run_i/opt_temp/
process/run_i/opt_pres/
process/run_i/md/
process/run_i/cpptraj/
```

### 35.3 Spectrum outputs

```text
process/spectrum/frames/
process/spectrum/gauss_prep/
process/spectrum/gaussian/
process/spectrum/analysis/
process/spectrum/plotting/
```

## 36. Final archive

When all stages finish, the driver copies:

```text
process/*
```

into:

```text
data_results/<save_as>/
```

then writes:

```text
data_results/<save_as>/.ok
```

and clears `process/*`.

The final directory therefore contains not only the final plots but the full preparation, MD, cpptraj, Gaussian, and analysis trail.

---

# Part VIII — Scientific interpretation of the complete workflow

---

## 37. What is actually being simulated?

The pipeline simulates a solvated molecular system in three nested approximations.

### 37.1 Classical explicit-solvent ensemble

Amber MD samples a periodic explicit-water system:

```text
solute + counterions + OPC3 water box
```

The potential energy surface is classical:

```text
bonded force field + nonbonded electrostatics + Lennard-Jones + PME
```

For metal systems, the metal center is represented by explicit bonded terms generated by MCPB.py.

This stage answers: **what conformations and local solvent arrangements are likely at 300 K in water under the chosen classical model?**

### 37.2 Reduced QM cluster / embedded frame

For each selected MD snapshot, the pipeline builds a Gaussian model:

```text
solute only
or solute + fixed point-charge waters
or solute + explicit QM waters
```

and always includes implicit water PCM unless changed in the generator.

This stage answers: **what is the quantum-mechanical proton shielding of the solute in this selected environment?**

### 37.3 Ensemble average of shieldings/shifts

The analysis averages chemical shifts over frames by atom id.

This stage answers: **what average proton chemical shift is predicted for each solute proton over the sampled classical ensemble?**

---

## 38. Why the pipeline uses both explicit and implicit solvent

The workflow uses explicit water in MD to sample realistic hydrogen bonding, steric packing, and electrostatic fluctuations. But Gaussian NMR on a full periodic water box is computationally impossible. Therefore, the pipeline reduces the solvent environment before Gaussian.

There are three solvent models at the NMR stage:

1. **Continuum only** (`discard`): fastest, ignores specific water geometry.
2. **Continuum + point-charge first shell** (`point_charges`): captures local electrostatic field cheaply.
3. **Continuum + full-QM first shell** (`full_qm`): captures local hydrogen bonding and electronic polarization more explicitly, at high cost.

All three still use PCM/IEFPCM water in the Gaussian route.

---

## 39. Meaning of metal-center sampling

The pipeline’s metal model is a fixed-topology bonded model. That means:

- it can sample vibrations and distortions around a coordination geometry,
- it can preserve intended Au–C, Au–Se, Au–S, or similar bonds if correctly parameterized,
- it cannot model ligand dissociation, oxidative addition, reductive elimination, or bond rearrangement as real chemical reactions.

If the metal-ligand bond is absent from `parm7`, the MD result is invalid for that complex because Amber will allow dissociation as a nonbonded artifact. If the bond exists but has wrong atom types or missing angles, geometry can still be distorted.

---

## 40. Meaning of the final NMR spectrum

The final spectrum is not a direct experimental observable in all details. It is an approximate computational prediction based on:

- the chosen starting structure and charge/protonation state,
- the quality of GAFF/MCPB parameters,
- adequacy of MD sampling,
- correctness of solvent-shell selection,
- DFT functional and basis/ECP choices,
- TMS referencing method,
- averaging and plotting assumptions.

The most reliable use is comparing related structures under the same workflow and identifying relative trends, not claiming absolute experimental identity without validation.

---

# Part IX — Parameter reference

---

## 41. tLEaP parameter reference

| Operation | Current template behavior | Scientific meaning |
|---|---|---|
| `source leaprc.zf` | load custom base force-field settings | defines base organic/solute parameters |
| `source leaprc.water.opc3` | load OPC3 water | explicit water model |
| `loadamberparams <name>.frcmod` | load ligand missing parameters | fills GAFF/parmchk2 gaps |
| `loadamberparams <name>_mcpbpy.frcmod` | injected when MCPB exists | metal-center bonded/nonbonded terms |
| `SYS = loadmol2 ...` or MCPB PDB | load solute | defines atoms/residues/charges/types |
| `solvatebox SYS OPC3BOX 20.0 iso` | 20 Å isotropic water shell | periodic explicit solvent box |
| `addIons SYS Na+ 0` | neutralize with Na+ | charge neutrality |
| `saveamberparm` | write `parm7`/`rst7` | Amber topology and coordinates |

---

## 42. Amber stage parameter reference

| Stage | Ensemble/operation | Length | Key features |
|---|---:|---:|---|
| `opt_water` | restrained minimization | 2000 cycles | solute heavy atoms restrained, solvent relaxes |
| `opt_all` | full minimization | 2000 cycles | whole system relaxes |
| `opt_temp` | heating/NVT | 1 ns | 1 K to 300 K, Langevin thermostat |
| `opt_pres` | NPT equilibration | 1 ns | 300 K, 1 pressure target, barostat |
| `md` | NPT production | 1 ns default | sampling for NMR frames |
| `md_long` | NPT production | 20 ns | optional longer sampling |
| `md_gamd` | GaMD | 100 ps template | enhanced sampling, dual boost |
| `md_qmmm` | QM/MM MD | 10 ps template | residue 1 QM via external Gaussian |

---

## 43. Gaussian parameter reference

| Gaussian component | Current behavior | Meaning |
|---|---|---|
| Functional | `wB97XD` | dispersion-aware range-separated DFT |
| NMR method | `GIAO` | gauge-including atomic orbitals for shieldings |
| Atom selection | `ReadAtoms` + `atoms=...` | compute/report selected solute protons |
| Solvent | `IEFPCM,Solvent=Water` | implicit water continuum |
| SCF | `XQC,Tight` | robust convergence |
| Grid | `UltraFine` | response-property stability |
| Light basis | `6-311++G(2df,2pd)` | high-quality light-atom basis |
| Water full-QM basis | `6-31G(d)` | lower-cost explicit water basis |
| Au/S/Se | custom basis/ECP files | heavy-element ECP handling |
| Point-charge water | Gaussian `Charge` keyword | fixed electrostatic embedding |

---

# Part X — Validation and troubleshooting logic

---

## 44. Resume markers

Each stage writes `.ok` only after output validation. Existing `.ok` markers are trusted only if expected files exist. Otherwise the marker is removed and the stage is rebuilt.

This prevents accidental reuse of half-finished results after disconnects or failed cluster jobs.

## 45. Gaussian validation

A Gaussian output is valid only with normal termination and no error termination. Failed logs are skipped or removed; no shielding is extracted from them.

## 46. tLEaP crash detection

After tLEaP runs, the code scans recent stderr files for errors such as:

```text
corrupted size
munmap_chunk(): invalid pointer
invalid pointer
Aborted
Segmentation fault
```

These are treated as fatal because tLEaP heap corruption can otherwise produce unreliable or missing outputs.

## 47. MCPB cache invalidation

MCPB stages are invalidated if:

- the input MOL2 hash changes,
- previous stages lack `.ok`,
- previous input lacks `add_bonded_pairs`,
- stale `additional_resids` content is detected.

This is intended to prevent stale metal topology from surviving input changes.

## 48. First-shell validation

`select_first_shell_surface.py` aborts if the solvent tail contains unsupported non-water species other than known monatomic ions. This prevents silently sending corrupted solvent clusters to Gaussian.

## 49. Gaussian basis validation

`xyz_to_gfj.sh` aborts if a QM-region element is not in its supported mapping. This prevents Gaussian inputs with missing basis definitions.

---

# Part XI — Known scientific limitations and assumptions

---

## 50. Fixed protonation and tautomeric state

The pipeline does not sample protonation changes or tautomerization. The starting MOL2 defines the protonation state. If the molecule can change protonation near physiological pH, separate structures must be prepared.

## 51. Fixed bonding topology

Amber MD here uses a fixed bonding topology. Bonds do not form or break. Metal coordination must be correct before MD begins.

## 52. Classical sampling quality

One or several nanoseconds may be insufficient for flexible molecules, slow rotamers, ligand rearrangements, peptide conformational changes, or solvent exchange around buried sites.

## 53. Force-field transferability

GAFF/GAFF2 plus MCPB.py is an approximation. The quality of predicted NMR shifts depends strongly on whether the force field samples physically realistic geometries.

## 54. Solvent reduction approximation

The Gaussian calculation is not performed on the full periodic water box. The local solvent environment is reduced. The chosen `water_mode` changes the physical model substantially.

## 55. TMS reference consistency

If `sigma` is manual, it may come from another level of theory or empirical calibration. If automatic, it is internally computed but not necessarily at the exact same basis/ECP level as heavy-element sample frames.

## 56. Peak assignment and equivalence

The pipeline averages by atom id. It does not automatically identify chemically equivalent protons, conformational exchange equivalence, or experimental multiplet structure. It produces shielding-derived peak positions, not spin-spin coupling patterns.

---

# Part XII — Practical reading guide for the generated result

---

## 57. Files to inspect first after a run

### 57.1 Force-field and topology sanity

```text
process/preparations/tleap/<name>.parm7
process/preparations/tleap/<name>.rst7
process/preparations/tleap/sys_leap.pdb
process/preparations/tleap/tleap_run.in
```

For metal systems, inspect whether metal-ligand bonds are present in the final topology.

### 57.2 MD stability

```text
process/run_*/opt_temp/mdinfo
process/run_*/opt_pres/mdinfo
process/run_*/md/mdinfo
```

Look for temperature, pressure, density, energy stability, and absence of SHAKE/coordinate blow-up errors.

### 57.3 Solvent-shell selection

```text
process/run_*/cpptraj/frames/first_shell_summary.tsv
```

Inspect how many waters are retained per frame.

### 57.4 Gaussian success

```text
process/spectrum/gaussian/nmr/frame_*.log
process/spectrum/gaussian/finished_jobs.log
```

Check that all requested frames have normal-terminated logs.

### 57.5 NMR data

```text
process/spectrum/analysis/avg.dat
process/spectrum/analysis/all_peaks.dat
process/spectrum/plotting/<save_as>.png
process/spectrum/plotting/<save_as>_all_peaks.png
```

---

## 58. Minimal conceptual checklist for a scientifically valid run

Before trusting final spectra, verify:

1. The starting MOL2 has correct atom order, charge, bond table, protonation state, and metal connectivity.
2. CREST did not alter connectivity, only coordinates.
3. Antechamber assigned reasonable ligand types.
4. parmchk2 did not produce suspicious missing/zero parameters for important ligand terms.
5. MCPB generated parameters for every intended metal-ligand bond.
6. tLEaP final topology contains all intended metal-ligand bonds.
7. The solvated system is neutralized and has reasonable box size.
8. Minimization and heating finish without large instabilities.
9. Production MD does not show dissociation or structural collapse.
10. cpptraj frames preserve solute-first atom ordering.
11. First-shell selection keeps a plausible number of waters.
12. Gaussian input contains the intended atoms, charges, basis, ECP, and solvent model.
13. Gaussian logs terminate normally.
14. TMS reference is appropriate for the chosen level of theory.
15. Averaging is done over enough frames for the molecular flexibility involved.

---

# Part XIII — Appendix: file-by-file responsibility map

---

## 59. Main scripts

| File | Responsibility |
|---|---|
| `nmr.sh` | global driver and stage order |
| `input_handling.sh` | parse configuration and set defaults |
| `output.sh` | logging and fatal errors |
| `modules.sh` | environment/module checks |
| `jobs.sh` | cluster submission and job waiting |
| `file_modification.sh` | template substitution and runtime patching |
| `utilities.sh` | chemistry and file-format utilities |
| `preparations.sh` | CREST, antechamber, parmchk2, MCPB, tLEaP |
| `simulation.sh` | Amber and cpptraj stage functions |
| `simulation_parallel.sh` | parallel per-replica launching |
| `gauss.sh` | Gaussian input generation and Gaussian job launching |
| `data.sh` | shielding analysis, TMS reference, plotting orchestration |

## 60. Scientific templates

| File | Responsibility |
|---|---|
| `tleap.in` | generic tLEaP solvation/topology template |
| `tleap_spec.in` | tLEaP template with selenium atom-type declaration |
| `mcpb.in` | conceptual MCPB input template |
| `opt_water.in` | restrained solvent minimization |
| `opt_all.in` | full-system minimization |
| `opt_temp.in` | heating/NVT |
| `opt_pres.in` | pressure equilibration/NPT |
| `md.in` | default production MD |
| `md_long.in` | optional 20 ns production MD |
| `md_gamd.in` | optional Gaussian accelerated MD |
| `md_qmmm.in` | optional QM/MM MD |
| `cpptraj.in` | solute-only extraction |
| `cpptraj_all.in` | residue 1-2 extraction |
| `cpptraj_all_di.in` | residue 1-3 extraction |
| `cpptraj_water.in` | closest-water preselection |
| `cpptraj_solvation.in` | all-solvent output for Python first-shell trimming |
| `xyz_to_gfj.sh` | selected XYZ to Gaussian GIAO inputs |
| `split_xyz.sh` | multi-frame XYZ splitting |
| `select_first_shell_surface.py` | van der Waals surface water-shell selector |
| `select_interact.py` | MDAnalysis hydrogen-bonding water selector |
| `gjf_to_plot.awk` | Gaussian shielding-to-shift extraction |
| `ref_sigma.awk` | reference shielding extraction from Gaussian logs |
| `log_to_plot.sh` | per-log extraction wrapper |
| `average_plot.sh` | average chemical shifts by atom id |

---

## 61. Final conceptual summary

The pipeline constructs a solvated Amber model from a molecular structure, samples the finite-temperature explicit-solvent ensemble, extracts representative solute/solvent clusters, computes quantum-mechanical proton shieldings for those clusters with Gaussian GIAO NMR, references those shieldings to TMS, and produces averaged and distribution-style proton NMR spectra.

The most important scientific interface points are:

- **MOL2 connectivity**: defines intended molecular topology.
- **MCPB/tLEaP metal-center integration**: determines whether metal complexes remain chemically intact during MD.
- **Amber MD parameters**: define the ensemble being sampled.
- **cpptraj/Python solvent selection**: defines what local solvent environment Gaussian sees.
- **Gaussian route/basis/ECP choices**: define the quantum-mechanical shielding model.
- **TMS reference**: defines the zero point of chemical shifts.
- **frame averaging**: defines the final ensemble-averaged NMR estimate.

Every final peak is therefore the result of a long chain:

```text
input structure
  -> force-field/topology assumptions
  -> classical ensemble sampling
  -> frame selection
  -> quantum shielding calculation
  -> reference subtraction
  -> averaging by atom identity
```

Understanding or debugging a predicted chemical shift means walking backward through that chain.

---

# Part XIV — Stage cards: exact inputs, transformations, and outputs

This section is intentionally operational. It documents each stage as a reproducible card with: entry condition, input files, scientific transformation, output files, and failure meaning.

---

## 62. Stage card: `read_config` / `load_cfg`

### Entry condition

The project root contains:

```text
inputs/sim.txt
```

### Input

`inputs/sim.txt`, using `key:=value` assignments.

### Transformation

The configuration is converted into shell variables. Those variables are not local to one stage; they become the global contract for the whole pipeline. This is why a wrong value in `sim.txt` can propagate far downstream.

### Scientific outputs

No chemical object is produced, but the following scientific choices are fixed:

- total charge,
- metal charge,
- water model at MD stage,
- water handling at Gaussian stage,
- number of frames and replicas,
- MD templates,
- DFT referencing behavior.

### Failure meaning

If this stage fails, the pipeline is not scientifically initialized. No partial result should be interpreted.

---

## 63. Stage card: atom-count extraction

### Entry condition

A MOL2 file exists at:

```text
inputs/structures/<name>.mol2
```

### Input

The `@<TRIPOS>MOLECULE` count line.

### Transformation

The first integer of the count line becomes `LIMIT`.

### Output

A global integer:

```text
LIMIT = number of solute atoms
```

### Scientific meaning

`LIMIT` is later used as the boundary between solute atoms and water/ion atoms in every selected XYZ frame. This means it controls:

- which atoms are included in the Gaussian solute block,
- which hydrogens are included in the NMR `atoms=` list,
- which hydrogens are extracted from Gaussian logs,
- where water/point-charge atoms begin.

### Failure mode

If `LIMIT` is wrong, Gaussian input generation and NMR peak extraction become wrong even if MD itself ran correctly.

---

## 64. Stage card: `run_crest`

### Entry condition

`input_type=mol2` and `<name>.mol2` exists.

### Inputs

```text
inputs/structures/<name>.mol2
charge
mamba/conda environment path
```

### Transformation

1. Convert MOL2 to XYZ.
2. Optionally xTB pre-optimize in implicit water.
3. Run CREST job if no final CREST geometry exists.
4. Merge optimized coordinates with original MOL2 connectivity.
5. Sanitize coordinates for MCPB compatibility.

### Outputs

```text
process/preparations/crest/<name>.xyz
process/preparations/crest/crest_best.xyz
process/preparations/crest/<name>_crest.mol2
```

### Scientific object produced

A relaxed conformer with the original bond table preserved.

### Key scientific assumption

The original MOL2 bond table is chemically authoritative. CREST/xTB may improve coordinates but does not define final covalent topology.

---

## 65. Stage card: `run_antechamber`

### Entry condition

`<name>_crest.mol2` exists.

### Inputs

```text
process/preparations/crest/<name>_crest.mol2
antechamber parameter string
charge
```

### Transformation

1. Copy CREST MOL2.
2. Detect metal.
3. If metal exists:
   - preserve full metal-containing MOL2,
   - strip metal for ligand-only GAFF typing,
   - force `-c dc -dr no` for antechamber.
4. Fix placeholder atom names.
5. Force selenium atom names to a consistent uppercase form where needed.
6. Run antechamber.
7. Preserve raw output for parmchk2.
8. Apply selenium/silicon downstream custom retagging.
9. Rebuild full ligand+metal MOL2 if metal workflow is active.

### Outputs

```text
process/preparations/antechamber/<name>_charges.mol2
process/preparations/antechamber/<name>_charges_antechamber_raw.mol2
process/preparations/antechamber/<name>_charges_full.mol2
```

### Scientific object produced

A GAFF/GAFF2-typed ligand MOL2 and, where needed, a full metal-containing MOL2 for MCPB.

### Key scientific assumption

The organic ligand can be reasonably described by GAFF-like atom types, while the metal center requires a specialized treatment.

---

## 66. Stage card: `run_parmchk2`

### Entry condition

Antechamber output exists.

### Inputs

```text
<name>_charges_antechamber_raw.mol2
<name>_charges_full.mol2, when present
parmchk2 parameter string
```

### Transformation

1. Copy raw antechamber ligand MOL2.
2. Strip metal if accidentally present.
3. Run parmchk2.
4. Ensure a syntactically valid frcmod exists.

### Outputs

```text
process/preparations/parmchk2/<name>.frcmod
process/preparations/parmchk2/<name>_charges_full.mol2, when present
```

### Scientific object produced

A supplement force-field parameter file for ligand terms absent from the base force field.

### Key scientific assumption

For missing organic parameters, parmchk2 estimates are acceptable as a first-order GAFF-like model.

---

## 67. Stage card: `run_mcpb`

### Entry condition

A full metal-containing MOL2 exists and `mcpb` configuration is non-empty.

### Inputs

```text
process/preparations/parmchk2/<name>_charges_full.mol2
process/preparations/parmchk2/<name>.frcmod
charge
metal_charge
mcpb command string
```

### Transformation

1. Detect metal atom.
2. Build MCPB PDB with ligand and metal in separate residues.
3. Build ligand and ion MOL2 files.
4. Enforce charge consistency.
5. Extract intended metal-bonded atoms from MOL2.
6. Create MCPB input with explicit `add_bonded_pairs`.
7. Run MCPB step 1 to create QM inputs.
8. Patch Gaussian inputs.
9. Run Gaussian small/large model jobs.
10. Run MCPB parameter generation.
11. Validate presence of MCPB outputs.

### Outputs

```text
process/preparations/mcpb/01_step1/<name>_mcpb.pdb
process/preparations/mcpb/01_step1/LIG.mol2
process/preparations/mcpb/01_step1/<METAL>.mol2
process/preparations/mcpb/02_qm/*.log
process/preparations/mcpb/03_params/<name>_mcpbpy.frcmod
process/preparations/mcpb/03_params/<name>_tleap.in
process/preparations/mcpb/03_params/<name>_mcpbpy.pdb
```

### Scientific object produced

A bonded Amber-compatible representation of the metal coordination center.

### Key scientific assumption

The metal coordination state is fixed and can be represented by harmonic bonded terms around the QM-derived geometry.

---

## 68. Stage card: `run_nemesis_fix`

### Entry condition

Antechamber output exists.

### Inputs

```text
process/preparations/antechamber/<name>_charges.mol2
```

### Transformation

1. Open Babel MOL2-to-MOL2 normalization.
2. Normalize MOL2 metadata.
3. Reapply selenium/silicon custom retagging.

### Outputs

```text
process/preparations/nemesis_fix/<name>_charges_fix.mol2
```

### Scientific object produced

A tLEaP-friendlier MOL2 representation of the ligand.

### Key scientific assumption

Open Babel normalization improves file compatibility without changing intended chemistry. Because Open Babel can alter metadata, custom atom-type patches must be reapplied afterward.

---

## 69. Stage card: `run_tleap`

### Entry condition

Ligand MOL2, ligand frcmod, optional MCPB outputs, and tLEaP template exist.

### Inputs

```text
process/preparations/parmchk2/<name>.frcmod
process/preparations/nemesis_fix/<name>_charges_fix.mol2
process/preparations/crest/<name>_crest.mol2
inputs/params/leaprc.zf
inputs/params/gaff.zf
inputs/params/frcmod.si_tms
inputs/simulation/<tleap>.in
MCPB outputs, when present
```

### Transformation

1. Copy parameter and structure inputs into tLEaP workdir.
2. Inject selenium and silicon patches if required.
3. Import MCPB parameters and libraries if present.
4. Reconcile MCPB PDB/template naming.
5. Filter/regenerate metal bonds from authoritative connectivity.
6. Sanitize/de-duplicate tLEaP commands.
7. Inject D2O mass override if requested.
8. Run tLEaP.
9. Validate topology and restart presence.

### Outputs

```text
process/preparations/tleap/<name>.parm7
process/preparations/tleap/<name>.rst7
process/preparations/tleap/sys_leap.pdb
process/preparations/tleap/tleap_run.in
```

### Scientific object produced

The complete explicit-solvent Amber simulation system.

### Key scientific assumption

All required force-field layers have been loaded in the correct order, and final atom types match final bonded parameters.

---

## 70. Stage card: `run_sim_step_parr`

### Entry condition

tLEaP outputs exist.

### Inputs

```text
md_iterations
stage name
stage template name
```

### Transformation

Launches the selected stage once for each replica directory:

```text
run_0, run_1, ..., run_<md_iterations-1>
```

### Outputs

A completed stage directory under each run.

### Scientific object produced

Independent MD branches for sampling.

---

## 71. Stage card: `run_cpptraj_parr`

### Entry condition

Production MD is complete in every replica.

### Inputs

```text
<name>_md.mdcrd
<name>.parm7
cpptraj template
LIMIT
frame-number offset
cpptraj_mode
```

### Transformation

1. Run cpptraj per replica.
2. Convert trajectory snapshots to frame files.
3. Run Python post-processing depending on mode.
4. Move finished frames into `process/spectrum/frames`.

### Outputs

```text
process/spectrum/frames/frame_0.xyz
process/spectrum/frames/frame_1.xyz
...
```

### Scientific object produced

A frame ensemble prepared for quantum NMR calculation.

---

## 72. Stage card: `run_gauss_prep`

### Entry condition

All requested frame XYZ files exist.

### Inputs

```text
process/spectrum/frames/frame_*.xyz
LIMIT
charge
water_mode
basis/ECP files
```

### Transformation

1. Copy frames.
2. Substitute variables into `xyz_to_gfj.sh`.
3. Generate one Gaussian GIAO NMR input per frame.

### Outputs

```text
process/spectrum/gauss_prep/gauss/frame_*.gjf
```

### Scientific object produced

Frame-wise quantum chemistry input files.

---

## 73. Stage card: `run_gaussian`

### Entry condition

Gaussian `.gjf` files exist.

### Inputs

```text
frame_*.gjf
Gaussian module
GAUSS_MEM_GB / GAUSS_NCPUS
```

### Transformation

1. Create one job directory per frame.
2. Patch resources.
3. Submit Gaussian jobs.
4. Validate logs.
5. Copy valid logs into a common NMR directory.

### Outputs

```text
process/spectrum/gaussian/nmr/frame_*.log
```

### Scientific object produced

Quantum-mechanical magnetic shielding tensors for each selected frame.

---

## 74. Stage card: `run_analysis`

### Entry condition

Gaussian logs exist and terminate normally.

### Inputs

```text
frame_*.log
sigma
LIMIT
```

### Transformation

1. Copy logs.
2. If needed, compute TMS reference shielding.
3. Extract H isotropic shieldings for atoms `<= LIMIT`.
4. Convert to ppm shifts.
5. Average by atom id.
6. Concatenate all peaks.

### Outputs

```text
avg.dat
all_peaks.dat
plots/plot_frame_*.dat
```

### Scientific object produced

Numerical predicted proton chemical shifts.

---

## 75. Stage card: `run_plotting`

### Entry condition

Analysis outputs exist.

### Inputs

```text
avg.dat
all_peaks.dat
filter
```

### Transformation

Run gnuplot scripts; optionally filter selected hydrogens.

### Outputs

```text
<save_as>.png
<save_as>_all_peaks.png
```

### Scientific object produced

Visualized averaged and distribution-level NMR spectra.

---

# Part XV — Detailed data lineage

The following lineage shows how one atom and one frame move through the pipeline.

## 76. Atom identity lineage

```text
inputs/structures/<name>.mol2
  atom id and atom name defined
  bond table defined
      ↓
crest/<name>_crest.mol2
  same atom order and connectivity, optimized coordinates
      ↓
antechamber/<name>_charges.mol2
  atom types and charges assigned/retyped
      ↓
parmchk2/<name>.frcmod
  missing parameters estimated for these atom types
      ↓
mcpb/... outputs
  coordinated atoms may receive MCPB Y* types
      ↓
tleap/<name>.parm7
  final atom names, atom types, charges, masses, bonds, angles
      ↓
md trajectory
  atom coordinates through time
      ↓
cpptraj XYZ
  atom names and positions exported
      ↓
Gaussian gjf
  element symbols and coordinates written
      ↓
Gaussian log
  isotropic shielding for selected atoms
      ↓
avg.dat/all_peaks.dat
  atom id mapped to chemical shift
```

The pipeline relies on atom order staying stable enough that atom id remains meaningful from input through Gaussian extraction.

## 77. Frame lineage

```text
run_i/md/<name>_md.mdcrd
  production trajectory
      ↓
run_i/cpptraj/<name>_frame.xyz
  multi-frame XYZ after imaging/centering/extraction
      ↓
run_i/cpptraj/frames/frame_N.xyz
  one XYZ file per selected frame
      ↓
spectrum/frames/frame_N.xyz
  global frame collection
      ↓
spectrum/gauss_prep/gauss/frame_N.gjf
  Gaussian NMR input
      ↓
spectrum/gaussian/nmr/frame_N.log
  Gaussian output
      ↓
spectrum/analysis/plots/plot_frame_N.dat
  per-frame ppm peaks
```

---

# Part XVI — Deeper scientific explanation of NMR calculation choices

## 78. Absolute shielding versus chemical shift

Gaussian reports magnetic shieldings, typically denoted σ. Experimental NMR spectra report chemical shifts δ. The relation used here is the simplest reference relation:

```text
δ_i = σ_ref - σ_i
```

where:

- `σ_ref` is the isotropic shielding of TMS hydrogens,
- `σ_i` is the isotropic shielding of solute hydrogen `i`.

The result is in ppm because Gaussian shieldings are in ppm-like shielding units.

## 79. Why isotropic shielding is used

Gaussian shielding tensors are anisotropic rank-2 tensors. For liquid-state NMR, fast molecular tumbling averages tensor orientation, so the isotropic shielding is the relevant scalar:

```text
σ_iso = (σ_xx + σ_yy + σ_zz) / 3
```

Gaussian prints `Isotropic = ...`, and the AWK scripts parse that value.

## 80. Why GIAO is used

Magnetic properties depend on the gauge origin. GIAO basis functions include gauge factors that make computed shieldings less sensitive to arbitrary coordinate origin. This is standard for DFT NMR shielding calculations.

## 81. Why frame averaging is by atom id

Each frame contains the same solute atom ids. The pipeline computes one shift per atom per frame and then averages that atom’s shift over frames. This approximates the ensemble average:

```text
<δ_i> = average over MD frames of δ_i(frame)
```

This is valid when atom identity is chemically meaningful and the sampled ensemble is representative.

## 82. What the pipeline does not compute

The pipeline does not compute:

- scalar J-couplings,
- multiplet splitting,
- relaxation times,
- exchange broadening,
- chemical exchange rates,
- automatic equivalent-proton grouping,
- explicit Boltzmann reweighting beyond MD sampling,
- quantum nuclear effects except optional D mass substitution for water.

The plots are therefore chemical-shift spectra/peak distributions, not full experimental line-shape simulations.

---

# Part XVII — Deeper explanation of water models at the Gaussian stage

## 83. `discard` mode

### Model

```text
QM region = solute only
environment = PCM water
```

### Strengths

- fastest,
- simplest,
- avoids basis problems for water clusters,
- good for rough screening.

### Weaknesses

- misses specific hydrogen bonds,
- misses instantaneous electrostatic fields from first-shell water,
- can underrepresent local deshielding/shielding effects near polar sites.

## 84. `point_charges` mode

### Model

```text
QM region = solute only
external charges = selected water O/H charges
environment = PCM water
```

### Strengths

- captures first-shell electrostatic field cheaply,
- avoids extra QM basis cost,
- water protons cannot contaminate plotted proton spectrum.

### Weaknesses

- no electronic polarization of water,
- no charge transfer or exchange interaction with water,
- point-charge values assume a water model charge distribution.

### Critical syntax detail

Gaussian external charges must appear immediately after the molecular coordinate section when `Charge` is used. The generator does this explicitly.

## 85. `full_qm` mode

### Model

```text
QM region = solute + selected waters
environment = PCM water
```

### Strengths

- explicit local water electronic structure,
- explicit hydrogen bonding in the QM density,
- potentially best for strongly H-bonded protons.

### Weaknesses

- expensive,
- larger SCF convergence burden,
- water selection strongly affects result,
- water protons are present in the QM system but deliberately excluded from target peak extraction.

---

# Part XVIII — Metal-complex documentation and safety logic

## 86. Why metal complexes are special

Organic force fields usually assume covalent bonds with transferable parameters. Metal coordination is less transferable because:

- coordination geometry depends on oxidation state,
- metal-ligand bonds are partially covalent and partially ionic,
- bond lengths and force constants depend strongly on ligand field,
- ordinary GAFF atom types do not contain metal-center bonded terms,
- antechamber cannot infer reliable transition-metal bonded models.

Therefore, the pipeline uses MCPB.py.

## 87. Metal-ligand topology is not optional

If a metal is chemically coordinated to ligand atoms, those bonds must appear in the final topology. Otherwise the classical model does not represent the target complex.

A correct topology must include:

```text
metal--coordinating atom bonds
metal-centered angles
compatible atom types
compatible bond/angle parameters
```

If any intended bond is missing, the MD may show artificial dissociation. This is not a valid prediction of bond breaking; it is a parameterization failure.

## 88. PDB/MOL2 naming hazard

MCPB.py and tLEaP often use PDB-safe four-character atom names. A MOL2 atom named `Se284` may become `SE28` in PDB/tLEaP. If bond reconstruction compares names literally without canonicalization, the intended bond can disappear.

The robust way to handle this is:

- use atom ids where possible,
- canonicalize atom names across MOL2/PDB/tLEaP contexts,
- validate final `parm7` bonds after tLEaP.

## 89. What should be validated for gold/selenium complexes

For an Au–Se complex, check:

```text
Au--C or Au--carbene bond present
Au--Se bond present
Se--C organic bond present
Au type matches MCPB metal type, e.g. M1
Se-side coordinated atom type matches MCPB Y* type or equivalent patch
Y*-M1 bond parameter exists
Y*-M1-Y* or M1-Y*-neighbor angle parameters exist
```

The presence of good starting coordinates is not enough. The final `parm7` is the source of truth for MD.

---

# Part XIX — Exhaustive parameter glossary

## 90. Amber minimization parameters

| Parameter | Meaning in this pipeline |
|---|---|
| `imin=1` | run minimization instead of MD |
| `maxcyc` | total minimization cycles |
| `ncyc` | switch point between steepest descent and conjugate gradient |
| `ntb=1` | periodic constant-volume context |
| `cut` | direct-space nonbonded cutoff in Å |
| `ntc=1` | no bond constraints |
| `ntf=1` | evaluate all bond forces |
| `ntr=1` | enable positional restraints |
| `restraint_wt` | restraint force constant |
| `restraintmask` | atom selection restrained |
| `ntpr` | print frequency |

## 91. Amber MD parameters

| Parameter | Meaning in this pipeline |
|---|---|
| `imin=0` | run dynamics |
| `nstlim` | number of MD steps |
| `dt` | timestep in ps |
| `ntb=1` | NVT-style periodic dynamics |
| `ntb=2` | NPT periodic dynamics |
| `cut` | nonbonded cutoff |
| `ntc=2` | constrain bonds involving hydrogen |
| `ntf=2` | do not compute forces for constrained bonds |
| `irest=0` | start new MD without previous velocities |
| `irest=1` | restart from previous velocities |
| `ntx=1` | read coordinates only |
| `ntx=5` | read coordinates and velocities |
| `ntt=3` | Langevin thermostat |
| `tempi` | initial temperature for velocity generation |
| `temp0` | target temperature |
| `gamma_ln` | Langevin collision frequency |
| `ig=-1` | randomize seed |
| `ntp=1` | isotropic pressure scaling |
| `pres0` | target pressure |
| `taup` | pressure relaxation time |
| `barostat` | Amber barostat selection |
| `ntpr` | energy print interval |
| `ntwx` | coordinate trajectory write interval |
| `ntwr` | restart write interval |
| `iwrap` | wrapping behavior |
| `ioutfm=1` | NetCDF output |
| `ntxo=2` | NetCDF restart output |

## 92. cpptraj commands

| Command | Meaning |
|---|---|
| `parm` | load Amber topology |
| `trajin` | load trajectory frames, with start/end/stride |
| `autoimage` | make molecules whole and image around anchor |
| `strip` | remove atoms/residues by mask |
| `closest` | select closest solvent molecules |
| `center :1 mass origin` | center solute residue by mass |
| `image origin center` | image solvent around centered solute |
| `trajout ... xyz ... multi` | write multi-frame XYZ |

## 93. Gaussian route keywords

| Keyword | Meaning |
|---|---|
| `#P` | verbose Gaussian output |
| `wB97XD` | selected DFT functional |
| `Gen` | custom general basis input follows |
| `GenECP` | custom basis plus ECP input follows |
| `NMR=GIAO` | compute NMR shieldings with GIAO method |
| `ReadAtoms` | read atom selection for NMR output |
| `Charge` | read external point charges |
| `NoSymm` | disable symmetry |
| `SCRF=(IEFPCM,Solvent=Water)` | implicit water continuum |
| `SCF=(XQC,Tight)` | robust/tight SCF convergence |
| `Int=UltraFine` | fine integration grid |
| `CPHF=Grid=UltraFine` | fine response-property grid |

---

# Part XX — Debugging by symptom

## 94. Symptom: metal ligand drifts away during MD

Likely cause:

- missing metal-ligand bond in final topology,
- wrong MCPB Y* type assignment,
- missing bond/angle parameter,
- tLEaP loaded ligand MOL2 instead of MCPB PDB/library,
- atom-name mismatch between MOL2 and PDB.

Check:

```text
preparations/tleap/tleap_run.in
preparations/tleap/<name>.parm7
MCPB <name>_tleap.in
MCPB <name>_mcpbpy.frcmod
```

## 95. Symptom: tLEaP says atom type unknown

Likely cause:

- MCPB template not loaded,
- residue name mismatch between PDB and MOL2/off library,
- custom selenium/silicon type not declared,
- missing `addAtomTypes` for MCPB-generated Y* types.

## 96. Symptom: Gaussian input generation fails with unsupported element

Likely cause:

- selected QM region contains an element not listed in `LIGHT_ORDER` and not handled separately,
- water/ion tail contains an ion that was not stripped,
- atom name is not parseable as an element.

Fix:

- add basis/ECP mapping for that element,
- ensure solvent-tail selection removes non-water species,
- normalize atom names before Gaussian conversion.

## 97. Symptom: no NMR peaks extracted

Likely cause:

- Gaussian logs did not terminate normally,
- `atoms=` list empty because solute hydrogens were not named with `H...`,
- `LIMIT` too small/large,
- Gaussian output format differs from AWK parser expectation,
- no hydrogen atoms in target solute.

## 98. Symptom: final spectrum contains water proton peaks

Likely cause:

- `LIMIT` includes water atoms accidentally,
- atom ordering changed so waters appear before solute boundary,
- water atoms were included in the solute block.

The intended logic excludes hydrogens with `atom > LIMIT`.

## 99. Symptom: too few or too many selected waters

Likely cause:

- `shell_surface_cutoff` too small or too large,
- solute hydrogens included/excluded unexpectedly,
- VDW radius table inappropriate for a heavy atom,
- cpptraj imaging produced broken solvent placement,
- frame comment lacks usable box and minimum-image correction was not applied.

## 100. Symptom: Gaussian SCF failures

Likely cause:

- too many explicit QM waters,
- metal/ECP basis issue,
- charged cluster too difficult,
- poor geometry from MD snapshot,
- strong point-charge field too close to QM atoms,
- insufficient memory/scratch.

Potential mitigations:

- use `point_charges` instead of `full_qm`,
- reduce shell cutoff,
- inspect problematic frame geometry,
- increase memory/scratch,
- tighten or adjust SCF settings carefully.

---

# Part XXI — Documentation-level pseudocode of the whole pipeline

```text
START

read sim.txt
load config variables
check selected templates
LIMIT = atom count from input MOL2

if final data_results/save_as/.ok exists:
    stop

if input_type == mol2:
    CREST:
        mol2 -> xyz
        optional xTB preopt
        crest conformer/geometry job
        write optimized MOL2 using original connectivity

    ANTECHAMBER:
        if metal present:
            preserve full MOL2
            strip metal
            force no new charge derivation
        run antechamber
        preserve raw output
        apply custom Se/Si retagging
        rebuild full metal MOL2 if needed

    PARMCHK2:
        use raw ligand MOL2
        strip metal if still present
        run parmchk2
        ensure frcmod exists

    MCPB:
        if metal present and mcpb configured:
            make PDB and ligand/ion MOL2s
            enforce formal charges
            extract metal bonded pairs
            run MCPB step 1
            patch Gaussian inputs
            run Gaussian QM jobs
            run MCPB parameter generation

    NEMESIS_FIX:
        normalize MOL2 with Open Babel
        reapply custom types

    TLEAP:
        copy ligand and parameters
        inject Se/Si/D2O patches if needed
        import MCPB files if available
        reconcile templates/PDB/residue names
        preserve intended metal bonds
        solvate with OPC3 20 Å box
        neutralize with Na+
        write parm7/rst7/PDB

ensure process/spectrum/frames exists
assert num_frames divisible by md_iterations
increase = num_frames / md_iterations

for each stage in [opt_water, opt_all, opt_temp, opt_pres, md]:
    for each replica run_i in parallel:
        copy previous restart/topology
        substitute Amber input template
        patch runtime settings if needed
        submit Amber job
        validate output

for each replica run_i in parallel:
    cpptraj trajectory extraction
    if no_water mode:
        write multi-frame xyz
        split into frame_N.xyz
        select first-shell waters by surface gap
    else:
        write frames.nc
        select H-bonding waters using MDAnalysis
    copy frames to spectrum/frames

GAUSS_PREP:
    for each frame_N.xyz:
        first LIMIT atoms = solute
        tail = waters
        choose water mode
        choose Gen/GenECP
        write Gaussian GIAO NMR input

GAUSSIAN:
    for each frame_N.gjf:
        patch resources
        submit Gaussian job
        validate log
        copy valid log to nmr directory

ANALYSIS:
    if sigma auto:
        run TMS optimization+NMR
        parse average TMS H shielding
    for each valid frame log:
        parse solute H shieldings
        ppm = sigma_TMS - shielding
        write plot_frame_N.dat
    average by atom id -> avg.dat
    concatenate all frame peaks -> all_peaks.dat

PLOTTING:
    run gnuplot for averaged and all-peaks spectra
    optionally filter alpha/beta hydrogens

ARCHIVE:
    copy process/* -> data_results/save_as
    write final .ok
    clear process/*

END
```

---

# Part XXII — Recommended documentation comments to keep near the code

The following concise statements capture the most important scientific invariants and are worth keeping near the codebase.

## 101. Connectivity invariant

> The original or CREST-preserved MOL2 bond table is the authoritative molecular topology. XYZ conversion must not be allowed to define bonds by distance, especially for metal complexes.

## 102. Solute-boundary invariant

> The first `LIMIT` atoms in exported XYZ frames are assumed to be the solute atoms. Gaussian target atoms and shielding extraction depend on this ordering.

## 103. Metal-center invariant

> Every intended metal-ligand bond must exist in the final Amber topology. A good starting geometry is insufficient if `parm7` lacks the bond.

## 104. Gaussian solvent invariant

> Water selected from MD is not automatically QM water. It is discarded, converted to point charges, or included as QM atoms according to `water_mode`.

## 105. NMR target invariant

> Only solute hydrogens are selected and plotted. Water hydrogens are excluded by the `LIMIT` boundary.

## 106. Resume invariant

> A stage `.ok` marker is meaningful only together with validated output files. If outputs are missing or invalid, the stage must be rebuilt.

---

# Part XXIII — End-to-end scientific statement

The pipeline predicts solute proton chemical shifts in water by combining classical thermodynamic sampling with quantum-mechanical shielding calculations. It assumes that the classical model correctly samples relevant conformations and local solvent configurations, then maps each sampled structure to a Gaussian GIAO NMR problem. The result is an ensemble average over MD-derived quantum shieldings. The strongest sources of scientific sensitivity are metal-center topology, protonation state, solvent-shell definition, DFT/basis/ECP choice, and sampling length.
