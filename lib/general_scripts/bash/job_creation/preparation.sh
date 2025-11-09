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

	info "Started running crest"

	#Start with finding the most stable conformation
    module add openbabel > /dev/null 2>&1

    #Start by converting the input mol into a xyz format -necessary for crest
	JOB_DIR="process/preparations/crest"
	ensure_dir $JOB_DIR

	#Constrcut the job file
	if [[ $meta == "true" ]]; then
		substitute_name_sh_meta_start "$JOB_DIR" "\$DATADIR/${name}.xyz" "${directory}" "$env"
		substitute_name_sh_meta_end "$JOB_DIR"
		substitute_name_sh "crest_metacentrum" "$JOB_DIR" "" "${name}" "" ""
		construct_sh_meta "$JOB_DIR" "crest"
	else
		substitute_name_sh_wolf_start "$JOB_DIR"
		substitute_name_sh "crest" "$JOB_DIR" "crest" "${name}" "" ""
		construct_sh_wolf "$JOB_DIR" "crest"
	fi

    obabel -imol2 "${INPUTS}/structures/${name}.mol2" -oxyz -O "${JOB_DIR}/${name}.xyz" > /dev/null 2>&1
    #Run the crest simulation
    submit_job "$meta" "crest" "$JOB_DIR" 4 16 0 "01:00:00"
    #Convert back to mol2 format
    obabel -ixyz "${JOB_DIR}/crest_best.xyz" -omol2 -O "${JOB_DIR}/${name}_crest.mol2" > /dev/null 2>&1
    
	#Check that the final files are truly present
	check_res_file "${name}_crest.mol2" "$JOB_DIR" "crest"

	success "\tcrest has finished correctly"

	#Write to the log a finished operation
	add_to_log "crest" "$LOG"
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

	info "Started running antechamber"

    #Start by converting the input mol into a xyz format -necessary for crest
	JOB_DIR="process/preparations/antechamber"
	ensure_dir $JOB_DIR

	SRC_DIR="process/preparations/crest"

	#Copy the data from crest
	move_inp_file "${name}_crest.mol2" "$SRC_DIR" "$JOB_DIR"

	#Constrcut the job file
	if [[ $meta == "true" ]]; then
		substitute_name_sh_meta_start "$JOB_DIR" "\$DATADIR/${name}_crest.mol2" "${directory}" ""
		substitute_name_sh_meta_end "$JOB_DIR"
		substitute_name_sh "antechamber" "$JOB_DIR" "$amber" "$name" "" ""
		construct_sh_meta "$JOB_DIR" "antechamber"
	else
		substitute_name_sh_wolf_start "$JOB_DIR"
		substitute_name_sh "antechmaber" "$JOB_DIR" "$amber" "$name" "" ""
		construct_sh_wolf "$JOB_DIR" "antechamber"
	fi

    #Run the antechmaber
    submit_job "$meta" "antechmaber" "$JOB_DIR" 4 4 0 "01:00:00"

	#Check that the final files are truly present
	check_res_file "${name}_charges.mol2" "$JOB_DIR" "antechamber"

	success "\tantechamber has finished correctly"

	#Write to the log a finished operation
	add_to_log "antechamber" "$LOG"
}

# run_antechamber NAME DIRECTORY META AMBER
# Runs everything pertaining to antechmaber
# Globals: none
# Returns: Nothing
run_parmchk2() {
	#Load the inputs
	local name=$1
	local directory=$2
	local meta=$3
	local amber=$4

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
		substitute_name_sh_meta_start "$JOB_DIR" "\$DATADIR/${name}_charges.mol2" "${directory}" ""
		substitute_name_sh_meta_end "$JOB_DIR"
		substitute_name_sh "$job_name" "$JOB_DIR" "$amber" "$name" "" ""
		construct_sh_meta "$JOB_DIR" "$job_name"
	else
		substitute_name_sh_wolf_start "$JOB_DIR"
		substitute_name_sh "$job_name" "$JOB_DIR" "$amber" "$name" "" ""
		construct_sh_wolf "$JOB_DIR" "$job_name"
	fi

    #Run the antechmaber
    submit_job "$meta" "$job_name" "$JOB_DIR" 4 4 0 "01:00:00"

	#Check that the final files are truly present
	check_res_file "${name}.frcmod" "$JOB_DIR" "$job_name"

	success "\t$job_name has finished correctly"

	#Write to the log a finished operation
	add_to_log "$job_name" "$LOG"
}