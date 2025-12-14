# shellcheck disable=SC2148
# Guard so we don't load twice
[[ ${_PREPARATION_SH_LOADED:-0} -eq 1 ]] && return
_PREPARATION_SH_LOADED=1

INPUTS="inputs"

# run_crest NAME DIRECTORY META ENV
# Runs everything pertaining crest
# Globals: none
# Returns: Nothing
run_crest() {
	#Load the inputs
	local name=$1
	local directory=$2
	local meta=$3
	local env=$4

	local job_name="crest"

	info "Started running $job_name"

    #Start by converting the input mol into a xyz format -necessary for crest
	JOB_DIR="process/preparations/$job_name"
	ensure_dir $JOB_DIR

	#Constrcut the job file
	if [[ $meta == "true" ]]; then
		module add openbabel > /dev/null 2>&1
		substitute_name_sh_meta_start "$JOB_DIR" "${directory}" "$env"
		substitute_name_sh_meta_end "$JOB_DIR"
		substitute_name_sh "crest_metacentrum" "$JOB_DIR" "" "${name}" "" "" "" ""
		construct_sh_meta "$JOB_DIR" "$job_name"
	else
		module add obabel > /dev/null 2>&1
		substitute_name_sh_wolf_start "$JOB_DIR"
		substitute_name_sh "$job_name" "$JOB_DIR" "$job_name" "${name}" "" "" "" ""
		construct_sh_wolf "$JOB_DIR" "$job_name"
	fi

    obabel -imol2 "${INPUTS}/structures/${name}.mol2" -oxyz -O "${JOB_DIR}/${name}.xyz" > /dev/null 2>&1
    #Run the crest simulation
    submit_job "$meta" "$job_name" "$JOB_DIR" 4 16 0 "08:00:00"
    #Convert back to mol2 format
    obabel -ixyz "${JOB_DIR}/crest_best.xyz" -omol2 -O "${JOB_DIR}/${name}_crest.mol2" > /dev/null 2>&1
	#Convert the symbols
	sed -i 's/AU/Au /' "${JOB_DIR}/${name}_crest.mol2"

	#Check that the final files are truly present
	check_res_file "${name}_crest.mol2" "$JOB_DIR" "$job_name"

	success "$job_name has finished correctly"

	#Write to the log a finished operation
	add_to_log "$job_name" "$LOG"
}

# run_antechamber NAME DIRECTORY META AMBER
# Runs everything pertaining to antechmaber
# Globals: none
# Returns: Nothing
run_antechamber() {
	#Load the inputs
	local name=$1
	local directory=$2
	local meta=$3
	local amber=$4
	local antechamber_parms=$5
	local charge=$6

	local job_name="antechamber"

	info "Started running $job_name"

	#Start by converting the input mol into a xyz format -necessary for crest
	JOB_DIR="process/preparations/$job_name"
	ensure_dir "$JOB_DIR"

	SRC_DIR="process/preparations/crest"

	#Copy the data from crest
	move_inp_file "${name}_crest.mol2" "$SRC_DIR" "$JOB_DIR"

	# --- Heavy-metal handling --------------------------------------------
	# If the original structure contains a heavy metal (e.g. Au),
	# AM1-BCC (sqm) will fail because it has no parameters for that element.
	# In that case, tell antechamber to *reuse* the input charges (-c rc)
	# and avoid calling sqm completely.
	local struct_file="${INPUTS}/structures/${name}.mol2"
	if has_heavy_metal "$struct_file"; then
		info "Heavy metal detected in $struct_file; forcing antechamber to use input charges (-c rc) instead of AM1-BCC."

		# Generate a stable charge file from the ORIGINAL input mol2
		# (crest/openbabel mol2 often does not preserve partial charges).
		local chg_file="${JOB_DIR}/${name}.crg"
		mol2_write_charge_file "$struct_file" "$chg_file"

		# Strip any existing "-c <...>", "-cf <...>", "-dr <...>" from user parameters
		# and force:
		#   -c rc   (read charges)
		#   -cf ... (charge file)
		#   -dr no  (disable unusual-element checking)
		# Everything else (-at, etc.) stays as configured in sim.txt.
		local base_parms
		base_parms=$(printf '%s\n' "$antechamber_parms" | sed -E \
			's/(^|[[:space:]])-c[[:space:]]+[[:alnum:]]+//g;
			 s/(^|[[:space:]])-cf[[:space:]]+[^[:space:]]+//g;
			 s/(^|[[:space:]])-dr[[:space:]]+[[:alnum:]]+//g')
		antechamber_parms="${base_parms} -c rc -cf ${name}.crg -dr no"

	fi
	# ---------------------------------------------------------------------

	#Constrcut the job file
	if [[ $meta == "true" ]]; then
		substitute_name_sh_meta_start "$JOB_DIR" "${directory}" ""
		substitute_name_sh_meta_end "$JOB_DIR"
		substitute_name_sh "$job_name" "$JOB_DIR" "$amber" "$name" "" "" "$antechamber_parms" "$charge"
		construct_sh_meta "$JOB_DIR" "$job_name"
	else
		substitute_name_sh_wolf_start "$JOB_DIR"
		substitute_name_sh "$job_name" "$JOB_DIR" "$amber" "$name" "" "" "$antechamber_parms" "$charge"
		construct_sh_wolf "$JOB_DIR" "$job_name"
	fi

	#Run the antechamber
	submit_job "$meta" "$job_name" "$JOB_DIR" 4 4 0 "01:00:00"

	#Check that the final files are truly present
	check_res_file "${name}_charges.mol2" "$JOB_DIR" "$job_name"

	success "$job_name has finished correctly"

	#Write to the log a finished operation
	add_to_log "$job_name" "$LOG"
}


# run_mcpb NAME DIRECTORY META AMBER
# Runs MCPB.py metal-center parametrization and merges the resulting frcmod
# into the standard parmchk2 frcmod.
# Globals: mcpb_cmd
# Returns: Nothing
run_mcpb()
{
    local in_mol2=$1

    local JOB_DIR="process/preparations/mcpb"
    local OUT_FRCMOD="$JOB_DIR/mcpbpy.frcmod"

    log_info "Started running mcpb"

    # Prepare the directory
    mkdir -p "$JOB_DIR" || { log_err "Failed to create $JOB_DIR"; exit 2; }
    rm -f "$JOB_DIR"/* 2>/dev/null || true

    # Only allowed input: mol2 from antechamber
    cp "$in_mol2" "$JOB_DIR/${name}_charges.mol2" || {
        log_err "Failed to copy $in_mol2 to $JOB_DIR/${name}_charges.mol2"
        exit 2
    }

    # Generate the MCPB .in (with placeholders filled later inside the job)
    cat > "$JOB_DIR/${name}_mcpb.in" <<EOF
original_pdb ${name}_mcpb.pdb
group_name ${name}
cut_off 2.8
ion_ids __ION_ID__
ion_mol2files __ION_MOL2__
naa_mol2files LIG.mol2
frcmod_files LIG.frcmod
EOF

    # Create metacentrum start/end wrappers
    # MCPB+Gaussian typically needs more mem than antechamber/parmchk2
    substitute_name_sh_meta_start "$JOB_DIR" "$name" "" "32" "8" "1"
    substitute_name_sh_meta_end "$JOB_DIR"

    # Create the actual job body (job_file.txt) so we are not dependent on lib templates
    cat > "$JOB_DIR/job_file.txt" <<EOF
set -e

module add ${amber_mod} ${gauss_mod}

# Decide the input mol2 (we always copy ${name}_charges.mol2 here)
IN_MOL2="${name}_charges.mol2"
test -f "\$IN_MOL2" || { echo >&2 "Missing \$IN_MOL2"; exit 2; }

# From mol2 only, generate:
# - ${name}_mcpb.pdb   (metal is its own residue, e.g. AU)
# - LIG.mol2           (all atoms except the metal)
# - <METAL>.pdb        (single-atom metal pdb)
# - metal_sym.txt, ion_id.txt, metal_charge_int.txt
python3 - <<'PY'
import re
from pathlib import Path

mol2_path = Path("${name}_charges.mol2")
lines = mol2_path.read_text().splitlines()

def find_idx(tag):
    for i, l in enumerate(lines):
        if l.strip() == tag:
            return i
    return None

i_mol = find_idx("@<TRIPOS>MOLECULE")
i_at  = find_idx("@<TRIPOS>ATOM")
i_bd  = find_idx("@<TRIPOS>BOND")
i_sb  = find_idx("@<TRIPOS>SUBSTRUCTURE")

if i_mol is None or i_at is None or i_bd is None:
    raise SystemExit("mol2 is missing required sections")

# Atom lines go until next section tag
def section_end(start):
    for j in range(start+1, len(lines)):
        if lines[j].startswith("@<TRIPOS>"):
            return j
    return len(lines)

at_end = section_end(i_at)
bd_end = section_end(i_bd)

atom_lines = lines[i_at+1:at_end]
bond_lines = lines[i_bd+1:bd_end]

metals = {
    "Au","Ag","Pt","Pd","Hg","Zn","Fe","Cu","Co","Ni","Mn","Mo","W","Ir","Os","Ru","Rh","Cd","Pb","Sn","Bi","Cr","V","Ti","Zr"
}

atoms = []
tot_q = 0.0
metal_atom = None

for l in atom_lines:
    if not l.strip():
        continue
    # id name x y z type subst_id subst_name charge
    parts = l.split()
    if len(parts) < 9:
        continue
    aid = int(parts[0])
    aname = parts[1]
    x,y,z = map(float, parts[2:5])
    atype = parts[5]
    subst_id = parts[6]
    subst_name = parts[7]
    q = float(parts[8])
    tot_q += q

    m = re.match(r"[A-Za-z]+", aname)
    elem = m.group(0) if m else aname
    elem = elem[0].upper() + (elem[1:].lower() if len(elem) > 1 else "")
    if (elem in metals) and (metal_atom is None):
        metal_atom = (aid, aname, x, y, z, elem, q)

    atoms.append((aid, aname, x, y, z, atype, q))

if metal_atom is None:
    raise SystemExit("No metal atom detected in mol2 (expected e.g. Au)")

metal_id, metal_aname, mx, my, mz, metal_sym, metal_q = metal_atom

# Write PDB with clean residue naming:
# - LIG for all non-metal atoms (resid 1)
# - METAL (e.g. AU) for the metal atom (resid 2)
pdb_lines = []
for aid, aname, x, y, z, atype, q in atoms:
    if aid == metal_id:
        resn = metal_sym.upper()
        resid = 2
        elem = metal_sym.upper()
    else:
        resn = "LIG"
        resid = 1
        em = re.match(r"[A-Za-z]+", aname)
        elem = (em.group(0) if em else aname)
        elem = elem[0].upper() + (elem[1:].lower() if len(elem) > 1 else "")
    # PDB formatting (good enough for MCPB parsing)
    pdb_lines.append(
        f"HETATM{aid:5d} {aname:<4s} {resn:>3s} A{resid:4d}    {x:8.3f}{y:8.3f}{z:8.3f}  1.00  0.00          {elem:>2s}"
    )

Path("${name}_mcpb.pdb").write_text("\\n".join(pdb_lines) + "\\n")

# Write single-atom metal pdb
metal_pdb = f"HETATM{metal_id:5d} {metal_sym.upper():<4s} {metal_sym.upper():>3s} A{2:4d}    {mx:8.3f}{my:8.3f}{mz:8.3f}  1.00  0.00          {metal_sym.upper():>2s}\\n"
Path(f"{metal_sym.upper()}.pdb").write_text(metal_pdb)

# Build ligand mol2 (strip only the metal atom)
keep = [a for a in atoms if a[0] != metal_id]
old2new = {a[0]: i+1 for i, a in enumerate(keep)}

# Parse bonds: id a1 a2 type
new_bonds = []
for l in bond_lines:
    if not l.strip():
        continue
    p = l.split()
    if len(p) < 4:
        continue
    a1 = int(p[1]); a2 = int(p[2])
    if a1 == metal_id or a2 == metal_id:
        continue
    if a1 in old2new and a2 in old2new:
        new_bonds.append((len(new_bonds)+1, old2new[a1], old2new[a2], p[3]))

lig_q = sum(a[6] for a in keep)

# Integer net charges for MCPB bookkeeping
tot_q_i = int(round(tot_q))
lig_q_i = int(round(lig_q))
metal_q_i = tot_q_i - lig_q_i

Path("metal_sym.txt").write_text(metal_sym.upper() + "\\n")
Path("ion_id.txt").write_text(str(metal_id) + "\\n")
Path("metal_charge_int.txt").write_text(str(metal_q_i) + "\\n")

# Reconstruct ligand mol2 with clean residue naming (LIG)
out = []
out.append("@<TRIPOS>MOLECULE")
out.append("LIG")
out.append(f"{len(keep)} {len(new_bonds)} 1 0 0")
out.append("SMALL")
out.append("USER_CHARGES")
out.append("")
out.append("@<TRIPOS>ATOM")
for old_id, aname, x, y, z, atype, q in keep:
    nid = old2new[old_id]
    # id name x y z type subst_id subst_name charge
    out.append(f"{nid:7d} {aname:<8s} {x:10.4f} {y:10.4f} {z:10.4f} {atype:<6s} 1 LIG {q: .6f}")
out.append("@<TRIPOS>BOND")
for bid, a1, a2, btyp in new_bonds:
    out.append(f"{bid:6d} {a1:4d} {a2:4d} {btyp}")
out.append("@<TRIPOS>SUBSTRUCTURE")
out.append("     1 LIG         1 GROUP 0 ****  ****    0 ROOT")

Path("LIG.mol2").write_text("\\n".join(out) + "\\n")
PY

METAL=\$(cat metal_sym.txt)
ION_ID=\$(cat ion_id.txt)
METALQ=\$(cat metal_charge_int.txt)

# Generate a 1-atom metal mol2 with the correct integer net charge
metalpdb2mol2.py -i "\${METAL}.pdb" -o "\${METAL}.mol2" -c "\${METALQ}"

# Generate ligand frcmod from the stripped ligand mol2
parmchk2 -i LIG.mol2 -f mol2 -o LIG.frcmod -s gaff2

# Fill MCPB .in placeholders
sed -i "s/__ION_ID__/\${ION_ID}/g" "${name}_mcpb.in"
sed -i "s/__ION_MOL2__/\${METAL}.mol2/g" "${name}_mcpb.in"

# Run MCPB (step 1 generates Gaussian inputs under mcpbpy/)
MCPB.py -i "${name}_mcpb.in" -s 1

# Patch Gaussian inputs to a basis that works for Au (def2SVP is available in g16)
# (We only rewrite the method/basis token on the route line; keep the rest.)
if [ -d mcpbpy ]; then
    for f in mcpbpy/*.com 2>/dev/null; do
        [ -f "\$f" ] || continue
        sed -i -E '/^#/ s#([^[:space:]]+/)[^[:space:]]+#\\1def2SVP#g' "\$f"
    done
fi

# Run Gaussian jobs if MCPB produced them
export GAUSS_SCRDIR="\$SCRATCHDIR/gauss_scratch"
mkdir -p "\$GAUSS_SCRDIR"

if [ -d mcpbpy ]; then
    cd mcpbpy
    for com in *.com 2>/dev/null; do
        [ -f "\$com" ] || continue
        g16 < "\$com" > "\${com%.com}.log"
    done
    for chk in *.chk 2>/dev/null; do
        [ -f "\$chk" ] || continue
        formchk "\$chk" "\${chk%.chk}.fchk"
    done
    cd ..
fi

# Continue MCPB parameterization (requires the Gaussian outputs above)
MCPB.py -i "${name}_mcpb.in" -s 2
MCPB.py -i "${name}_mcpb.in" -s 3
MCPB.py -i "${name}_mcpb.in" -s 4

# IMPORTANT: meta end does "cp * \$DATADIR/" (no directories).
# Copy key outputs from mcpbpy/ up to the scratch root so they are copied back.
if [ -d mcpbpy ]; then
    cp -f mcpbpy/*.frcmod . 2>/dev/null || true
    cp -f mcpbpy/*.mol2   . 2>/dev/null || true
    cp -f mcpbpy/*.lib    . 2>/dev/null || true
    cp -f mcpbpy/*.pdb    . 2>/dev/null || true
    cp -f mcpbpy/*.in     . 2>/dev/null || true
fi

echo "MCPB finished; scratch top-level files:"
ls -lah
EOF

    # Wrap and submit
    construct_sh_meta "$JOB_DIR" "mcpb"
    chmod +x "$JOB_DIR/mcpb.sh"

    submit_job "$JOB_DIR/mcpb.sh" "mcpb" "$JOB_DIR/jobs_info.txt"
    wait_for_job_completion

    check_file_exists "$OUT_FRCMOD" "mcpb"
    log_ok "MCPB finished; found: $OUT_FRCMOD"
}

# run_parmchk2 NAME DIRECTORY META AMBER
# Runs everything pertaining to parmchk2
# Globals: none
# Returns: Nothing
run_parmchk2() {
	#Load the inputs
	local name=$1
	local directory=$2
	local meta=$3
	local amber=$4
	local parmchk2_params=$5
	local mcpb_cmd=$6

	local job_name="parmchk2"

	info "Started running $job_name"

    #Start by converting the input mol into a xyz format -necessary for crest
	JOB_DIR="process/preparations/$job_name"
	ensure_dir $JOB_DIR

	SRC_DIR="process/preparations/antechamber"

	#Copy the data from antechamber
	move_inp_file "${name}_charges.mol2" "$SRC_DIR" "$JOB_DIR"

	#Constrcut the job file
	if [[ $meta == "true" ]]; then
		substitute_name_sh_meta_start "$JOB_DIR" "${directory}" ""
		substitute_name_sh_meta_end "$JOB_DIR"
		substitute_name_sh "$job_name" "$JOB_DIR" "$amber" "$name" "" "" "$parmchk2_params" ""
		construct_sh_meta "$JOB_DIR" "$job_name"
	else
		substitute_name_sh_wolf_start "$JOB_DIR"
		substitute_name_sh "$job_name" "$JOB_DIR" "$amber" "$name" "" "" "$parmchk2_params" ""
		construct_sh_wolf "$JOB_DIR" "$job_name"
	fi

    #Run the antechmaber
    submit_job "$meta" "$job_name" "$JOB_DIR" 32 32 0 "01:00:00"

	#Check that the final files are truly present
	check_res_file "${name}.frcmod" "$JOB_DIR" "$job_name"

	# Run MCPB.py only if heavy metal is present (needed for metal-center parameters)
    local mol2_for_detect="${INPUTS}/structures/${name}.mol2"
    if [[ -f "process/preparations/antechamber/${name}_charges.mol2" ]]; then
        mol2_for_detect="process/preparations/antechamber/${name}_charges.mol2"
    fi

    if has_heavy_metal_mcpb "$mol2_for_detect"; then
        local hold_job_dir="$JOB_DIR"
        info "Heavy metal detected in ${mol2_for_detect} – running MCPB.py"
        run_mcpb "$name" "$directory" "$meta" "$amber" "$mcpb_cmd"
        JOB_DIR="$hold_job_dir"
    fi

	success "$job_name has finished correctly"

	#Write to the log a finished operation
	add_to_log "$job_name" "$LOG"
}

# run_nemesis_fix NAME
# Moves the mol2 file through nemesis (openbabel) to correct some mistakes from antechmaber
# Globals: none
# Returns: Nothing
run_nemesis_fix() {
	#Load the inputs
	local name=$1

	local job_name="nemesis_fix"

	info "Started running $job_name"

    #Start by converting the input mol into a xyz format -necessary for crest
	JOB_DIR="process/preparations/$job_name"
	ensure_dir $JOB_DIR

	SRC_DIR="process/preparations/antechamber"

	#Copy the data from antechamber
	move_inp_file "${name}_charges.mol2" "$SRC_DIR" "$JOB_DIR"

	#Add the correct module
	if [[ $meta == "true" ]]; then
		module add openbabel > /dev/null 2>&1
	else
		module add obabel > /dev/null 2>&1
	fi

	obabel -imol2 "$JOB_DIR/${name}_charges.mol2" -omol2 -O "$JOB_DIR/${name}_charges_fix.mol2" > /dev/null 2>&1

	#Check that the final files are truly present
	check_res_file "${name}_charges_fix.mol2" "$JOB_DIR" "$job_name"

	success "$job_name has finished correctly"

	#Write to the log a finished operation
	add_to_log "$job_name" "$LOG"
}

# run_tleap NAME DIRECTORY META AMBER
# Runs everything pertaining to parmchk2
# Globals: none
# Returns: Nothing
run_tleap() {
	#Load the inputs
	local name=$1
	local directory=$2
	local meta=$3
	local amber=$4
	local in_file=$5
	local params=$6

	local job_name="tleap"

	info "Started running $job_name"

    #Start by converting the input mol into a xyz format -necessary for crest
	JOB_DIR="process/preparations/$job_name"
	ensure_dir $JOB_DIR

	SRC_DIR_1="process/preparations/parmchk2"
	SRC_DIR_2="process/preparations/nemesis_fix"
	SRC_DIR_3="inputs/params"

	#Copy the data from antechamber
	move_inp_file "${name}.frcmod" "$SRC_DIR_1" "$JOB_DIR"
	move_inp_file "${name}_charges_fix.mol2" "$SRC_DIR_2" "$JOB_DIR"

	#If also spec, load the necessary files
	if [[ $params == "yes" ]]; then
		cp  "$SRC_DIR_3/gaff.zf" "$JOB_DIR"
		cp  "$SRC_DIR_3/leaprc.zf" "$JOB_DIR"
	fi

	#Copy the .in file for tleap
	substitute_name_in "$in_file" "$JOB_DIR" "$name" ""

	#Construct the job file
	if [[ $meta == "true" ]]; then
		substitute_name_sh_meta_start "$JOB_DIR" "${directory}" ""
		substitute_name_sh_meta_end "$JOB_DIR"
		substitute_name_sh "$job_name" "$JOB_DIR" "$amber" "$name" "$in_file.in" "" "" ""
		construct_sh_meta "$JOB_DIR" "$job_name"
	else
		substitute_name_sh_wolf_start "$JOB_DIR"
		substitute_name_sh "$job_name" "$JOB_DIR" "$amber" "$name" "$in_file.in" "" "" ""
		construct_sh_wolf "$JOB_DIR" "$job_name"
	fi

    #Run the antechmaber
    submit_job "$meta" "$job_name" "$JOB_DIR" 8 8 0 "01:00:00"

	#Check that the final files are truly present
	check_res_file "${name}.rst7" "$JOB_DIR" "$job_name"
	check_res_file "${name}.parm7" "$JOB_DIR" "$job_name"

	success "$job_name has finished correctly"

	#Write to the log a finished operation
	add_to_log "$job_name" "$LOG"
}