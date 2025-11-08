# shellcheck disable=SC2148
# Guard so we don't load twice
[[ ${_PREPARATION_SH_LOADED:-0} -eq 1 ]] && return
_PREPARATION_LOADED=1

# submit_job META NAME JOB_DIR MEM_GB NCPUS NGPUS WALLTIME
# Submits the given .sh file for executing on the cluster
# Globals: none
# Returns: The id of the submitted job
run_crest