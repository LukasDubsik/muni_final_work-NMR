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
# run_mcpb NAME DIRECTORY META AMBER IN_MOL2 LIG_FRCMOD
run_mcpb() {
	local name="$1"
	local directory="$2"
	local meta="$3"
	local amber="$4"
	local in_mol2="$5"
	local lig_frcmod="$6"

	local job_name="mcpb"
	local JOB_DIR="process/preparations/$job_name"

	# Only run if a heavy metal is present
	if ! mol2_has_metal "$in_mol2"; then
		return 0
	fi

	info "Heavy metal detected in $in_mol2 – running MCPB.py"

	rm -rf "$JOB_DIR"
	ensure_dir "$JOB_DIR"

	# Stage all MCPB inputs in JOB_DIR (so the job can just copy and run)
	local src_mol2="$JOB_DIR/${name}_mcpb_source.mol2"
	cp "$in_mol2" "$src_mol2"
	cp "$lig_frcmod" "$JOB_DIR/LIG.frcmod"

	# Sanitize MOL2 if it contains an extra element column in @<TRIPOS>ATOM
	mol2_sanitize_atom_coords_inplace "$src_mol2"

	# Identify the first metal (Au in your case)
	local metal_line
	metal_line="$(mol2_first_metal "$src_mol2")"
	[[ -n "$metal_line" ]] || die "Failed to detect metal in $src_mol2"

	local metal_id metal_elem metal_charge mx my mz
	read -r metal_id metal_elem metal_charge mx my mz <<< "$metal_line"

	# Generate PDB and split MOL2s
	mol2_to_mcpb_pdb "$src_mol2" "$JOB_DIR/${name}_mcpb.pdb" "$metal_id"
	mol2_strip_atom "$src_mol2" "$JOB_DIR/LIG.mol2" "$metal_id"
	write_single_ion_mol2 "$JOB_DIR/${metal_elem}.mol2" "$metal_elem" "$metal_charge" "$mx" "$my" "$mz"

	# Generate MCPB input (resolved values; no runtime substitutions needed)
		# Generate MCPB input (resolved values; no runtime substitutions needed)
	cat > "$JOB_DIR/${name}_mcpb.in" <<EOF
original_pdb ${name}_mcpb.pdb
group_name ${name}
cut_off 2.8
ion_ids ${metal_id}
ion_mol2files ${metal_elem}.mol2
naa_mol2files LIG.mol2
frcmod_files LIG.frcmod
large_opt 0
EOF


	# Build job script (avoid quoting issues; avoid relying on broken template substitutions)
	if [[ $meta == "true" ]]; then
		substitute_name_sh_meta_start "$JOB_DIR" "$directory" ""
	else
		substitute_name_sh_wolf_start "$JOB_DIR"
	fi

	cat > "$JOB_DIR/job_file.txt" <<EOF
module add ${amber}
MCPB.py -i ${name}_mcpb.in ${mcpb_cmd:-"-s 1"}
EOF

	if [[ $meta == "true" ]]; then
		substitute_name_sh_meta_end "$JOB_DIR" "$JOB_DIR"
		construct_sh_meta "$JOB_DIR" "$job_name"
	else
		substitute_name_sh_wolf_end "$JOB_DIR" "$JOB_DIR"
		construct_sh_wolf "$JOB_DIR" "$job_name"
	fi

	# Run
	submit_job "$meta" "$job_name" "$JOB_DIR" 8 8 0 "01:00:00"

	if [[ ! -f "$JOB_DIR/${name}_tleap.in" && -f "$JOB_DIR/tleap.in" ]]; then
		cp "$JOB_DIR/tleap.in" "$JOB_DIR/${name}_tleap.in"
	fi

	check_res_file "${name}_tleap.in" "$JOB_DIR" "$job_name"

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
    run_mcpb "$name" "$directory" "$meta" "$amber" "$JOB_DIR/${name}_charges.mol2" "$JOB_DIR/${name}.frcmod"

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
		substitute_name_sh "$job_name" "$JOB_DIR" "$amber" "$name" "" "" "$tleap_in" ""
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