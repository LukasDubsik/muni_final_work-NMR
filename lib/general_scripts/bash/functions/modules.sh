# shellcheck disable=SC2148
# Guard so we don't load twice
[[ ${_MODULES_SH_LOADED:-0} -eq 1 ]] && return
_MODULES_SH_LOADED=1

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

	#That pmemd.cuda is available - only for Wolf side of things
	if [[ $meta == "false" ]]; then
		check_module "pmemd-cuda"
	fi

	#That Obabel is available (file conversion)
	check_module "obabel"

	#That Amber is available
	check_module "$amber_mod"

	#That gaussian is available
	check_module "$gauss_mod"

	succes "All the modules (crest, amber, gaussian) are present"
}

# check_require FUNCTION_NAME
# Tries to find the path to the function.
# Globals: none
# Returns: Exits if the function can't be run, otherwise nothing.
check_require() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

check_requires() {
	#That antechamber is running
	check_require "antechamber"

	#And so on
	check_require "parmchk2"
	check_require "pmemd"
	check_require "pmemd.cuda"
	check_require "cpptraj"
	check_require "gaussian"

	succes "All functions within the modules are present"
}