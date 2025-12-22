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
# Globals: none
# Returns: Nothing
# run_mcpb NAME DIRECTORY META AMBER MCPB_CMD IN_MOL2 LIG_FRCMOD
run_mcpb() {
	local name=$1 directory=$2 meta=$3 amber=$4 mcpb_cmd=$5 mol2=$6 frcmod=$7

	# If MCPB is not configured, do nothing
	if [[ -z "${mcpb_cmd:-}" ]]; then
		info "Skipping MCPB.py (no mcpb option set in config)"
		return 0
	fi

	# Backwards-compat: if the overall MCPB was logged previously, do not rerun
	if check_log "mcpb" "$LOG"; then
		info "mcpb already finished (log)"
		return 0
	fi

	# Run MCPB.py only if heavy metal is present (needed for metal-center parameters)
	if ! mol2_has_metal "$mol2"; then
		info "No metal detected in ${mol2}; skipping MCPB.py"
		return 0
	fi

	# Resolve MCPB requested step (default to 4 if user gave something non-empty but without -s)
	local mcpb_step
	mcpb_step="$(printf '%s\n' "$mcpb_cmd" | sed -nE 's/.*-s[[:space:]]*([0-9]+).*/\1/p' | head -n 1)"
	mcpb_step="${mcpb_step:-4}"

	# Base + stage dirs
	local BASE_DIR="process/preparations/mcpb"
	local STAGE1_DIR="$BASE_DIR/01_step1"
	local STAGE2_DIR="$BASE_DIR/02_qm"
	local STAGE3_DIR="$BASE_DIR/03_params"

	# Stage job names (these go to $LOG individually)
	local STAGE1_JOB="mcpb_step1"
	local STAGE2_JOB="mcpb_qm"
	local STAGE3_JOB="mcpb_params"

	# Inputs from previous steps
	local SRC_PDB_DIR="process/preparations/mol2"
	local SRC_MOL2_DIR
	SRC_MOL2_DIR="$(dirname "$mol2")"
	local SRC_FRCMOD_DIR
	SRC_FRCMOD_DIR="$(dirname "$frcmod")"

	local PDB_FILE="${name}.pdb"
	local MOL2_FILE
	MOL2_FILE="$(basename "$mol2")"
	local FRCMOD_FILE
	FRCMOD_FILE="$(basename "$frcmod")"

	# -----------------------------
	# Stage 1/3: MCPB.py -s 1
	# -----------------------------
	if [[ $mcpb_step -ge 1 ]]; then
		if ! check_log "$STAGE1_JOB" "$LOG"; then
			info "MCPB Stage 1/3: generating models + QM inputs (MCPB.py -s 1)"

			ensure_dir "$STAGE1_DIR"

			# Bring inputs into stage dir so MetaCentrum scratch staging works
			check_inp_file "$PDB_FILE" "$SRC_PDB_DIR"
			move_inp_file "$PDB_FILE" "$SRC_PDB_DIR" "$STAGE1_DIR"

			check_inp_file "$MOL2_FILE" "$SRC_MOL2_DIR"
			move_inp_file "$MOL2_FILE" "$SRC_MOL2_DIR" "$STAGE1_DIR"

			check_inp_file "$FRCMOD_FILE" "$SRC_FRCMOD_DIR"
			move_inp_file "$FRCMOD_FILE" "$SRC_FRCMOD_DIR" "$STAGE1_DIR"

			cp "$directory/inputs/simulation/${name}_mcpb.in" "$STAGE1_DIR/mcpb.in" || die "Couldn't copy ${name}_mcpb.in"

			# Build stage-1 job
			cat > "$STAGE1_DIR/job_file.txt" << EOF
#!/usr/bin/env bash
set -euo pipefail

source "${directory}/inputs/simulation/modules.sh"
load_module "amber/${amber}"
load_module "python/3.9.16-gcc-10.2.1"

NAME="${name}"

PDB_PATH="${PDB_FILE}"
MOL2_PATH="${MOL2_FILE}"
FRCMOD_PATH="${FRCMOD_FILE}"

# --- Read MCPB config from mcpb.in template
ION_IDS="\$(grep -E '^[[:space:]]*ion_ids[[:space:]]*=' "mcpb.in" | head -n 1 | cut -d'=' -f2 | tr -d '[:space:]')"
CUTOFF="\$(grep -E '^[[:space:]]*cutoff[[:space:]]*=' "mcpb.in" | head -n 1 | cut -d'=' -f2 | tr -d '[:space:]')"
GROUP_NAME="\$(grep -E '^[[:space:]]*group_name[[:space:]]*=' "mcpb.in" | head -n 1 | cut -d'=' -f2 | tr -d '[:space:]')"

MCPB_PARAMS="\$(grep -E '^[[:space:]]*mcpb_[a-zA-Z0-9_]+[[:space:]]*=' "mcpb.in" | sed -E 's/[[:space:]]+/ /g' || true)"

# --- Write the actual MCPB input for this stage
cat > "\${NAME}_mcpb.in" << EOI
original_pdb = \${PDB_PATH}
ion_ids = \${ION_IDS}
cutoff = \${CUTOFF}
group_name = \${GROUP_NAME}
software_version = g16
force_field = ff14SB
mol2_file = \${MOL2_PATH}
frcmod_file = \${FRCMOD_PATH}
\${MCPB_PARAMS}
EOI

MCPB.py -i "\${NAME}_mcpb.in" -s 1

if [[ -f "\${NAME}_small_opt.com" && -f "\${NAME}_small_fc.com" ]]; then
	echo "[OK] MCPB stage1 produced QM inputs"
else
	echo "[ERROR] MCPB stage1 did not produce expected QM inputs"
	exit 1
fi
EOF

			if [[ "$meta" == "true" ]]; then
				substitute_name_sh_meta_start "$STAGE1_DIR" "$directory" "$amber"
				substitute_name_sh_meta_end "$STAGE1_DIR"
				construct_sh_meta "$STAGE1_DIR" "$STAGE1_JOB"
			else
				substitute_name_sh_wolf_start "$STAGE1_DIR" "$directory" "$amber"
				substitute_name_sh_meta_end "$STAGE1_DIR"
				construct_sh_wolf "$STAGE1_DIR" "$STAGE1_JOB"
			fi

			# Submit stage 1
			submit_job "$STAGE1_JOB" "$STAGE1_DIR" "$meta" "01:00:00" 8 4 0

			# Verify stage 1 results
			check_res_file "${name}_small_opt.com" "$STAGE1_DIR" "$STAGE1_JOB"
			check_res_file "${name}_small_fc.com" "$STAGE1_DIR" "$STAGE1_JOB"
			check_res_file "${name}_mcpb.in" "$STAGE1_DIR" "$STAGE1_JOB"

			add_to_log "$STAGE1_JOB" "$LOG"
			success "MCPB Stage 1/3 completed"
		else
			info "MCPB Stage 1/3 already completed (log)"
		fi
	fi

	# If user only wanted stage 1, we stop here
	if [[ $mcpb_step -le 1 ]]; then
		add_to_log "mcpb" "$LOG"
		return 0
	fi

	# -----------------------------
	# Stage 2/3: Gaussian QM runs
	# -----------------------------
	if ! check_log "$STAGE2_JOB" "$LOG"; then
		info "MCPB Stage 2/3: running Gaussian QM (small_opt + small_fc)"

		ensure_dir "$STAGE2_DIR"

		# Stage inputs must be present inside stage dir before submission (scratch staging)
		move_inp_file "${name}_small_opt.com" "$STAGE1_DIR" "$STAGE2_DIR"
		move_inp_file "${name}_small_fc.com" "$STAGE1_DIR" "$STAGE2_DIR"

		# Build stage-2 job
		cat > "$STAGE2_DIR/job_file.txt" << EOF
#!/usr/bin/env bash
set -euo pipefail

source "${directory}/inputs/simulation/modules.sh"
load_module "gaussian/g16"

NAME="${name}"

# Align QM input headers with allocated resources
sed -i "s/%mem=.*/%mem=32GB/g" "\${NAME}_small_opt.com" || true
sed -i "s/%mem=.*/%mem=32GB/g" "\${NAME}_small_fc.com" || true
sed -i "s/%nprocshared=.*/%nprocshared=8/g" "\${NAME}_small_opt.com" || true
sed -i "s/%nprocshared=.*/%nprocshared=8/g" "\${NAME}_small_fc.com" || true

gauss_ok() {
	local log="\$1"
	[[ -f "\$log" ]] || return 1
	grep -q "Normal termination" "\$log"
}

g16 "\${NAME}_small_opt.com"
g16 "\${NAME}_small_fc.com"

if gauss_ok "\${NAME}_small_opt.log" && gauss_ok "\${NAME}_small_fc.log"; then
	echo "[OK] MCPB stage2 Gaussian finished (Normal termination)"
else
	echo "[ERROR] MCPB stage2 Gaussian did not terminate normally"
	exit 1
fi
EOF

		if [[ "$meta" == "true" ]]; then
			substitute_name_sh_meta_start "$STAGE2_DIR" "$directory" "$amber"
			substitute_name_sh_meta_end "$STAGE2_DIR"
			construct_sh_meta "$STAGE2_DIR" "$STAGE2_JOB"
		else
			substitute_name_sh_wolf_start "$STAGE2_DIR" "$directory" "$amber"
			substitute_name_sh_meta_end "$STAGE2_DIR"
			construct_sh_wolf "$STAGE2_DIR" "$STAGE2_JOB"
		fi

		# Submit stage 2
		submit_job "$STAGE2_JOB" "$STAGE2_DIR" "$meta" "12:00:00" 32 8 0

		# Verify stage 2 results
		check_res_file "${name}_small_opt.log" "$STAGE2_DIR" "$STAGE2_JOB"
		check_res_file "${name}_small_fc.log" "$STAGE2_DIR" "$STAGE2_JOB"

		add_to_log "$STAGE2_JOB" "$LOG"
		success "MCPB Stage 2/3 completed"
	else
		info "MCPB Stage 2/3 already completed (log)"
	fi

	# -----------------------------
	# Stage 3/3: MCPB.py -s 2 (+ -s 4 if requested)
	# -----------------------------
	if ! check_log "$STAGE3_JOB" "$LOG"; then
		info "MCPB Stage 3/3: generating parameters (MCPB.py -s 2) and LEaP input (optional -s 4)"

		ensure_dir "$STAGE3_DIR"

		# Stage inputs must be present inside stage dir before submission (scratch staging)
		# Copy everything from stage1 (models, generated MCPB input, etc.)
		cp -a "$STAGE1_DIR/." "$STAGE3_DIR/" || die "Couldn't sync MCPB stage1 -> stage3"
		# Copy Gaussian logs from stage2
		move_inp_file "${name}_small_opt.log" "$STAGE2_DIR" "$STAGE3_DIR"
		move_inp_file "${name}_small_fc.log" "$STAGE2_DIR" "$STAGE3_DIR"

		# Build stage-3 job
		cat > "$STAGE3_DIR/job_file.txt" << EOF
#!/usr/bin/env bash
set -euo pipefail

source "${directory}/inputs/simulation/modules.sh"
load_module "amber/${amber}"
load_module "python/3.9.16-gcc-10.2.1"

NAME="${name}"
STEP="${mcpb_step}"

GROUP_NAME="\$(grep -E '^[[:space:]]*group_name[[:space:]]*=' "mcpb.in" | head -n 1 | cut -d'=' -f2 | tr -d '[:space:]')"
GNAME="\${GROUP_NAME}"

# MCPB step2 (requires the Gaussian logs to be present)
MCPB.py -i "\${NAME}_mcpb.in" -s 2

if [[ -f "frcmod_\${GNAME}" ]]; then
	cp "frcmod_\${GNAME}" "\${NAME}_mcpbpy.frcmod"
else
	echo "[ERROR] Missing frcmod_\${GNAME} after MCPB step2"
	exit 1
fi

if [[ -f "\${GNAME}.lib" ]]; then
	cp "\${GNAME}.lib" "\${NAME}_mcpbpy.lib"
else
	echo "[ERROR] Missing \${GNAME}.lib after MCPB step2"
	exit 1
fi

# MCPB step4 only if requested
if [[ "\${STEP}" -ge 4 ]]; then
	MCPB.py -i "\${NAME}_mcpb.in" -s 4

	if [[ -f "tleap.in" ]]; then
		cp "tleap.in" "\${NAME}_tleap.in"
	else
		echo "[ERROR] Missing tleap.in after MCPB step4"
		exit 1
	fi
fi

echo "[OK] MCPB stage3 finished"
EOF

		if [[ "$meta" == "true" ]]; then
			substitute_name_sh_meta_start "$STAGE3_DIR" "$directory" "$amber"
			substitute_name_sh_meta_end "$STAGE3_DIR"
			construct_sh_meta "$STAGE3_DIR" "$STAGE3_JOB"
		else
			substitute_name_sh_wolf_start "$STAGE3_DIR" "$directory" "$amber"
			substitute_name_sh_meta_end "$STAGE3_DIR"
			construct_sh_wolf "$STAGE3_DIR" "$STAGE3_JOB"
		fi

		# Submit stage 3
		submit_job "$STAGE3_JOB" "$STAGE3_DIR" "$meta" "06:00:00" 16 8 0

		# Verify stage 3 results
		check_res_file "${name}_mcpbpy.frcmod" "$STAGE3_DIR" "$STAGE3_JOB"
		check_res_file "${name}_mcpbpy.lib" "$STAGE3_DIR" "$STAGE3_JOB"

		if [[ $mcpb_step -ge 4 ]]; then
			check_res_file "${name}_tleap.in" "$STAGE3_DIR" "$STAGE3_JOB"
		fi

		add_to_log "$STAGE3_JOB" "$LOG"
		success "MCPB Stage 3/3 completed"
	else
		info "MCPB Stage 3/3 already completed (log)"
	fi

	# Final “overall” marker for backwards compatibility / convenience
	add_to_log "mcpb" "$LOG"
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

	local job_name="parmchk2"

	info "Started running $job_name"

    #Start by converting the input mol into a xyz format -necessary for crest
	JOB_DIR="process/preparations/$job_name"
	ensure_dir $JOB_DIR

	SRC_DIR="process/preparations/antechamber"

	#Copy the data from antechamber
	move_inp_file "${name}_charges.mol2" "$SRC_DIR" "$JOB_DIR"

	# parmchk2 is for the organic part; heavy metals frequently break/poison the frcmod generation.
	# If a metal is present, run parmchk2 on a ligand-only MOL2, but keep the full MOL2 for MCPB.
	local full_mol2="$JOB_DIR/${name}_charges.mol2"
	local mcpb_mol2="$full_mol2"

		# Strip the metal for the parmchk2 run (keep a full copy for MCPB)
	local mcpb_mol2="$JOB_DIR/${name}_charges_full.mol2"
	local mcpb_input_mol2="$full_mol2"

	if mol2_has_metal "$full_mol2"; then
		cp "$full_mol2" "$mcpb_mol2"

		local metal_id
		metal_id="$(mol2_first_metal_id "$mcpb_mol2")"

		if [[ "$metal_id" == "-1" ]]; then
			warning "Metal expected but could not be identified in MOL2; skipping strip. (This may break parmchk2.)"
		else
			info "Metal detected in MOL2 (atom_id=$metal_id). Stripping it for parmchk2 (MCPB will use the full MOL2)."
			mol2_strip_atom "$mcpb_mol2" "$full_mol2" "$metal_id"

			# MCPB must see the full (unstripped) MOL2
			mcpb_input_mol2="$mcpb_mol2"
		fi
	fi

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
    submit_job "$meta" "$job_name" "$JOB_DIR" 8 8 0 "01:00:00"

	#Check that the final files are truly present
	check_res_file "${name}.frcmod" "$JOB_DIR" "$job_name"

		# MCPB.py step 2 crashes on an empty frcmod; ensure non-empty file
	if [[ ! -s "$JOB_DIR/${name}.frcmod" ]]; then
		warning "parmchk2 produced an empty frcmod ($JOB_DIR/${name}.frcmod). Creating a minimal stub so MCPB.py can proceed."
		cat > "$JOB_DIR/${name}.frcmod" <<'EOF'
remark generated by nmr.sh: empty parmchk2 frcmod; no overrides needed
MASS
BOND
ANGLE
DIHE
IMPROPER
NONBON
EOF
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

	# OpenBabel may rewrite MOL2 metadata and metal atom types (e.g., Au -> Au).
	# Normalize to GAFF/GAFF2 expectations.
	mol2_normalize_obabel_output_inplace "$JOB_DIR/${name}_charges_fix.mol2" "$name"

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

	# If MCPB produced a tleap input, reuse its parameter/library load statements
	# so teLeap knows the metal atom type + metal-ligand bonded terms.
	local tleap_in="${in_file}.in"
	local MCPB_DIR="process/preparations/mcpb/03_params"
	[[ -d "$MCPB_DIR" ]] || MCPB_DIR="process/preparations/mcpb"

	if [[ -f "${MCPB_DIR}/${name}_tleap.in" ]]; then
		info "Detected MCPB output – importing metal parameters into tleap input"

		# Copy MCPB artifacts that its tleap file may load
		cp "${MCPB_DIR}"/*.frcmod "${MCPB_DIR}"/*.lib "${MCPB_DIR}"/*.off "${MCPB_DIR}"/*.dat \
			"$JOB_DIR" 2>/dev/null || true

		# Extract only load statements (avoid unit creation / save / quit)
		grep -E '^(loadAmberParams|loadamberparams|loadoff|loadOff)[[:space:]]' \
			"${MCPB_DIR}/${name}_tleap.in" \
			| sed 's#^[[:space:]]*##; s#\./##g' > "$JOB_DIR/mcpb_params.in" || true

		# Filter out MCPB load statements that reference local files that are not present.
		# (Common when MCPB step 4 is run without having generated step 2 outputs yet.)
		if [[ -s "$JOB_DIR/mcpb_params.in" ]]; then
			local mcpb_filtered="$JOB_DIR/mcpb_params.filtered.in"
			: > "$mcpb_filtered"

			while IFS= read -r line; do
				# Normalize (strip leading spaces, remove leading "./")
				line="$(printf '%s\n' "$line" | sed 's/^[[:space:]]*//; s#\./##g')"

				# Skip empty/comment lines
				[[ -z "$line" || "$line" == \#* ]] && continue

				# shellcheck disable=SC2086
				set -- $line
				local cmd="$1"
				local file="$2"

				# Keep built-in Amber frcmods (resolved via AMBER data path)
				if [[ "$cmd" =~ ^(loadAmberParams|loadamberparams|loadoff|loadOff)$ ]]; then
					if [[ "$file" == frcmod.* ]]; then
						printf '%s\n' "$line" >> "$mcpb_filtered"
					elif [[ -f "$JOB_DIR/$file" ]]; then
						printf '%s\n' "$line" >> "$mcpb_filtered"
					else
						info "Skipping MCPB load statement (missing file): $line"
					fi
				else
					printf '%s\n' "$line" >> "$mcpb_filtered"
				fi
			done < "$JOB_DIR/mcpb_params.in"

			mv "$mcpb_filtered" "$JOB_DIR/mcpb_params.in"
		fi


		if [[ -s "$JOB_DIR/mcpb_params.in" ]]; then
			cat "$JOB_DIR/mcpb_params.in" "$JOB_DIR/${in_file}.in" > "$JOB_DIR/tleap_run.in"
			tleap_in="tleap_run.in"
		else
			info "MCPB tleap file present but no load statements found – using ${in_file}.in"
		fi
	fi

	#Construct the job file
	if [[ $meta == "true" ]]; then
		substitute_name_sh_meta_start "$JOB_DIR" "${directory}" ""
		substitute_name_sh_meta_end "$JOB_DIR"
		substitute_name_sh "$job_name" "$JOB_DIR" "$amber" "$name" "$tleap_in" "" "" ""
		construct_sh_meta "$JOB_DIR" "$job_name"
	else
		substitute_name_sh_wolf_start "$JOB_DIR"
		substitute_name_sh "$job_name" "$JOB_DIR" "$amber" "$name" "" "" "$tleap_in" ""
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