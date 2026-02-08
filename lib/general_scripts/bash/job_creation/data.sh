# shellcheck disable=SC2148
# Guard so we don't load twice
[[ ${_DATA_SH_LOADED:-0} -eq 1 ]] && return
_DATA_SH_LOADED=1

# run_analysis SIGMA LIMIT
# Analyze the results from the gauss nmr run and get necessary data
# Globals: none
# Returns: Nothing
run_analysis() {
	#Load the inputs
	local sigma=$1
	local limit=$2

	local job_name="analysis"

	info "Started running $job_name"

    #Start by converting the input mol into a xyz format -necessary for crest
	JOB_DIR="process/spectrum/$job_name"
	ensure_dir $JOB_DIR

	SRC_DIR_1="lib/general_scripts/bash/general"
	SRC_DIR_2="lib/general_scripts/awk"
	SRC_DIR_3="process/spectrum/gaussian/nmr"

	substitute_name_sh_data "general/log_to_plot.sh" "$JOB_DIR/log_to_plot.sh" "" "$limit" "$sigma" ""
	move_inp_file "average_plot.sh" "$SRC_DIR_1" "$JOB_DIR"
	move_inp_file "gjf_to_plot.awk" "$SRC_DIR_2" "$JOB_DIR"

	ensure_dir $JOB_DIR/plots

	#Copy the log files from gaussian runs
	cp -r $SRC_DIR_3 $JOB_DIR
 
	#Move to the directory to run the scripts
	cd $JOB_DIR || die "Couldn'r enter the $JOB_DIR"

	#Run the script and average the resulting nmr spectra
	bash log_to_plot.sh

	#Return back
	cd ../../.. || die "Couldn't back to the main directory"

	#Check that the final files are truly present
	check_res_file "avg.dat" "$JOB_DIR" "$job_name"
	check_res_file "all_peaks.dat" "$JOB_DIR" "$job_name"

	success "$job_name has finished correctly"

	#Write to the log a finished operation
	add_to_log "$job_name" "$LOG"
}

# run_plotting
# Given the results from analysis of the gaussian runs plot the resulting nmr spectra
# Globals: none
# Returns: Nothing
run_plotting() {
	#Load the inputs
	local name=$1
	local save_as=$2
	local filter=$3

	local job_name="plotting"

	info "Started running $job_name"

    #Start by converting the input mol into a xyz format -necessary for crest
	JOB_DIR="process/spectrum/$job_name"
	ensure_dir $JOB_DIR

	SRC_DIR_1="process/spectrum/analysis"
	SRC_DIR_2="lib/general_scripts/gnuplot"

	move_inp_file "avg.dat" "$SRC_DIR_1" "$JOB_DIR"
	move_inp_file "all_peaks.dat" "$SRC_DIR_1" "$JOB_DIR"

	if [[ $filter == "none" ]]; then
		move_inp_file "plot_nmr.plt" "$SRC_DIR_2" "$JOB_DIR"
		move_inp_file "plot_nmr_all_peaks.plt" "$SRC_DIR_2" "$JOB_DIR"
	elif [[ $filter == "alpha_beta" ]]; then
		cp "lib/general_scripts/python/filter/filter_alpha_beta.py" "$JOB_DIR"
		cp "inputs/structures/$name.mol2" "$JOB_DIR"
		move_inp_file "plot_nmr_alpha_beta.plt" "$SRC_DIR_2" "$JOB_DIR"
		move_inp_file "plot_nmr_all_peaks.plt" "$SRC_DIR_2" "$JOB_DIR"
	else
		die "Unknown filter parameter"
	fi

	#Move to the directory to run the scripts
	cd $JOB_DIR || die "Couldn't enter the $JOB_DIR"

	#Run the script(s) and generate two outputs:
	#  1) averaged/smoothed spectrum (existing behavior)
	#  2) all-peaks "stick spectrum" (no averaging, no broadening)
	if [[ $filter == "none" ]]; then
		gnuplot plot_nmr.plt
		gnuplot plot_nmr_all_peaks.plt
	elif [[ $filter == "alpha_beta" ]]; then
		python filter_alpha_beta.py avg.dat "$name.mol2" filtered_avg.dat
		gnuplot plot_nmr_alpha_beta.plt
		gnuplot plot_nmr_all_peaks.plt
	else
		die "Unknown filter parameter"
	fi

	#Return back
	cd ../../.. || die "Couldn't back to the main directory"

	#Check that the final files are truly present
	check_res_file "nmr.png" "$JOB_DIR" "$job_name"
	check_res_file "nmr_all_peaks.png" "$JOB_DIR" "$job_name"

	mv $JOB_DIR/nmr.png $JOB_DIR/"$save_as".png
	mv $JOB_DIR/nmr_all_peaks.png $JOB_DIR/"${save_as}_all_peaks".png

	success "$job_name has finished correctly"

	#Write to the log a finished operation
	add_to_log "$job_name" "$LOG"
}