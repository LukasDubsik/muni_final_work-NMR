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
	local script="${name}.sh"

	curr_dir=$( pwd )
	cd "$job_dir" || exit 1

	#Submit the job based on meta/wolf
	local jobid out
	if [[ $meta == "false" ]]; then
		out=$(psubmit -ys default "$script" mem="${mem_gb}gb" ncpus="${ncpus}" ngpus="${ngpus}" walltime="${walltime}" || true)
	else
		# PBS select spec; add ngpus if present via env NGPU (optional)
		local select="select=1:ncpus=${ncpus}:ngpus=${ngpus}:mem=${mem_gb}gb"
		# Optional extra chunk resources for MetaCentrum (e.g., host_licenses, scratch_local)
		# Example: JOB_META_SELECT_EXTRA="host_licenses=g16:scratch_local=50gb"
		local extra="${JOB_META_SELECT_EXTRA:-}"
		if [[ -n "$extra" ]]; then
			extra="${extra#:}"
			select="${select}:${extra}"
		fi
		out=$(qsub -q default -l "${select}" -l "walltime=${walltime}" "$script" || true)
	fi

	#Extract job id
	if [[ $meta == "true" ]]; then
		# Keep server suffix; MetaCentrum may require it for qstat/qdel
		jobid=${out%%[[:space:]]*}
	else
		# Legacy psubmit output: keep numeric id
		IFS='.' read -r -a jobid_arr <<< "$out"
		IFS=' ' read -r -a jobid_arr2 <<< "${jobid_arr[0]}"
		jobid=${jobid_arr2[-1]}
	fi

	#Check that the job was succesfully submitted and exit
	[[ -n "$jobid" ]] || die "Failed to submit job '${name}': $out"

	#Persist the jobid in the job directory so interrupted pipelines can resume
	echo "$jobid" > .jobid

	wait_job "$jobid"

	cd "$curr_dir" || exit 1
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