#!/bin/bash
# Project: Pipeline for NMR simulations
# Author: Lukas Dubsik
# Date: 07.11.2025
# Description: A simple script that runs Amber simulations and Gaussian to get NMR spectrum of given molecule


# ----- Argument parsing -----
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

