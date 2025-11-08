# shellcheck disable=SC2148
# Guard so we don't load twice
[[ ${_JOBS_SH_LOADED:-0} -eq 1 ]] && return
_JOBS_SH_LOADED=1

# submit_job META NAME JOB_DIR MEM_GB NCPUS NGPUS WALLTIME
# Submits the given .sh file for executing on the cluster
# Globals: none
# Returns: Nothing
submit_job() {
	#Get the parameters into local variables
	local meta=$1 name=$2 job_dir=$3 mem_gb=$4 ncpus=$5 ngpus=$6 walltime=$7
	ensure_dir "$job_dir"
	local script="$job_dir/${name}.sh"

	#Submit the job based on meta/wolf
	local jobid out
	if [[ $meta == "false" ]]; then
		out=$(psubmit -ys default "$script" mem="${mem_gb}gb" ncpus="${ncpus}" ngpus="${ngpus}" walltime="${walltime}" || true)
	else
		# PBS select spec; add ngpus if present via env NGPU (optional)
		local select="select=1:ncpus=${ncpus}:ngpus=${ngpus}:mem=${mem_gb}gb"
		out=$(qsub -q default -l "${select}" -l "walltime=${walltime}" "$script" || true)
	fi

	#Extract numeric job id
	IFS='.' read -r -a jobid_arr <<< "$out"
    IFS=' ' read -r -a jobid_arr2 <<< "${jobid_arr[0]}"
	jobid=${jobid_arr2[-1]}

	#Check that the job was succesfully submitted and exit
	[[ -n "$jobid" ]] || die "Failed to submit job '${name}': $out"

	wait_job "$jobid"
}

# wait_job JOBID
# Waits for the job to finish executing
# Globals: none
# Returns: Nothing
wait_job() {
	local jobid=$1
	while qstat "$jobid" >/dev/null 2>&1; do 
		sleep 10
	done
}