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
metal_charge=""


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
	# Validate that all the input files given by the user are explicitly present
	check_cfg
	get_number_of_atoms "$name"

	# ----- Module Check -----
	# Check that all the modules and their functions are present

	# The names of the modules based on the running environment
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

	# ----- Finalization guard -----
	FINAL_DIR="data_results/${save_as}"
	if [[ -f "${FINAL_DIR}/.ok" ]]; then
		info "Final results already exist for save_as=${save_as} (${FINAL_DIR}/.ok). Nothing to do."
		return 0
	fi

	# ----- Preparations -----
	# Prepare the environment if the input has been set to the mol2
	if [[ $input_type == "mol2" ]]; then
		run_crest "$name" "$directory" "$meta" "$mamba"
		run_antechamber "$name" "$directory" "$meta" "$amber_mod" "$antechamber_cmd" "$charge"
		run_parmchk2 "$name" "$directory" "$meta" "$amber_mod" "$parmchk2_cmd"

		# Always attempt MCPB; run_mcpb is self-resuming via stage marker files
		mcpb_in_mol2="process/preparations/parmchk2/${name}_charges_full.mol2"
		if [[ ! -f "$mcpb_in_mol2" ]]; then
			mcpb_in_mol2="process/preparations/parmchk2/${name}_charges.mol2"
		fi

		run_mcpb "$name" "$directory" "$meta" "$amber_mod" "$mcpb_cmd" \
			"$mcpb_in_mol2" \
			"process/preparations/parmchk2/${name}.frcmod" "$charge" \
			"$metal_charge"

		run_nemesis_fix "$name"
		run_tleap "$name" "$directory" "$meta" "$amber_mod" "$tleap" "$params"
	fi

	# ----- Simulation Preparation -----
	# Prepare the environment for saving data from individual simulations
	ensure_dir "process/spectrum/frames"

	# Get the starting position for each md simulation frames counting
	if (( (num_frames % md_iterations) != 0 )); then
		die "$num_frames must be divisible by the number of md simulations: $md_iterations!"
	fi
	increase=$((num_frames / md_iterations))

	# ----- Simulation -----
	# Run each step (internally self-resuming via output validation + .ok stamps)
	run_sim_step_parr "$name" "$directory" "$meta" "$amber_mod" "$opt_water" "$md_iterations" "opt_water"
	run_sim_step_parr "$name" "$directory" "$meta" "$amber_mod" "$opt_all"   "$md_iterations" "opt_all"
	run_sim_step_parr "$name" "$directory" "$meta" "$amber_mod" "$opt_temp"  "$md_iterations" "opt_temp"
	run_sim_step_parr "$name" "$directory" "$meta" "$amber_mod" "$opt_pres"  "$md_iterations" "opt_pres"
	run_sim_step_parr "$name" "$directory" "$meta" "$amber_mod" "$md"        "$md_iterations" "md"

	# Sample with cpptraj
	run_cpptraj_parr "$name" "$directory" "$meta" "$amber_mod" "$increase" "$LIMIT" "$cpptraj" "$cpptraj_mode" "$mamba" "$md_iterations"

	# ----- Spectrum -----
	run_gauss_prep "$meta" "$num_frames" "$LIMIT" "$charge"
	run_gaussian   "$name" "$directory" "$meta" "$gauss_mod"
	run_analysis   "$sigma" "$LIMIT"
	run_plotting   "$name" "$save_as" "$filter"

	# ----- Move -----
	info "Moving the final results"

	# delete the folder for save if already present (if you want to keep previous results, change save_as)
	rm -rf "${FINAL_DIR}/"
	mkdir -p "${FINAL_DIR}/"

	# Copy everything for posterity
	cp -r process/* "${FINAL_DIR}/"

	# Stamp finalization as OK (atomic .ok marker)
	mark_step_ok "${FINAL_DIR}"

	# Delete the process directory
	rm -rf process/*

	success "All files from the job saved in results under: $save_as"

	# ----- Finish -----
	end_time=$( date +%s%N )
	echo
	info "Execution time was $(( (end_time - start_time)/(60000000000) )) minutes"
}

main "$@"