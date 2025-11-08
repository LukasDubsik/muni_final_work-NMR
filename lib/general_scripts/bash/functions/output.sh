# shellcheck disable=SC2148
# Guard so we don't load twice
[[ ${_OUTPUT_SH_LOADED:-0} -eq 1 ]] && return
_OUTPUT_SH_LOADED=1

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