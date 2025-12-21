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
	local name="$1"
	local directory="$2"
	local meta="$3"
	local amber="$4"
	local mcpb_cmd="$5"
	local in_mol2="$6"
	local lig_frcmod="$7"

	local job_name="mcpb"
	local JOB_DIR="process/preparations/$job_name"

	# Only run if a heavy metal is present
	if ! mol2_has_metal "$in_mol2"; then
		return 0
	fi

	info "Heavy metal detected in $in_mol2 - running MCPB.py"

	rm -rf "$JOB_DIR"
	ensure_dir "$JOB_DIR"

	# Default to step 4 for metal systems (step 4 alone is NOT sufficient; we will run prereqs)
	local mcpb_cmd_resolved="${mcpb_cmd:-"-s 4"}"

	# Gaussian module name depends on cluster
	local gauss_mod="gaussian"
	if [[ $meta == "true" ]]; then
		gauss_mod="g16"
	fi

	# Stage all MCPB inputs in JOB_DIR (so the job can just copy and run)
	local src_mol2="$JOB_DIR/${name}_mcpb_source.mol2"
	cp "$in_mol2" "$src_mol2"
	cp "$lig_frcmod" "$JOB_DIR/LIG.frcmod"

	# Sanitize MOL2 if it contains an extra element column in @<TRIPOS>ATOM
	mol2_sanitize_atom_coords_inplace "$src_mol2"

	# Identify the first metal
	local metal_line
	metal_line="$(mol2_first_metal "$src_mol2")"
	[[ -n "$metal_line" ]] || die "Failed to detect metal in $src_mol2"

	local metal_id metal_elem metal_charge mx my mz
	read -r metal_id metal_elem metal_charge mx my mz <<< "$metal_line"
	metal_charge="${metal_charge:-0.0}"
	metal_elem=$(echo "$metal_elem" | tr '[:lower:]' '[:upper:]')

	# Generate PDB and split MOL2s
	mol2_to_mcpb_pdb "$src_mol2" "$JOB_DIR/${name}_mcpb.pdb" "$metal_id"
	mol2_strip_atom "$src_mol2" "$JOB_DIR/LIG.mol2" "$metal_id"
	write_single_ion_mol2 "$JOB_DIR/${metal_elem}.mol2" "$metal_elem" "$metal_charge" "$mx" "$my" "$mz"

	mol2_sanitize_for_mcpb "$JOB_DIR/LIG.mol2" "LIG"
	mol2_sanitize_for_mcpb "$JOB_DIR/${metal_elem}.mol2" "$metal_elem"


	# Generate MCPB input (resolved values; no runtime substitutions needed)
		# Generate MCPB input (resolved values; no runtime substitutions needed)
	cat > "$JOB_DIR/job_file.txt" <<EOF
# Amber tools (MCPB.py) live here
module add ${amber}

# Gaussian (MetaCentrum: module is typically g16; keep fallback for portability)
module add g16 2>/dev/null || module add gaussian 2>/dev/null || true

# Pass resolved name into the job environment (so we can quote the heredoc below)
NAME="${name}"

echo "[INFO] MCPB pipeline requested: step 1 -> QM (opt+freq) -> step 2 -> step 4"

# Ensure MCPB input exists in the execution directory (do not rely on copy filters)
{
	echo "original_pdb ${name}_mcpb.pdb"
	echo "group_name ${name}"
	echo "cut_off 2.8"
	echo "ion_ids ${metal_id}"
	echo "ion_mol2files ${metal_elem}.mol2"
	echo "naa_mol2files LIG.mol2"
	echo "frcmod_files LIG.frcmod"
	echo "large_opt 0"
} > "${name}_mcpb.in"

if [ ! -s "${name}_mcpb.in" ]; then
	echo "[ERR] Failed to create MCPB input: ${name}_mcpb.in"
	JOB_STATUS=1
fi

JOB_STATUS=0
EOF

cat >> "$JOB_DIR/job_file.txt" <<'EOF'

need_cmd() {
	command -v "$1" >/dev/null 2>&1 && return 0
	echo "[ERR] Required command '$1' not found in PATH."
	JOB_STATUS=1
	return 1
}

run_mcpb_step() {
	local step="$1"
	echo "[INFO] Running MCPB.py step ${step}"
	[ -s "${name}_mcpb.in" ] || { echo "[ERR] Missing MCPB input: ${name}_mcpb.in"; JOB_STATUS=1; return 1; }
	MCPB.py -i "${name}_mcpb.in" -s "\${step}"
	local rc=$?
	if [ $rc -ne 0 ]; then
		echo "[ERR] MCPB.py step ${step} failed (rc=$rc)"
		JOB_STATUS=$rc
		return $rc
	fi
	return 0
}

gauss_ok() {
	local out="$1"
	[ -f "$out" ] || return 1
	grep -q "Normal termination of Gaussian" "$out"
}

run_gaussian() {
	local com="$1"
	local stem="${com%.com}"
	local out="${stem}.log"

	[ -f "$com" ] || { echo "[ERR] Gaussian input missing: $com"; JOB_STATUS=1; return 1; }

	need_cmd g16 || return 1

	# Respect scheduler CPU allocation to avoid full-node oversubscription/spin
	local ncpus="${PBS_NCPUS:-${NCPUS:-${OMP_NUM_THREADS:-2}}}"
	[ -n "$ncpus" ] || ncpus=2

	export OMP_NUM_THREADS="$ncpus"
	export MKL_NUM_THREADS="$ncpus"
	export OPENBLAS_NUM_THREADS="$ncpus"
	export VECLIB_MAXIMUM_THREADS="$ncpus"
	export NUMEXPR_NUM_THREADS="$ncpus"

	# Ensure Gaussian uses a writable scratch directory
	export GAUSS_SCRDIR="${GAUSS_SCRDIR:-${SCRATCHDIR:-$PWD}}"
	export TMPDIR="${TMPDIR:-$GAUSS_SCRDIR}"
	mkdir -p "$GAUSS_SCRDIR" >/dev/null 2>&1 || true

	# Make sure the input deck ends cleanly (avoids edge parsing issues)
	printf "\n" >> "$com" 2>/dev/null || true

	# If present, MetaCentrum helper can rewrite %Mem/%NProcShared/%RWF appropriately
	if command -v g16-prepare >/dev/null 2>&1; then
		g16-prepare "$com" >> "$out" 2>&1 || true
	fi

	echo "[INFO] Running Gaussian: $com (ncpus=$ncpus, scrdir=$GAUSS_SCRDIR)"
	g16 "$com" > "$out" 2>&1 &
	local pid=$!

	# Watchdog: if neither log nor RWF grows for too long, dump diagnostics and abort
	local idle=0
	local idle_limit=20   # minutes
	local last_out_sz=0
	local last_rwf_sz=0
	local rwf_a="$GAUSS_SCRDIR/Gau-${pid}.rwf"
	local rwf_b="./Gau-${pid}.rwf"

	last_out_sz=$(stat -c %s "$out" 2>/dev/null || echo 0)
	last_rwf_sz=$(stat -c %s "$rwf_a" 2>/dev/null || stat -c %s "$rwf_b" 2>/dev/null || echo 0)

	while kill -0 "$pid" >/dev/null 2>&1; do
		sleep 60

		local out_sz rwf_sz
		out_sz=$(stat -c %s "$out" 2>/dev/null || echo 0)
		rwf_sz=$(stat -c %s "$rwf_a" 2>/dev/null || stat -c %s "$rwf_b" 2>/dev/null || echo 0)

		if [ "$out_sz" -gt "$last_out_sz" ] || [ "$rwf_sz" -gt "$last_rwf_sz" ]; then
			idle=0
			last_out_sz="$out_sz"
			last_rwf_sz="$rwf_sz"
		else
			idle=$((idle + 1))
			if [ "$idle" -ge "$idle_limit" ]; then
				echo "[ERR] Gaussian appears hung: no log/rwf growth for ${idle_limit} minutes: $com" >> "$out"
				ps -fp "$pid" >> "$out" 2>&1 || true

				if command -v top >/dev/null 2>&1; then
					echo "[INFO] top -H (threads) snapshot:" >> "$out"
					top -b -n 1 -H -p "$pid" | head -n 60 >> "$out" 2>&1 || true
				fi

				if command -v timeout >/dev/null 2>&1 && command -v strace >/dev/null 2>&1; then
					echo "[INFO] Capturing strace (10s) -> ${stem}.strace.txt" >> "$out"
					timeout 10 strace -tt -f -p "$pid" -o "${stem}.strace.txt" >> "$out" 2>&1 || true
				fi

				kill -TERM "$pid" >/dev/null 2>&1 || true
				sleep 10
				kill -KILL "$pid" >/dev/null 2>&1 || true

				JOB_STATUS=1
				return 1
			fi
		fi
	done

	wait "$pid"
	local rc=$?
	if [ "$rc" -ne 0 ]; then
		echo "[ERR] Gaussian failed (rc=$rc): $com"
		JOB_STATUS="$rc"
		return "$rc"
	fi

	if [ -f "${stem}.chk" ] && command -v formchk >/dev/null 2>&1; then
		formchk "${stem}.chk" "${stem}.fchk" >> "$out" 2>&1 || true
	fi

	if ! gauss_ok "$out"; then
		echo "[ERR] Gaussian did not terminate normally: $out"
		JOB_STATUS=1
		return 1
	fi

	return 0
}

# Step 1: build models + generate QM inputs
if [ \$JOB_STATUS -eq 0 ]; then run_mcpb_step 1; fi

# QM (generated by step 1)
if [ $JOB_STATUS -eq 0 ]; then run_gaussian "${NAME}_small_opt.com"; fi
if [ $JOB_STATUS -eq 0 ]; then run_gaussian "${NAME}_small_fc.com";  fi

# Step 2: generate force field parameters (expects QM results)
if [ $JOB_STATUS -eq 0 ]; then run_mcpb_step 2; fi

# Step 4: generate LEaP input
if [ $JOB_STATUS -eq 0 ]; then run_mcpb_step 4; fi

if [ $JOB_STATUS -ne 0 ]; then
	echo "[ERR] MCPB pipeline finished with errors (JOB_STATUS=$JOB_STATUS). Files will still be copied back for debugging."
else
	echo "[INFO] MCPB pipeline finished successfully."
fi

echo "[INFO] MCPB pipeline output files present in scratch:"
ls -la
EOF

	if [[ $meta == "true" ]]; then
		substitute_name_sh_meta_start "$JOB_DIR" "${directory}" ""
		substitute_name_sh_meta_end "$JOB_DIR" "$JOB_DIR"
		construct_sh_meta "$JOB_DIR" "$job_name"
	else
		substitute_name_sh_wolf_end "$JOB_DIR" "$JOB_DIR"
		construct_sh_wolf "$JOB_DIR" "$job_name"
	fi

	# Run
	# If we need QM (step >= 2), give it more time/memory
	local mcpb_ncpu=8
	local mcpb_mem=8
	local mcpb_wall="01:00:00"

	if echo "$mcpb_cmd_resolved" | grep -Eq -- '(^|[[:space:]])(-s|--step)[[:space:]]*[234]'; then
		mcpb_mem=32
		mcpb_wall="12:00:00"
	fi

	submit_job "$meta" "$job_name" "$JOB_DIR" "$mcpb_mem" "$mcpb_ncpu" 0 "$mcpb_wall"


	if [[ ! -f "$JOB_DIR/${name}_tleap.in" && -f "$JOB_DIR/tleap.in" ]]; then
		cp "$JOB_DIR/tleap.in" "$JOB_DIR/${name}_tleap.in"
	fi

	# Step 2 must produce the metal parameter frcmod
	if echo "$mcpb_cmd_resolved" | grep -Eq -- '(^|[[:space:]])(-s|--step)[[:space:]]*[234]'; then
		check_res_file "${name}_mcpbpy.frcmod" "$JOB_DIR" "$job_name"
	fi

	# Step 4 must produce the tleap include (some versions name it tleap.in)
	if echo "$mcpb_cmd_resolved" | grep -Eq -- '(^|[[:space:]])(-s|--step)[[:space:]]*4'; then
		check_res_file "${name}_tleap.in" "$JOB_DIR" "$job_name"
	fi

	# If the user requested step 4, they almost certainly intend to build a bonded model in LEaP.
	# Step 4 does NOT generate the metal bonded parameter file; that comes from step 2.
	# Refuse to continue if the frcmod is missing, otherwise tleap will fail with missing Au terms.
	if echo "${mcpb_cmd:-"-s 1"}" | grep -Eq -- '(^|[[:space:]])(-s|--step)[[:space:]]*4'; then
		if [[ ! -f "$JOB_DIR/${name}_mcpbpy.frcmod" ]]; then
			die "MCPB step 4 did not produce ${name}_mcpbpy.frcmod. Step 4 generates the LEaP input, but bonded metal parameters are produced in step 2 (after QM outputs exist). Run MCPB step 1 -> run QM -> MCPB step 2 -> then step 4."
		fi
	fi

	success "$job_name has finished correctly"
	add_to_log "$job_name" "$LOG"
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

	# parmchk2 is for the organic part; heavy metals frequently break/poison the frcmod generation.
	# If a metal is present, run parmchk2 on a ligand-only MOL2, but keep the full MOL2 for MCPB.
	local full_mol2="$JOB_DIR/${name}_charges.mol2"
	local mcpb_mol2="$full_mol2"

	if mol2_has_metal "$full_mol2"; then
		cp "$full_mol2" "$JOB_DIR/${name}_charges_full.mol2"
		mcpb_mol2="$JOB_DIR/${name}_charges_full.mol2"

		local metal_id
		metal_id="$(mol2_first_metal "$mcpb_mol2" | awk '{print $1}')"
		[[ -n "$metal_id" ]] || die "parmchk2: Failed to identify metal atom id"

		# Overwrite the parmchk2 input MOL2 with ligand-only content
		mol2_strip_atom "$mcpb_mol2" "$full_mol2" "$metal_id"
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
    submit_job "$meta" "$job_name" "$JOB_DIR" 32 32 0 "01:00:00"

	#Check that the final files are truly present
	check_res_file "${name}.frcmod" "$JOB_DIR" "$job_name"

	# Run MCPB.py only if heavy metal is present (needed for metal-center parameters)
    run_mcpb "$name" "$directory" "$meta" "$amber" "$mcpb_cmd" "$JOB_DIR/${name}_charges.mol2" "$JOB_DIR/${name}.frcmod"

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
	local MCPB_DIR="process/preparations/mcpb"

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