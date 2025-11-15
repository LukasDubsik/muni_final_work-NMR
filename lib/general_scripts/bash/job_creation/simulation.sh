# shellcheck disable=SC2148
# Guard so we don't load twice
[[ ${_SIMULATION_SH_LOADED:-0} -eq 1 ]] && return
_SIMULATION_LOADED=1

# run_opt_water NAME DIRECTORY META AMBER
# Optimalize the water system without touching the solute
# Globals: none
# Returns: Nothing
run_opt_water() {
	#Load the inputs
	local name=$1
	local directory=$2
	local meta=$3
	local amber=$4
	local in_file=$5

	local job_name="opt_water"

	info "Started running $job_name"

    #Start by converting the input mol into a xyz format -necessary for crest
	JOB_DIR="process/simulation/$job_name"
	ensure_dir $JOB_DIR

	SRC_DIR_1="process/preparations/tleap"

	#Copy the data from antechamber
	move_inp_file "${name}.rst7" "$SRC_DIR_1" "$JOB_DIR"
	move_inp_file "${name}.parm7" "$SRC_DIR_1" "$JOB_DIR"

	#Copy the .in file for tleap
	substitute_name_in "$in_file" "$JOB_DIR" "$name" ""

	#Constrcut the job file
	if [[ $meta == "true" ]]; then
		substitute_name_sh_meta_start "$JOB_DIR" "${directory}" ""
		substitute_name_sh_meta_end "$JOB_DIR"
		substitute_name_sh "$job_name" "$JOB_DIR" "$amber" "$name" "$job_name.in" "" ""
		construct_sh_meta "$JOB_DIR" "$job_name"
	else
		substitute_name_sh_wolf_start "$JOB_DIR"
		substitute_name_sh "$job_name" "$JOB_DIR" "$amber" "$name" "$job_name.in" "" ""
		construct_sh_wolf "$JOB_DIR" "$job_name"
	fi

    #Run the antechmaber
    submit_job "$meta" "$job_name" "$JOB_DIR" 8 8 0 "04:00:00"

	#Check that the final files are truly present
	check_res_file "${name}_opt_water.rst7" "$JOB_DIR" "$job_name"

	success "$job_name has finished correctly"

	#Write to the log a finished operation
	add_to_log "$job_name" "$LOG"
}

# run_opt_all NAME DIRECTORY META AMBER
# Optimalize the whole system (water + solute)
# Globals: none
# Returns: Nothing
run_opt_all() {
	#Load the inputs
	local name=$1
	local directory=$2
	local meta=$3
	local amber=$4
	local in_file=$5

	local job_name="opt_all"

	info "Started running $job_name"

    #Start by converting the input mol into a xyz format -necessary for crest
	JOB_DIR="process/simulation/$job_name"
	ensure_dir $JOB_DIR

	SRC_DIR_1="process/simulation/opt_water"

	#Copy the data from antechamber
	move_inp_file "${name}_opt_water.rst7" "$SRC_DIR_1" "$JOB_DIR"
	move_inp_file "${name}.parm7" "$SRC_DIR_1" "$JOB_DIR"

	#Copy the .in file for tleap
	substitute_name_in "$in_file" "$JOB_DIR" "$name" ""

	#Constrcut the job file
	if [[ $meta == "true" ]]; then
		substitute_name_sh_meta_start "$JOB_DIR" "${directory}" ""
		substitute_name_sh_meta_end "$JOB_DIR"
		substitute_name_sh "$job_name" "$JOB_DIR" "$amber" "$name" "$job_name.in" "" ""
		construct_sh_meta "$JOB_DIR" "$job_name"
	else
		substitute_name_sh_wolf_start "$JOB_DIR"
		substitute_name_sh "$job_name" "$JOB_DIR" "$amber" "$name" "$job_name.in" "" ""
		construct_sh_wolf "$JOB_DIR" "$job_name"
	fi

    #Run the antechmaber
    submit_job "$meta" "$job_name" "$JOB_DIR" 8 8 0 "04:00:00"

	#Check that the final files are truly present
	check_res_file "${name}_opt_all.rst7" "$JOB_DIR" "$job_name"

	success "$job_name has finished correctly"

	#Write to the log a finished operation
	add_to_log "$job_name" "$LOG"
}

# run_opt_temp NAME DIRECTORY META AMBER
# Heat the system to the production temperature
# Globals: none
# Returns: Nothing
run_opt_temp() {
	#Load the inputs
	local name=$1
	local directory=$2
	local meta=$3
	local amber=$4
	local in_file=$5

	local job_name="opt_temp"

	info "Started running $job_name"

    #Start by converting the input mol into a xyz format -necessary for crest
	JOB_DIR="process/simulation/$job_name"
	ensure_dir $JOB_DIR

	SRC_DIR_1="process/simulation/opt_all"

	#Copy the data from antechamber
	move_inp_file "${name}_opt_all.rst7" "$SRC_DIR_1" "$JOB_DIR"
	move_inp_file "${name}.parm7" "$SRC_DIR_1" "$JOB_DIR"

	#Copy the .in file for tleap
	substitute_name_in "$in_file" "$JOB_DIR" "$name" ""

	#Constrcut the job file
	if [[ $meta == "true" ]]; then
		substitute_name_sh_meta_start "$JOB_DIR" "${directory}" ""
		substitute_name_sh_meta_end "$JOB_DIR"
		substitute_name_sh "$job_name" "$JOB_DIR" "$amber" "$name" "$in_file.in" "" ""
		construct_sh_meta "$JOB_DIR" "$job_name"
	else
		substitute_name_sh_wolf_start "$JOB_DIR"
		substitute_name_sh "$job_name" "$JOB_DIR" "$amber" "$name" "$in_file.in" "" ""
		construct_sh_wolf "$JOB_DIR" "$job_name"
	fi

    #Run the antechmaber
    submit_job "$meta" "$job_name" "$JOB_DIR" 8 8 1 "08:00:00"

	#Check that the final files are truly present
	check_res_file "${name}_opt_temp.rst7" "$JOB_DIR" "$job_name"

	success "$job_name has finished correctly"

	#Write to the log a finished operation
	add_to_log "$job_name" "$LOG"
}

# run_opt_pres NAME DIRECTORY META AMBER
# Stabilize the system at production pressure
# Globals: none
# Returns: Nothing
run_opt_pres() {
	#Load the inputs
	local name=$1
	local directory=$2
	local meta=$3
	local amber=$4
	local in_file=$5

	local job_name="opt_pres"

	info "Started running $job_name"

    #Start by converting the input mol into a xyz format -necessary for crest
	JOB_DIR="process/simulation/$job_name"
	ensure_dir $JOB_DIR

	SRC_DIR_1="process/simulation/opt_temp"

	#Copy the data from antechamber
	move_inp_file "${name}_opt_temp.rst7" "$SRC_DIR_1" "$JOB_DIR"
	move_inp_file "${name}.parm7" "$SRC_DIR_1" "$JOB_DIR"

	#Copy the .in file for tleap
	substitute_name_in "$in_file" "$JOB_DIR" "$name" ""

	#Constrcut the job file
	if [[ $meta == "true" ]]; then
		substitute_name_sh_meta_start "$JOB_DIR" "${directory}" ""
		substitute_name_sh_meta_end "$JOB_DIR"
		substitute_name_sh "$job_name" "$JOB_DIR" "$amber" "$name" "$in_file.in" "" ""
		construct_sh_meta "$JOB_DIR" "$job_name"
	else
		substitute_name_sh_wolf_start "$JOB_DIR"
		substitute_name_sh "$job_name" "$JOB_DIR" "$amber" "$name" "$in_file.in" "" ""
		construct_sh_wolf "$JOB_DIR" "$job_name"
	fi

    #Run the antechmaber
    submit_job "$meta" "$job_name" "$JOB_DIR" 8 8 1 "08:00:00"

	#Check that the final files are truly present
	check_res_file "${name}_opt_pres.rst7" "$JOB_DIR" "$job_name"

	success "$job_name has finished correctly"

	#Write to the log a finished operation
	add_to_log "$job_name" "$LOG"
}

# run_md NAME DIRECTORY META AMBER
# Runs the final, production level molecular dynamic simulation
# Globals: none
# Returns: Nothing
run_md() {
	#Load the inputs
	local name=$1
	local directory=$2
	local meta=$3
	local amber=$4
	local in_file=$5

	local job_name="md"

	info "Started running $job_name"

    #Start by converting the input mol into a xyz format -necessary for crest
	JOB_DIR="process/simulation/$job_name"
	ensure_dir $JOB_DIR

	SRC_DIR_1="process/simulation/opt_pres"

	#Copy the data from antechamber
	move_inp_file "${name}_opt_pres.rst7" "$SRC_DIR_1" "$JOB_DIR"
	move_inp_file "${name}.parm7" "$SRC_DIR_1" "$JOB_DIR"

	#Copy the .in file for tleap
	substitute_name_in "$in_file" "$JOB_DIR" "$name" ""

	#Constrcut the job file
	if [[ $meta == "true" ]]; then
		substitute_name_sh_meta_start "$JOB_DIR" "${directory}" ""
		substitute_name_sh_meta_end "$JOB_DIR"
		substitute_name_sh "$job_name" "$JOB_DIR" "$amber" "$name" "$in_file.in" "" ""
		construct_sh_meta "$JOB_DIR" "$job_name"
	else
		substitute_name_sh_wolf_start "$JOB_DIR"
		substitute_name_sh "$job_name" "$JOB_DIR" "$amber" "$name" "$in_file.in" "" ""
		construct_sh_wolf "$JOB_DIR" "$job_name"
	fi

    #Run the antechmaber
    submit_job "$meta" "$job_name" "$JOB_DIR" 8 8 2 "24:00:00"

	#Check that the final files are truly present
	check_res_file "${name}_md.rst7" "$JOB_DIR" "$job_name"

	success "$job_name has finished correctly"

	#Write to the log a finished operation
	add_to_log "$job_name" "$LOG"
}

# run_cpptraj NAME DIRECTORY META AMBER CURR_RUN
# Run cppytraj and sample the needed atoms/molecules for the gaussian NMR
# Globals: none
# Returns: Nothing
run_cpptraj() {
	#Load the inputs
	local name=$1
	local directory=$2
	local meta=$3
	local amber=$4
	local curr_run=$5
	local limit=$6
	local in_file=$7

	local job_name="cpptraj"

	info "Started running $job_name"

    #Start by converting the input mol into a xyz format -necessary for crest
	JOB_DIR="process/simulation/$job_name"
	ensure_dir $JOB_DIR

	SRC_DIR_1="process/simulation/md"
	SRC_DIR_2="lib/general_scripts/bash/general"

	#Copy the data from antechamber
	move_inp_file "${name}_md.mdcrd" "$SRC_DIR_1" "$JOB_DIR"
	move_inp_file "${name}.parm7" "$SRC_DIR_1" "$JOB_DIR"

	#Copy the .in file for tleap
	substitute_name_in "$in_file" "$JOB_DIR" "$name" "$limit"

	#Constrcut the job file
	if [[ $meta == "true" ]]; then
		substitute_name_sh_meta_start "$JOB_DIR" "${directory}" ""
		substitute_name_sh_meta_end "$JOB_DIR"
		substitute_name_sh "$job_name" "$JOB_DIR" "$amber" "$name" "$job_name.in" "" ""
		construct_sh_meta "$JOB_DIR" "$job_name"
	else
		substitute_name_sh_wolf_start "$JOB_DIR"
		substitute_name_sh "$job_name" "$JOB_DIR" "$amber" "$name" "$job_name.in" "" ""
		construct_sh_wolf "$JOB_DIR" "$job_name"
	fi

    #Run the antechmaber
    submit_job "$meta" "$job_name" "$JOB_DIR" 8 8 0 "02:00:00"

	#Check that the final files are truly present
	check_res_file "${name}_frame.xyz" "$JOB_DIR" "$job_name"

	#Split the .xyz file into individual files
	#Move the bash script for it
	move_inp_file "split_xyz.sh" "$SRC_DIR_2" "$JOB_DIR"

	#Ensure the final dir exists
    ensure_dir $JOB_DIR/frames

	#Run the bash script
    cd "$JOB_DIR" || die "Couldn't enter the cpptraj directory"
    bash split_xyz.sh "$curr_run" < "${name}_frame.xyz"
    cd ../../../ || die "Couldn't return back from the cpptraj dir"

	success "$job_name has finished correctly"

	#Write to the log a finished operation
	add_to_log "$job_name" "$LOG"
}

# move_finished_job RUN
# Move the results into the preparation folder and save these for future analysis
# Globals: none
# Returns: Nothing
move_finished_job() {
	local RUN=$1

	#Move the frames from cpptraj to the gauss_prep
	SRC_DIR="process/simulation/cpptraj"
	DST_DIR="process/spectrum/gauss_prep"

	cp -r $SRC_DIR/frames/* "$DST_DIR/frames" || exit 1

	#Create a directory to save the results into
	ensure_dir "process/run_$RUN"

	#Move all the files there
	mv -r process/simulation/* "process/run_$RUN"
}