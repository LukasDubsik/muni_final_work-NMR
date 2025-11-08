# shellcheck disable=SC2148
# Guard so we don't load twice
[[ ${_PREPARATION_SH_LOADED:-0} -eq 1 ]] && return
_PREPARATION_LOADED=1

INPUTS="inputs"

# run_crest NAME DIRECTORY META
# Runs everything pertaining crest
# Globals: none
# Returns: Nothing
run_crest() {
	#Load the inputs
	local name=$1
	local directory=$2
	local meta=$3

	#Start with finding the most stable conformation
    module add openbabel > /dev/null 2>&1

    #Start by converting the input mol into a xyz format -necessary for crest
	JOB_DIR="process/preparations/crest"
	ensure_dir $JOB_DIR

	#Constrcut the job file
	if [[ $meta == "true" ]]; then
		substitute_name_sh_meta_start "$JOB_DIR" "${name}.xyz" "${directory}" "crest"
	fi

    obabel -imol2 "${INPUTS}/structures/${name}.mol2" -oxyz -O "${JOB_DIR}/${name}.xyz" > /dev/null 2>&1
    #Run the crest simulation
    submit_job "$meta" "crest" "$JOB_DIR" 4 16 0 "01:00:00"
    wait_job $?
    #Convert back to mol2 format
    obabel -ixyz "${JOB_DIR}/crest_best.xyz" -omol2 -O "${JOB_DIR}/${name}_crest.mol2" > /dev/null 2>&1
    
	success "crest has finished correctly"
}