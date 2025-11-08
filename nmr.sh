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

# shellcheck source=/dev/null
source "${LIB_PATH}/utilities.sh"
# shellcheck source=/dev/null
source "${LIB_PATH}/modules.sh"
# shellcheck source=/dev/null
source "${LIB_PATH}/input_handling.sh"
# shellcheck source=/dev/null
source "${LIB_PATH}/output.sh"

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

#Give global variables given in external functions default value here
name="" save_as="" input_type="" gpu="" meta="" directory="" amber_ext=""
tleap="" opt_water="" opt_all="" opt_temp="" opt_pres="" md="" cpptraj=""
md_iterations="" antechamber_cmd="" parmchk2_cmd=""

# ----- Output Functions -----
# Functions focusing on informing user about the program's state

# ----- Job Submission -----
# Functions for submitting a job

submit_job() {
	# Get the parameters into local variables
	local name=$1 job_dir=$2 script_avar=$3 mem_gb=$5 ncpus=$4 ngpus=$6 walltime=$7
	ensure_dir "$job_dir"
	local script="$job_dir/${name}.sh"

	# build script from array referenced by name
	local -n _LINES_REF="$script_avar"
	printf '#!/bin/bash\nset -Eeuo pipefail\n' >"$script"
	printf '%s\n' "${_LINES_REF[@]}" >>"$script"
	chmod +x "$script"

	local jobid out
	if command -v psubmit >/dev/null 2>&1; then
	out=$(psubmit -ys "${queue}" "$script" ncpus="${ncpus}" mem="${mem_gb}gb" walltime="${walltime}" || true)
	else
	# PBS select spec; add ngpus if present via env NGPU (optional)
	local select="select=1:ncpus=${ncpus}:mem=${mem_gb}gb"
	if [[ ${NGPU:-0} -gt 0 ]]; then select+="\:ngpus=${NGPU}"; fi
	out=$(qsub -q "${queue}" -l "${select}" -l "walltime=${walltime}" "$script" || true)
	fi

	# extract numeric job id
	jobid=$(printf '%s\n' "$out" | awk '/[0-9]+/{print $1}' | sed 's/[^0-9].*$//' | tail -n1)
	[[ -n "$jobid" ]] || die "Failed to submit job '${name}': $out"
	printf '%s\n' "$jobid"
}


# wait for job to finish (simple polling)
wait_job() {
	local jobid=$1
	require qstat || { info "qstat not found; skipping wait"; return 0; }
	while qstat "$jobid" >/dev/null 2>&1; do sleep 10; done
}


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
	load_cfg "$OVR_NAME" "$OVR_SAVE"


	# ----- Input Check -----
	# Validate that all the input files given by the suer are explicitly present
	check_cfg


	# ----- Module Check -----
	# Check that all the modules and their functions are present

	#The names of the modules based on the running enviroment
	amber_mod="amber${amber_ext}"
	gauss_mod=$(( meta == "true" ? "g16" : "gaussian" ))

	check_modules "$amber_mod" "$gauss_mod"


	# ----- Load Log -----
	# Load the log of the previous run - start from the last succesfull operation
	LOG="run.log"
	LOG_POSITION=0

	#if [[ -f $LOG ]]; then
	#	LOG_POSITION=$( read_log "$LOG" )
	#fi


	# ----- Modules/Functions -----
	# Make sure all the necessary modules and their functions are available
}

main "$@"