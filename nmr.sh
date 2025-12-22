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
source "${SUB_PATH}/simulation_parallel.sh"
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

# shellcheck disable=SC2034
declare -A Params

#Give global variables given in external functions default value here
name="" save_as="" input_type="" gpu="" meta="" directory="" amber_ext=""
tleap="" opt_water="" opt_all="" opt_temp="" opt_pres="" md="" cpptraj=""
md_iterations="" antechamber_cmd="" parmchk2_cmd="" mamba="" c_modules=""
num_frames="" cpptraj_mode="" sigma="" charge="" filter="" params="" mcpb_cmd=""

LOG="log.txt"

LOG_POSITION=""

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
	#find_sim_num "$md_iterations" "$LOG_POSITION"

	#Clear the files not important for the log
	clean_process "$LOG_POSITION" "$md_iterations"


	# ----- Preparations -----
	# prepare the enviroment if the input has been set to the mol2
	if [[ $input_type == "mol2" ]]; then
		#Run crest
		if [[ 1 -gt $LOG_POSITION ]]; then
			run_crest "$name" "$directory" "$meta" "$mamba"
		fi

		#Run antechmaber
		if [[ 2 -gt $LOG_POSITION ]]; then
			run_antechamber "$name" "$directory" "$meta" "$amber_mod" "$antechamber_cmd" "$charge"
		fi

		#Run parmchk2
		if [[ 3 -gt $LOG_POSITION ]]; then
			run_parmchk2 "$name" "$directory" "$meta" "$amber_mod" "$antechamber_cmd" "$charge"
		fi

		# Always attempt MCPB; run_mcpb is now self-resuming via stage marker files
		run_mcpb "$name" "$directory" "$meta" "$amber_mod" "$mcpb_cmd" \
			"process/preparations/parmchk2/${name}_charges.mol2" \
			"process/preparations/parmchk2/${name}.frcmod"


		#Perform the nemesis fix
		if [[ 4 -gt $LOG_POSITION ]]; then
			run_nemesis_fix "$name"
		fi

		#Run tleap
		if [[ 5 -gt $LOG_POSITION ]]; then
			run_tleap "$name" "$directory" "$meta" "$amber_mod" "$tleap" "$params"
		fi
	fi


	# ----- Simulation Preparation -----
	# Prepare the enviroment for saving data from individual simulations
	ensure_dir "process/spectrum/frames"

	#Get the starting position for each md simulation frames counting
	if (( (num_frames % md_iterations) != 0 )); then
		die "$num_frames must be divisible by the number of md simulations: $md_iterations!"
	fi

	increase=$((num_frames / md_iterations))


	# ----- Simulation -----
	# Run in parallel each step

	#Optimaze the water
	if [[ 6 -gt $LOG_POSITION ]]; then
		run_sim_step_parr "$name" "$directory" "$meta" "$amber_mod" "$opt_water" "$md_iterations" "opt_water"
	fi

	#Optimaze the entire system
	if [[ 7 -gt $LOG_POSITION ]]; then
		run_sim_step_parr "$name" "$directory" "$meta" "$amber_mod" "$opt_all" "$md_iterations" "opt_all"
	fi

	#Heat the system
	if [[ 8 -gt $LOG_POSITION ]]; then
		run_sim_step_parr "$name" "$directory" "$meta" "$amber_mod" "$opt_temp" "$md_iterations" "opt_temp"
	fi

	#Set production pressure in the system
	if [[ 9 -gt $LOG_POSITION ]]; then
		run_sim_step_parr "$name" "$directory" "$meta" "$amber_mod" "$opt_pres" "$md_iterations" "opt_pres"
	fi

	#Run the molcular dynamics
	if [[ 10 -gt $LOG_POSITION ]]; then
		run_sim_step_parr "$name" "$directory" "$meta" "$amber_mod" "$md" "$md_iterations" "md"
	fi

	#Sample with cpptraj
	if [[ 11 -gt $LOG_POSITION ]]; then
		run_cpptraj_parr "$name" "$directory" "$meta" "$amber_mod" "$increase" "$LIMIT" "$cpptraj" "$cpptraj_mode" "$mamba" "$md_iterations"
	fi

	# ----- Spectrum -----
	# Having gotten the simulation frames perform NMR computation in Gaussian 
	# for each frame, combine and graph
	
	#Convert to .gjf for the gaussian program
	if [[ 12 -gt $LOG_POSITION ]]; then
		run_gauss_prep "$meta" "$num_frames" "$LIMIT" "$charge"
	fi

	#Run gaussian on all the frames
	if [[ 13 -gt $LOG_POSITION ]]; then
		run_gaussian "$name" "$directory" "$meta" "$gauss_mod"
	fi

	#Analyse the resulting data
	if [[ 14 -gt $LOG_POSITION ]]; then
		run_analysis "$sigma" "$LIMIT"
	fi

	#Run gaussian on all the frames
	if [[ 15 -gt $LOG_POSITION ]]; then
		run_plotting "$name" "$save_as" "$filter"
	fi

	# ----- Move -----
	# Move the results
	if [[ 16 -gt $LOG_POSITION ]]; then
		info "Moving the final results"
		#delete the file for save if already present
		rm -rf data_results/"$save_as"/
		mkdir -p data_results/"$save_as"/
		#Copy everything for posterity
		cp -r process/* data_results/"$save_as"/
		#Delete the process directory
		rm -rf process/*
		#Add to the log
		add_to_log "moving" "$LOG"
	fi

	success "All files from the job saved in results under: $save_as"

	# ----- Finish -----
	# Clean the enviroment and output run statistics	
	end_time=$( date +%s%N )

	echo

	info "Execution time was $(( (end_time - start_time)/(60000000000) )) minutes"

	rm -f log.txt

	# ----- Info -----
	# Inform the user that the job correctly finished
	#send_email "$mamba" "$save_as"
}

main "$@"