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
    local name=$1
    local directory=$2
    local meta=$3
    local amber=$4
    local mcpb_params=$5

    local job_name="mcpb"
    info "Started running $job_name"

    JOB_DIR="process/preparations/$job_name"
    ensure_dir "$JOB_DIR"

    # Default params if config didn’t provide anything sane
    if [[ -z "${mcpb_params:-}" ]]; then
        mcpb_params="-i ${name}_mcpb.in -s 4"
    fi

    # Expand common placeholders people put into sim.txt
    mcpb_params="${mcpb_params//\$\{name\}/$name}"
    mcpb_params="${mcpb_params//\$NAME/$name}"
    mcpb_params="${mcpb_params//\"/}"

    # MCPB input must exist (user-provided)
    local mcpb_in_src="${INPUTS}/structures/${name}_mcpb.in"
    [[ -f "$mcpb_in_src" ]] || die "Missing MCPB input file: ${mcpb_in_src}"
    cp "$mcpb_in_src" "${JOB_DIR}/${name}_mcpb.in" || die "Failed copying MCPB input file"

    # Stage common pipeline products that MCPB inputs usually reference
    # (does not fail if not present; MCPB .in parsing below will enforce required ones)
    copy_first_existing "${name}.frcmod" "$JOB_DIR" \
        "process/preparations/parmchk2" || true

    copy_first_existing "${name}_charges_fix.mol2" "$JOB_DIR" \
        "process/preparations/nemesis_fix" \
        "process/preparations/antechamber" || true

    copy_first_existing "${name}_charges.mol2" "$JOB_DIR" \
        "process/preparations/antechamber" || true

    copy_first_existing "${name}.mol2" "$JOB_DIR" \
        "${INPUTS}/structures" || true

    copy_first_existing "${name}.pdb" "$JOB_DIR" \
        "${INPUTS}/structures" || true

    # Parse MCPB .in for referenced files and enforce staging
    # Keys per MCPB.py tutorial: original_pdb, ion_mol2files, naa_mol2files, frcmod_files, etc.
    # 
    local refs=()
    local line=""
    while IFS= read -r line; do
        line="${line#*=}"
        line="${line//\"/}"
        line="${line//,/ }"
        for tok in $line; do
            refs+=("$tok")
        done
    done < <(grep -E '^[[:space:]]*(original_pdb|ion_pdbfile|ion_mol2files|naa_mol2files|frcmod_files)[[:space:]]*=' "${JOB_DIR}/${name}_mcpb.in" || true)

    local f=""
    for f in "${refs[@]}"; do
        # skip obvious non-filenames
        [[ -z "$f" ]] && continue

        if [[ -f "${JOB_DIR}/${f}" ]]; then
            continue
        fi

        copy_first_existing "$f" "$JOB_DIR" \
            "${INPUTS}/structures" \
            "process/preparations/antechamber" \
            "process/preparations/nemesis_fix" \
            "process/preparations/parmchk2" \
            "process/preparations/mcpb" \
            "." || die "MCPB input references missing file: $f (not found in any known staging dirs)"
    done

    # Build the job script
    local mcpb_script=""
    if [[ "$meta" == "true" ]]; then
        mcpb_script="${JOB_DIR}/${job_name}_start.sh"
        substitute_name_sh "$job_name" "$JOB_DIR" "$amber" "$name" "" "" "$mcpb_params" ""
        construct_sh_meta "$JOB_DIR" "$job_name" "$amber" "$name" "" "" "$mcpb_params" ""
    else
        create_wolf_sh "$job_name" "$JOB_DIR"
        substitute_name_sh "$job_name" "$JOB_DIR" "$amber" "$name" "" "" "$mcpb_params" ""
        construct_sh_wolf "$JOB_DIR" "$job_name" "$amber" "$name" "" "" "$mcpb_params" ""
    fi

    # Run (MCPB is CPU-side)
    submit_job "$meta" "$job_name" "$JOB_DIR" 8 4 0 "08:00:00"

    # Normalize expected outputs
    local frcmod_out=""
    if [[ -f "${JOB_DIR}/mcpbpy.frcmod" ]]; then
        frcmod_out="${JOB_DIR}/mcpbpy.frcmod"
    else
        frcmod_out="$(ls -1 "${JOB_DIR}"/*mcpbpy*.frcmod 2>/dev/null | head -n 1 || true)"
    fi

    [[ -n "$frcmod_out" ]] || {
        ls -la "$JOB_DIR" >> "${JOB_DIR}/jobs_info.txt" 2>/dev/null || true
        die "MCPB finished but no mcpbpy frcmod was produced (check ${JOB_DIR}/*.e* and jobs_info.txt)."
    }

    # Ensure canonical filename for downstream steps
    if [[ "$frcmod_out" != "${JOB_DIR}/mcpbpy.frcmod" ]]; then
        cp "$frcmod_out" "${JOB_DIR}/mcpbpy.frcmod" || die "Failed normalizing MCPB frcmod output"
    fi

    # Export MCPB parameters into the ligand frcmod used by tleap
    local dst_frcmod="process/preparations/parmchk2/${name}.frcmod"
    if [[ -f "$dst_frcmod" ]]; then
        if ! grep -q "### MCPB.py (auto) ###" "$dst_frcmod"; then
            printf "\n### MCPB.py (auto) ###\n" >> "$dst_frcmod"
            cat "${JOB_DIR}/mcpbpy.frcmod" >> "$dst_frcmod"
        fi
    else
        cp "${JOB_DIR}/mcpbpy.frcmod" "$dst_frcmod" || die "Failed exporting MCPB frcmod -> $dst_frcmod"
    fi

    # Keep library for tleap if MCPB produced it
    if [[ -f "${JOB_DIR}/mcpbpy.lib" ]]; then
        success "MCPB produced mcpbpy.lib (will be available for tleap staging)"
    fi

    check_res_file "mcpbpy.frcmod" "$JOB_DIR" "$job_name"
    success "Finished running $job_name"

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