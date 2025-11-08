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

#Check if we can set colored output
NC=""; GREEN=""; ORANGE=""; RED=""
if [[ -t 1 ]]; then
	NC="\033[0m"
	GREEN="\033[0;32m\xE2\x9C\x94"
	ORANGE="\033[38;5;208m\xE2\x9C\x94"
	RED="\033[0;31m\xE2\x9C\x98"
fi

log() { printf "[%s] %s\n" "$1" "$2"; }
info() { log INFO "$1"; }

# success
# Print that given program section executed correctly
# Globals: none
# Returns: Nothing
succes() { printf "[%bOK%b] %s\n" "${GREEN}" "${NC}" "$1"; }
# warning
# Print a warning to the user
# Globals: none
# Returns: Nothing
warning() { printf "[%bWARN%b] %s\n" "${ORANGE}" "${NC}" "$1"; }
# success
# Exits the program upon a fatal error
# Globals: none
# Returns: Nothing
exit_program() { printf "[%bERR%b] %s\n" "${RED}" "${NC}" "$1" 1>&2; exit 1; }

# usage
# Exits the program upon a fatal error
# Globals: none
# Returns: Nothing
usage() {
cat <<EOF
Usage: ${PROG_NAME} [-n NAME] [-s SAVE_AS] [-h]

Options:
-n NAME Override sample name from config
-s SAVE_AS Override save_as from config
-h Show this help and exit

This scripts is a pipeline for getting NMr spectra data by using crest/amber/gaussian.
EOF
}


# ----- Utilities -----
# Functions to check if files present, validy process occured or prepare script enviroment

# usage MODULE_NAME
# Tries to add the module.
# Globals: none
# Returns: Exits the program if module can't be added, otherwise nothing
check_module() { module add "$1" > /dev/null 2>&1 || die "Couldn't add the module: $1"; }
check_module_conda() {
	conda activate "$1" > /dev/null 2>&1 || die "Couldn't activate conda enviroment";
	module add "$1" > /dev/null 2>&1 || die "Couldn't add the module: $1"; 
	conda deactivate > /dev/null 2>&1 || die "Couldn't exit conda enviroment";
}
check_modules() {
	#Load the parametrs
	local amber_mod=$1
	local gauss_mod=$2

	#That crest is available
	if [[ $meta == "true" ]]; then
		#On metacentrum crest needs conda additionaly to be run
		check_module_conda "crest"
	else
		check_module "crest"
	fi

	#That Amber is available
	check_module "$amber_mod"

	#That gaussian is available
	check_module "$gauss_mod"

	succes "All the modules (crest, amber, gaussian) are present"
}
# require FUNCTION_NAME
# Tries to find the path to the function.
# Globals: none
# Returns: Exits if the function can't be run, otherwise nothing.
require() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

# ensure_dir DIR_NAME
# Makes sure the dir exists by creating it
# Globals: none
# Returns: Nothing
ensure_dir() { mkdir -p -- "$1"; }


# ----- Input File -----
# Functions for extracting data from the sim.txt file and analyzing their correctness
declare -A Params

read_config() {
	#Hardwired location of the input file
	local file="inputs/sim.txt"
	[[ -f "$file" ]] || die "Config file not found: $file"

	#Iterate the file to get all its values
	while IFS= read -r line || [[ -n "$line" ]]; do
		#Skip empty lines and lines starting with # (comments)
		[[ -z "$line" || ${line:0:1} == '#' ]] && continue
		#Extract all lines containing assign
		if [[ "$line" == *":="* ]]; then
			local key=${line%%:=*}
			local val=${line#*:=}
			#Strip all whitespaces from the key
			key=${key//[[:space:]]/}
			Params["$key"]=$val
		fi
	done <"$file"
}

get_cfg() {
	local key=$1
	if [[ -n "${Params[$key]}" ]]; then 
		die "Expected: ${Params[$key]}. But it was not present!"; 
	else 
		return 1; 
	fi
}

check_in_file() {
	# Check that given in file truly present
	local name=$1 dir=$2
	local file="$dir/${name}.in"
	[[ -f "$file" ]] || die "Missing input template: $file"
	succ ".in present: $file"
}

check_sh_file() {
	# Check that given sh script truly present
	local name=$1 dir=$2
	local file="$dir/${name}.sh"
	[[ -f "$file" ]] || die "Missing script: $file"
	succ ".sh present: $file"
}

load_cfg() {
	#Declare the values as explicitly global
	declare -g \
    name save_as input_type gpu meta directory amber_ext \
    tleap opt_water opt_all opt_temp opt_pres md cpptraj \
    md_iterations antechamber_cmd parmchk2_cmd

	#See if we have the name for the molecule
	name=${OVR_NAME:-$(get_cfg 'name')}

	#See if we have the save for the molecule
	save_as=${OVR_SAVE:-$(get_cfg 'save_as')}

	#Get the input type and check it is valid type
	input_type=$(get_cfg 'input_type')
	#Check that it is allowed
	if [[ ! $input_type == 'mol2' && ! $input_type == '7' ]]; then
		exit_program "Only allowed input file types are mol2 and rst/parm7!"
	fi

	#See if we have gpu specified
	gpu=$(get_cfg 'gpu')

	#If we want to run the code in metacentrum
	meta=$(get_cfg 'meta')

	#Number of iterations of the md
	md_iterations=$(get_cfg 'md_iterations')

	info "Config loaded: name=$name, save_as=$save_as, input_type=$input_type, gpu=$gpu, meta=$meta, md iterations=$md_iterations"

	#By default amber extension is empty
	amber_ext=""

	#If so also see that other important values given
	if [[ $meta == 'true' ]]; then
		#What is our directoryt in which we are running the script
		directory=$(get_cfg 'directory')

		#What version of amber are we using
		amber_ext=$(get_cfg 'amber')

		info "All the informations for metacentrum loaded correctly: directory=$directory, amber=$amber_ext"
	fi

	#Additional parametrs for specfic programs - only for mol2
	if [[ $input_type == "mol2" ]]; then
		antechamber_cmd=$(get_cfg 'antechamber')
		parmchk2_cmd=$(get_cfg 'parmchk2')

		info "All the additional parametrs for mol2 loaded correctly"
	fi

	#Load the names of the .in files (all need to be under inputs/simulation/)
	tleap=$(get_cfg 'tleap')
	opt_water=$(get_cfg 'opt_water')
	opt_all=$(get_cfg 'opt_all')
	opt_temp=$(get_cfg 'opt_temp')
	opt_pres=$(get_cfg 'opt_pres')
	md=$(get_cfg 'md')
	cpptraj=$(get_cfg 'cpptraj')
}

check_cfg() {
	#Directory, where the .in fils must be stored
	PATH_TO_INPUTS="inputs/simulation"

	#Go file by file and check if they are present
	check_in_file "$tleap" "$PATH_TO_INPUTS"
	check_in_file "$opt_water" "$PATH_TO_INPUTS"
	check_in_file "$opt_all" "$PATH_TO_INPUTS"
	check_in_file "$opt_temp" "$PATH_TO_INPUTS"
	check_in_file "$opt_pres" "$PATH_TO_INPUTS"
	check_in_file "$md" "$PATH_TO_INPUTS"
	check_in_file "$cpptraj" "$PATH_TO_INPUTS"

	succes "All .in files are present and loaded."
}


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
	load_cfg


	# ----- Input Check -----
	# Validate that all the input files given by the suer are explicitly present
	check_cfg


	# ----- Module Check -----
	# Check that all the modules and their functions are present

	#The names of the modules based on the running enviroment
	amber_mod="amber${amber_ext}"
	gauss_mod=$(( meta == "true" ? "g16" : "gaussian" ))

	check_modules "$amber_mod" "$gauss_mod"


	# ----- Modules/Functions -----
	# Make sure all the necessary modules and their functions are available
}