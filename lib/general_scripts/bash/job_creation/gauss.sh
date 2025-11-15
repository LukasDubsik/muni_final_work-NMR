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

	SRC_DIR_1="lib/general_scripts/bash/general"

	move_inp_file "xyz_to_gfj.sh" "$SRC_DIR_1" "$JOB_DIR"

    #Run the antechmaber
    submit_job "$meta" "$job_name" "$JOB_DIR" 8 8 0 "02:00:00"

	#Ensure the final dir exists
    ensure_dir $JOB_DIR/gauss

	#Run the bash script
	cd "$JOB_DIR" || die "Couldn't enter the cpptraj directory"
	bash xyz_to_gfj.sh
	cd ../../../ || die "Couldn't return back from the cpptraj dir"

	#Check that the final files are truly present
	check_res_file "gauss/frame.100.gfj" "$JOB_DIR" "$job_name"

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