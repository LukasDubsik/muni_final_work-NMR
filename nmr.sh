#!/bin/bash
# Project: Pipeline for NMR simulations
# Author: Lukas Dubsik
# Date: 07.11.2025
# Description: A simple script that runs Amber simulations and Gaussian to get NMR spectrum of given molecule


# ----- Enviroment -----
# Setup the enviroment for the script

#Exit upon any error in the script
set -Eeuo pipefail
shopt -s lastpipe

#Load the libraries
LIB_PATH="lib/general_scripts/bash/functions"

#Load the basic functions
# shellcheck source=/dev/null
source "${LIB_PATH}/modules.sh"
# shellcheck source=/dev/null
source "${LIB_PATH}/input_handling.sh"
# shellcheck source=/dev/null
source "${LIB_PATH}/output.sh"
# shellcheck source=/dev/null
source "${LIB_PATH}/logging.sh"
# shellcheck source=/dev/null
source "${LIB_PATH}/file_modification.sh"
# shellcheck source=/dev/null
source "${LIB_PATH}/jobs.sh"
# shellcheck source=/dev/null
source "${LIB_PATH}/utilities.sh"

#Load the job submissions
SUB_PATH="lib/general_scripts/bash/job_creation"

#Load the libraries with job submission
# shellcheck source=/dev/null
source "${SUB_PATH}/preparations.sh"
# shellcheck source=/dev/null
source "${SUB_PATH}/simulation.sh"
# shellcheck source=/dev/null
source "${SUB_PATH}/gauss.sh"
# shellcheck source=/dev/null
source "${SUB_PATH}/data.sh"
# shellcheck source=/dev/null
source "${SUB_PATH}/info.sh"

# on_error
# Inform the user about what happened upon an error occuring
# Globals: none
# Returns: The error code returned by the given line
on_error() {
	local rc=$1
	local lineno=$2
	printf "[FATAL] %s:%s: command failed (rc=%d)\n" "${BASH_SOURCE[0]}" "$lineno" "$rc" 1>&2
	exit "$rc" 
}
trap 'on_error $? $LINENO' ERR


# ----- Set Basic Variables -----
# Set the basic values for the script

declare -A Params

#Give global variables given in external functions default value here
name="" save_as="" input_type="" gpu="" meta="" directory="" amber_ext=""
tleap="" opt_water="" opt_all="" opt_temp="" opt_pres="" md="" cpptraj=""
md_iterations="" antechamber_cmd="" parmchk2_cmd="" mamba="" c_modules=""
num_frames="" cpptraj_mode="" sigma=""

LOG="log.txt"

LOG_POSITION=""
COUNTER=0

#How many atoms the simulated molecule holds
LIMIT=""

# ----- Output Functions -----
# Functions focusing on informing user about the program's state


# ----- Parameters -----
# Parse the parameters from the user
OVR_NAME=""
OVR_SAVE=""

#Shift through all the possible arguments
while getopts ":n:s:h" opt; do
	case "$opt" in
		n) OVR_NAME=$OPTARG ;;
		s) OVR_SAVE=$OPTARG ;;
		h) usage; exit 0 ;;
		:) die "Option -$OPTARG requires an argument" ;;
		\?) die "Unknown option: -$OPTARG" ;;
	esac
done
#Drop all the shifted through arguments
shift $((OPTIND-1))


# ----- Main -----
# ...

main() {
	# ----- Setup ------
	# Prepare variables for the main execution
	start_time=$( date +%s%N )

	# ----- Input -----
	# Read the user input file and extract its data
	read_config
	load_cfg "$OVR_NAME" "$OVR_SAVE"


	# ----- Input Check -----
	# Validate that all the input files given by the suer are explicitly present
	check_cfg

	get_number_of_atoms "$name"


	# ----- Module Check -----
	# Check that all the modules and their functions are present

	#The names of the modules based on the running enviroment
	amber_mod="amber${amber_ext}"
	if [[ $meta == "false" ]]; then
		gauss_mod="gaussian"
	else
		gauss_mod="g16"
	fi

	if [[ $c_modules == "true" ]]; then
		check_modules "$amber_mod" "$gauss_mod" "$meta"
		check_requires
	fi


	# ----- Load Log -----
	# Load the log of the previous run - start from the last succesfull operation
	read_log "$LOG"

	#Get the last run md simulation
	find_sim_num "$md_iterations" "$LOG_POSITION"

	#Clear the files not important for the log
	clean_process "$LOG_POSITION" "$COUNTER"


	# ----- Preparations -----
	# prepare the enviroment if the input has been set to the mol2
	if [[ $input_type == "mol2" ]]; then
		#Run crest
		if [[ 1 -gt $LOG_POSITION ]]; then
			run_crest "$name" "$directory" "$meta" "$mamba"
		fi

		#Run antechmaber
		if [[ 2 -gt $LOG_POSITION ]]; then
			run_antechamber "$name" "$directory" "$meta" "$amber_mod" "$antechamber_cmd"
		fi

		#Run parmchk2
		if [[ 3 -gt $LOG_POSITION ]]; then
			run_parmchk2 "$name" "$directory" "$meta" "$amber_mod" "$parmchk2_cmd"
		fi

		#Perform the nemesis fix
		if [[ 4 -gt $LOG_POSITION ]]; then
			run_nemesis_fix "$name"
		fi

		#Run tleap
		if [[ 5 -gt $LOG_POSITION ]]; then
			run_tleap "$name" "$directory" "$meta" "$amber_mod" "$tleap"
		fi
	fi


	# ----- Simulation Preparation -----
	# Prepare the enviroment for saving data from individual simulations
	ensure_dir "process/spectrum/frames"

	# Get the starting position for each md simulation frames counting
	if (( (num_frames % md_iterations) != 0 )); then
		die "$num_frames must be divisible by the number of md simulations: $md_iterations!"
	fi

	position_start=$(( num_frames / md_iterations ))

	# ----- Simulation -----
	# Run n times the full simulation pathway: Optimize - md - cpptraj
	# Now in PARALLEL, with a cap on max_parallel jobs

	if [[ 6 -gt $LOG_POSITION ]]; then

		pids=()
		max_parallel=10

		while (( COUNTER <= md_iterations )); do
			# Precompute per-run values so each subshell sees its own copy
			local_counter=$COUNTER
			local_pos_curr=$(( position_start * (local_counter - 1) ))

			(
				# ----- Single simulation run (in subshell) -----

				# Optimaze the water
				run_opt_water "$name" "$directory" "$meta" "$amber_mod" "$opt_water"

				# Optimaze the entire system
				run_opt_all "$name" "$directory" "$meta" "$amber_mod" "$opt_all"

				# Heat the system
				run_opt_temp "$name" "$directory" "$meta" "$amber_mod" "$opt_temp"

				# Set production pressure in the system
				run_opt_pres "$name" "$directory" "$meta" "$amber_mod" "$opt_pres"

				# Run the molcular dynamics
				run_md "$name" "$directory" "$meta" "$amber_mod" "$md"

				# Sample with cpptraj
				# use local_pos_curr instead of global pos_curr
				run_cpptraj "$name" "$directory" "$meta" "$amber_mod" "$local_pos_curr" "$LIMIT" "$cpptraj" "$cpptraj_mode" "$mamba"

				# Move the finished files; use local_counter for this run
				move_finished_job "$local_counter"

			) &
			pids+=("$!")

			# Limit the number of concurrent runs
			while (( ${#pids[@]} >= max_parallel )); do
				if ! wait -n; then
					# One of the subshells failed: kill the rest
					kill "${pids[@]}" 2>/dev/null || true
					# Optional: if your run_* functions submit cluster jobs, you can also qdel them here.
					die "One of the MD iteration runs failed!"
				fi

				# Clean up finished PIDs from the list
				tmp=()
				for pid in "${pids[@]}"; do
					if kill -0 "$pid" 2>/dev/null; then
						tmp+=("$pid")
					fi
				done
				pids=("${tmp[@]}")
			done

			# Increase the current counter for the NEXT run
			((COUNTER++))
		done

		COUNTER=0
		# Wait for all runs to finish; kill all others if just one fails
		for pid in "${pids[@]}"; do
			if ! wait "$pid"; then
				kill "${pids[@]}" 2>/dev/null || true
				die "One of the MD iteration runs failed during final wait!"
			fi
			success "Md run $COUNTER has finished!"
			(( COUNTER++ ))
		done

		#All the mds have finishged, include that in the log
		add_to_log "md" "$LOG"
	fi

	# ----- Spectrum -----
	# Having gotten the simulation frames perform NMR computation in Gaussian 
	# for each frame, combine and graph
	
	#Convert to .gjf for the gaussian program
	if [[ 7 -gt $LOG_POSITION ]]; then
		run_gauss_prep "$meta" "$num_frames" "$LIMIT"
	fi

	#Run gaussian on all the frames
	if [[ 8 -gt $LOG_POSITION ]]; then
		run_gaussian "$name" "$directory" "$meta" "$gauss_mod"
	fi

	#Analyse the resulting data
	if [[ 9 -gt $LOG_POSITION ]]; then
		run_analysis "$sigma" "$LIMIT"
	fi

	#Run gaussian on all the frames
	if [[ 10 -gt $LOG_POSITION ]]; then
		run_plotting "$name" "$save_as"
	fi

	# ----- Finish -----
	# Clean the enviroment and output run statistics	
	end_time=$( date +%s%N )

	echo

	info "Execution time was $(( (end_time - start_time)/(60000000000) )) minutes"

	# ----- Info -----
	# Inform the user that the job correctly finished
	#send_email "$mamba" "$save_as"
}

main "$@"