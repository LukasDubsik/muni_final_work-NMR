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
	rc=$1
	lineno=$2
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
check_module() { module add "$1" > /dev/null 2>&1 || die "Couldn't add th module: $1"; }
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


# ----- Job Submission -----
# Functions for submitting a job


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