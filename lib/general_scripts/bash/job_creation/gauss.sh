# shellcheck disable=SC2148
# Guard so we don't load twice
[[ ${_GAUSS_SH_LOADED:-0} -eq 1 ]] && return
_GAUSS_LOADED=1

# run_gauss_convert NAME DIRECTORY META AMBER CURR_RUN
# Convert the xyz files from the amber simulation into log files for gaussian
# Globals: none
# Returns: Nothing
run_gauss_convert() {
	#Load the inputs
	local name=$1
	local directory=$2
	local meta=$3
	local amber=$4
	local curr_run=$5
	local limit=$6
	local in_file=$7
	local mode=$8

	local job_name="gauss_prep"

	info "Started running $job_name"

    #Start by converting the input mol into a xyz format -necessary for crest
	JOB_DIR="process/spectrum/$job_name"
	ensure_dir $JOB_DIR

	SRC_DIR_1="process/simulation/md"
	SRC_DIR_2="lib/general_scripts/bash/general"
	SRC_DIR_3="lib/general_scripts/python"

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

	#Ensure the final dir exists
    ensure_dir $JOB_DIR/frames

	if [[ $mode == "no_water" ]]; then
		#Check that the final files are truly present
		check_res_file "${name}_frame.xyz" "$JOB_DIR" "$job_name"
		#Split the .xyz file into individual files
		#Move the bash script for it
		move_inp_file "split_xyz.sh" "$SRC_DIR_2" "$JOB_DIR"
		#Run the bash script
		cd "$JOB_DIR" || die "Couldn't enter the cpptraj directory"
		bash split_xyz.sh "$curr_run" < "${name}_frame.xyz"
		cd ../../../ || die "Couldn't return back from the cpptraj dir"
	else 
		#Check that the final files are truly present
		check_res_file "frames.nc" "$JOB_DIR" "$job_name"
		#Copy the python script
		move_inp_file "select_interact.py" "$SRC_DIR_3" "$JOB_DIR"
		#Move to the job dir
		cd "$JOB_DIR" || die "Couldn't enter the cpptraj directory"
		#Run the python script
		python select_interact.py "${name}.parm7" "$curr_run"
		#Return to the base dir
		cd ../../../ || die "Couldn't return back from the cpptraj dir"
	fi

	success "$job_name has finished correctly"

	#Write to the log a finished operation
	add_to_log "$job_name" "$LOG"
}





substitute_name_sh "xyz_to_gfj.sh" "spectrum/gauss_prep/"
#(( limit -= 3))
mkdir -p process/spectrum/gauss_prep/gauss
cd process/spectrum/gauss_prep/ || { echo -e "\t\t\t[$CROSS] ${RED} Failed to enter the gauss_prep directory!${NC}"; exit 1; }
bash xyz_to_gfj.sh || { echo -e "\t\t\t[$CROSS] ${RED} Failed to convert to .gjf format!${NC}"; exit 1; }
cd ../../../ || { echo -e "\t\t\t[$CROSS] ${RED} Failed to return to main directory after converting!${NC}"; exit 1; }
if [[ ! -d process/spectrum/gauss_prep/gauss || -z "$(ls -A process/spectrum/gauss_prep/gauss)" ]]; then
    echo -e "\t\t\t[$CROSS] ${RED} Conversion to .gjf format failed, no files found!${NC}"
    exit 1
else
    echo -e "\t\t\t[$CHECKMARK] Conversion to .gjf format successful."
fi