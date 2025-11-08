# shellcheck disable=SC2148
# Guard so we don't load twice
[[ ${_JOBS_SH_LOADED:-0} -eq 1 ]] && return
_JOBS_SH_LOADED=1

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