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
source "${SUB_PATH}/preparation.sh"

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

LOG="log.txt"

LOG_POSITION=""

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
	# ----- Input -----
	# Read the user input file and extract its data
	read_config
	load_cfg "$OVR_NAME" "$OVR_SAVE"


	# ----- Input Check -----
	# Validate that all the input files given by the suer are explicitly present
	check_cfg


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

	#Clear the files not important for the log
	clean_process "$LOG_POSITION"


	# ----- Preparations -----
	# prepare the enviroment if the input has been set to the mol2
	if [[ $input_type == "mol2" ]]; then
		#Run crest
		if [[ 1 -gt $LOG_POSITION ]]; then
			run_crest "$name" "$directory" "$meta" "$mamba"
		fi

		#Run antechmaber
		if [[ 2 -gt $LOG_POSITION ]]; then
			run_antechamber "$name" "$directory" "$meta" "$amber_mod"
		fi

		#Run parmchk2
		if [[ 3 -gt $LOG_POSITION ]]; then
			run_parmchk2 "$name" "$directory" "$meta" "$amber_mod"
		fi

		#Perform the nemesis fix
		if [[ 4 -gt $LOG_POSITION ]]; then
			run_nemesis_fix "$name"
		fi

		#Run tleap
		if [[ 5 -gt $LOG_POSITION ]]; then
			run_tleap "$name" "$directory" "$meta" "$amber_mod"
		fi
	fi
}

main "$@"