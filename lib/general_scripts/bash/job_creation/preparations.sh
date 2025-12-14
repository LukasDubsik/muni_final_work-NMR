# shellcheck disable=SC2148
# Guard so we don't load twice
[[ ${_PREPARATION_SH_LOADED:-0} -eq 1 ]] && return
_PREPARATION_LOADED=1

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
	ensure_dir $JOB_DIR

	SRC_DIR="process/preparations/crest"

	#Copy the data from crest
	move_inp_file "${name}_crest.mol2" "$SRC_DIR" "$JOB_DIR"

	# If a heavy metal is present, antechamber cannot run sqm/AM1-BCC.
	# Force it to reuse the input charges from the MOL2.
	if mol2_has_heavy_metal "${INPUTS}/structures/${name}.mol2" && echo "$antechamber_parms" | grep -qE "(^|[[:space:]])-c[[:space:]]*bcc([[:space:]]|$)"; then
		info "Heavy metal detected in ${INPUTS}/structures/${name}.mol2; forcing antechamber to use input charges (-c rc) instead of AM1-BCC."
		antechamber_parms=$(echo "$antechamber_parms" | sed -E "s/(^|[[:space:]])-c[[:space:]]*bcc([[:space:]]|$)/\\1-c rc\\2/")
	fi

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

    #Run the antechmaber
    submit_job "$meta" "$job_name" "$JOB_DIR" 4 4 0 "01:00:00"

	#Check that the final files are truly present
	check_res_file "${name}_charges.mol2" "$JOB_DIR" "$job_name"

	success "$job_name has finished correctly"

	#Write to the log a finished operation
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

	# Optional metal-center parametrization (MCPB.py)
	# If the MOL2 contains a heavy metal and user provided an MCPB command, run it
	if [[ -n "${mcpb_cmd:-}" ]] && mol2_has_heavy_metal "${INPUTS}/structures/${name}.mol2"; then
		info "Heavy metal detected in ${INPUTS}/structures/${name}.mol2; running MCPB.py"
		run_mcpb "$directory" "$amber" "$name" "$meta" "${mcpb_cmd}"
	fi

	success "$job_name has finished correctly"

	#Write to the log a finished operation
	add_to_log "$job_name" "$LOG"
}

run_mcpb() {
	local directory=$1
	local amber=$2
	local name=$3
	local meta=$4
	local mcpb_cmd=$5

	local JOB_DIR="process/preparations/mcpb"
	local SRC_DIR="process/preparations/parmchk2"
	local job_name="mcpb"

	info "Started running mcpb"

	# Ensure the directory exists
	ensure_dir "$JOB_DIR"

	# Stage required inputs into the MCPB job directory (these get copied to $SCRATCHDIR)
	#   - MCPB control file
	local mcpb_in=""
	for cand in \
		"${INPUTS}/structures/${name}_mcpb.in" \
		"${INPUTS}/simulation/${name}_mcpb.in" \
		"${name}_mcpb.in"; do
		if [[ -f "$cand" ]]; then
			mcpb_in=$cand
			break
		fi
	done
	[[ -n "$mcpb_in" ]] || die "Missing MCPB input file ${name}_mcpb.in (looked in ${INPUTS}/structures, ${INPUTS}/simulation, and current dir)"
	cp "$mcpb_in" "$JOB_DIR/${name}_mcpb.in" || die "Failed to copy MCPB input file into $JOB_DIR"

	#   - Bring forward ligand/force-field artifacts for convenience/debugging
	[[ -f "$SRC_DIR/${name}.frcmod" ]] && cp "$SRC_DIR/${name}.frcmod" "$JOB_DIR/${name}.frcmod" || true
	[[ -f "$SRC_DIR/${name}_charges.mol2" ]] && cp "$SRC_DIR/${name}_charges.mol2" "$JOB_DIR/${name}_charges.mol2" || true

	#   - Also stage any .pdb files referenced in the MCPB input
	local pdb_refs
	pdb_refs=$(grep -Eo '[^[:space:]]+\.pdb' "$mcpb_in" | sort -u || true)
	for pdb in $pdb_refs; do
		if [[ -f "${INPUTS}/structures/${pdb}" ]]; then
			cp "${INPUTS}/structures/${pdb}" "$JOB_DIR/${pdb}" || die "Failed to copy ${pdb} into $JOB_DIR"
		elif [[ -f "${pdb}" ]]; then
			cp "${pdb}" "$JOB_DIR/${pdb}" || die "Failed to copy ${pdb} into $JOB_DIR"
		else
			warn "MCPB input references ${pdb}, but it was not found in ${INPUTS}/structures or current dir"
		fi
	done

	# Sanitize params so config can use $NAME or ${name} without breaking the job script
	local mcpb_params="$mcpb_cmd"
	if [[ "$mcpb_params" == \"*\" && "$mcpb_params" == *\" ]]; then
		mcpb_params="${mcpb_params:1:${#mcpb_params}-2}"
	fi
	mcpb_params=$(printf '%s' "$mcpb_params" | sed "s/\\\$NAME/${name}/g; s/\\\${name}/${name}/g")

	# Create the script and submit
	substitute_name_sh_meta_start "$JOB_DIR" "${directory}" ""
	substitute_name_sh "$job_name" "$JOB_DIR" "$amber" "$name" "" "" "$mcpb_params" ""
	substitute_name_sh_meta_end "$JOB_DIR" ""
	construct_sh_meta "$JOB_DIR" "$job_name" "meta_start" "$job_name" "meta_end"
	submit_job "$directory" "$job_name" "$JOB_DIR" 1 8 "24:00:00" "" "$meta" ""

	# Verify output
	check_res_file "mcpbpy.frcmod" "$JOB_DIR" "$job_name"

	# Merge MCPB frcmod into the parmchk2 frcmod (stable across reruns)
	local base_frcmod="$SRC_DIR/${name}.frcmod"
	local base_backup="$SRC_DIR/${name}.frcmod.base"
	[[ -f "$base_frcmod" ]] || die "Expected base frcmod $base_frcmod to exist before MCPB merge"
	[[ -f "$base_backup" ]] || cp "$base_frcmod" "$base_backup"
	cat "$base_backup" "$JOB_DIR/mcpbpy.frcmod" > "$base_frcmod" || die "Failed to merge MCPB frcmod into $base_frcmod"

	# Keep MCPB library around if produced (tleap_spec.in can load it via loadoff)
	[[ -f "$JOB_DIR/mcpbpy.lib" ]] && cp "$JOB_DIR/mcpbpy.lib" "$SRC_DIR/mcpbpy.lib" || true
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