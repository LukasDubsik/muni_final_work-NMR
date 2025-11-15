# shellcheck disable=SC2148
# Guard so we don't load twice
[[ ${_DATA_SH_LOADED:-0} -eq 1 ]] && return
_DATA_SH_LOADED=1

# run_analysis META NUM_FRAMES
# Analyze the results from the gauss nmr run and get necessary data
# Globals: none
# Returns: Nothing
run_analysis() {
	#Load the inputs
	local meta=$1
	local num_frames=$2
	local sigma=$3
	local limit=$4

	local job_name="analysis"

	info "Started running $job_name"

    #Start by converting the input mol into a xyz format -necessary for crest
	JOB_DIR="process/spectrum/$job_name"
	ensure_dir $JOB_DIR

	SRC_DIR_1="lib/general_scripts/bash/general"
	SRC_DIR_2="lib/general_scripts/awk"
	SRC_DIR_3="process/spectrum/gaussian/nmr"

	substitute_name_sh_data "$SRC_DIR_1/log_to_plot.sh" "$JOB_DIR" "" "$limit" "$sigma"
	move_inp_file "average_plot.sh" "$SRC_DIR_1" "$JOB_DIR"
	move_inp_file "gfj_to_plot.awk" "$SRC_DIR_2" "$JOB_DIR"

	#Copy the log files from gaussian runs
	cp -r $SRC_DIR_3 $JOB_DIR

	#Move to the directory to run the scripts
	cd $JOB_DIR || die "Couldn'r enter the $JOB_DIR"

	#Run the script and average the resulting nmr spectra
	bash log_to_plot.sh

	#Return back
	cd ../../.. || die "Couldn't back to the main directory"

	#Check that the final files are truly present
	check_res_file "$JOB_DIR/avg.dat" "$JOB_DIR" "$job_name"

	success "$job_name has finished correctly"

	#Write to the log a finished operation
	add_to_log "$job_name" "$LOG"
}


sed "s/\${name}/${name}/g" $SCRIPTS/plot_nmr.plt > process/spectrum/plotting/plot_nmr.plt || { echo -e "\t\t\t[$CROSS] ${RED} Failed to modify the plot_nmr.plt file!${NC}"; exit 1; }
#Run the script
#Finally plot and check presence of the graphic file
gnuplot plot_nmr.plt || { echo -e "\t\t\t[$CROSS] ${RED} Failed to run gnuplot for NMR spectrum!${NC}"; exit 1; }
mv "${name}"_nmr.png "${save_as}".png
cd ../../../ || { echo -e "\t\t\t[$CROSS] ${RED} Failed to return to main directory after plotting!${NC}"; exit 1; }
if [[ ! -f process/spectrum/plotting/${save_as}.png ]]; then
    echo -e "\t\t\t[$CROSS] ${RED} Plotting the NMR spectrum failed, no file found!${NC}"
    exit 1
else
    echo -e "\t\t\t[$CHECKMARK] Plotting the NMR spectrum successful."
fi