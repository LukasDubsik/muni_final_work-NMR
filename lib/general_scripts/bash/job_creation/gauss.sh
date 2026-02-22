# shellcheck disable=SC2148
# Guard so we don't load twice
[[ ${_GAUSS_SH_LOADED:-0} -eq 1 ]] && return
_GAUSS_SH_LOADED=1

# gaussian_log_ok LOG_FILE
# Returns 0 if the given Gaussian log ended with normal termination
# and contains no explicit error termination marker.
# Globals: none
# Returns: 0 if OK, 1 otherwise
gaussian_log_ok() {
	local log_file=$1
	[[ -f "$log_file" ]] || return 1
	grep -q "Normal termination of Gaussian" "$log_file" || return 1
	! grep -q "Error termination" "$log_file"
}

# patch_gaussian_link0_resources GJF_FILE MEM_GB NCPUS
# Ensures the Gaussian input uses the same resources as the batch allocation.
patch_gaussian_link0_resources() {
	local gjf_file=$1 mem_gb=$2 ncpus=$3
	[[ -f "$gjf_file" ]] || die "Missing Gaussian input file: $gjf_file"

	local tmp
	tmp=$(mktemp) || die "mktemp failed"

	awk -v mem_gb="$mem_gb" -v ncpus="$ncpus" '
	BEGIN { inserted=0 }
	{
		l=tolower($0)

		# Drop any pre-existing resource directives to avoid duplicates.
		if (l ~ /^%mem=/) next
		if (l ~ /^%nprocshared=/) next
 
		# If we hit the route section before %chk, insert Link0 resources here.
		if (inserted==0 && $0 ~ /^#/) {
			print "%mem=" mem_gb "GB"
			print "%nprocshared=" ncpus
			inserted=1
		}

		print $0

		# Normal case: insert right after %chk=...
		if (inserted==0 && l ~ /^%chk=/) {
			print "%mem=" mem_gb "GB"
			print "%nprocshared=" ncpus
			inserted=1
		}
	}
	END {
		# Very defensive fallback; should not happen for valid .gjf inputs.
		if (inserted==0) {
			print "%mem=" mem_gb "GB"
			print "%nprocshared=" ncpus
		}
	}' "$gjf_file" >"$tmp" || { rm -f "$tmp"; die "Failed to patch Gaussian resources in: $gjf_file"; }

	mv "$tmp" "$gjf_file" || die "Failed to replace patched file: $gjf_file"
}

# run_gauss_convert META NUM_FRAMES
# Convert the xyz files from the amber simulation into log files for gaussian
# Globals: none
# Returns: Nothing
run_gauss_prep() {
	#Load the inputs
	local meta=$1
	local num_frames=$2
	local limit=$3
	local charge=$4

	local job_name="gauss_prep"

	info "Started running $job_name"

    #Start by converting the input mol into a xyz format -necessary for crest
	JOB_DIR="process/spectrum/$job_name"
	ensure_dir $JOB_DIR
	ensure_dir $JOB_DIR/frames

	local ok="$JOB_DIR/.ok"
	last_frame=$((num_frames - 1))
	if [[ -f "$ok" ]]; then
		if [[ -s "$JOB_DIR/gauss/frame_${last_frame}.gjf" ]]; then
			info "$job_name already complete; skipping"
			return 0
		else
			rm -f "$ok"
		fi
	fi

	#Move the frames into the gaussian prep run
	cp -r process/spectrum/frames/* $JOB_DIR/frames/

	SRC_DIR_1="lib/general_scripts/bash/general"

	substitute_name_sh_data "general/xyz_to_gfj.sh" "$JOB_DIR/xyz_to_gfj.sh" "" "$limit" "" "$charge"

	#Ensure the final dir exists
    ensure_dir $JOB_DIR/gauss

	#Run the bash script
	cd "$JOB_DIR" || die "Couldn't enter the cpptraj directory"
	bash xyz_to_gfj.sh
	cd ../../../ || die "Couldn't return back from the cpptraj dir"

	last_frame=$((num_frames - 1))

	#Check that the final files are truly present
	check_res_file "frame_$last_frame.gjf" "$JOB_DIR/gauss" "$job_name"

	mark_step_ok "$JOB_DIR"

	success "$job_name has finished correctly"

}

# run_gaussian NAME DIRECTORY META GAUSSIAN
# For each gjf file run gaussian and acquire the log file of the results
# Globals: none
# Returns: Nothing
run_gaussian() {
	#Load the inputs
	local name=$1
	local directory=$2
	local meta=$3
	local gaussian=$4

	local job_name="gaussian"

	local mem_gb=16
	local ncpus=16

	info "Started running $job_name"

	# Gaussian writes large scratch (RWF etc.). On MetaCentrum we must reserve scratch explicitly,
	# otherwise $SCRATCHDIR is too small and the job fails with "Disk quota exceeded".
	local old_extra="${JOB_META_SELECT_EXTRA:-}"
	if [[ $meta == "true" ]]; then
		# g16 is licensed only on specific nodes => host_licenses=g16
		# Pick a scratch size that matches your workload (start with 50gb for GIAO NMR).
		JOB_META_SELECT_EXTRA="host_licenses=g16:scratch_local=50gb"
	fi


    #Start by converting the input mol into a xyz format -necessary for crest
	JOB_DIR="process/spectrum/$job_name"
	ensure_dir $JOB_DIR

	local ok="$JOB_DIR/.ok"

	#Directory where to store inputs
	INP_DIR_1="process/spectrum/$job_name/gauss"
	ensure_dir $INP_DIR_1

	#Directory where to store outputs
	OUT_DIR_1="process/spectrum/$job_name/nmr"
	ensure_dir $OUT_DIR_1

	local done_log="$JOB_DIR/finished_jobs.log"

	# Fast-path: if already marked OK, trust it but verify the last frame log exists and is valid
	if [[ -f "$ok" ]]; then
		last_frame=$((num_frames - 1))
		if gaussian_log_ok "$OUT_DIR_1/frame_${last_frame}.log"; then
			info "$job_name already complete; skipping"
			return 0
		else
			rm -f "$ok"
		fi
	fi

	#Copy the input files
	SRC_DIR_1="process/spectrum/gauss_prep/gauss"

	cp -r $SRC_DIR_1/* $INP_DIR_1

	# Resume support: keep a local completion log and discover already-finished frames
	declare -A don=()

	# Load existing completion log, but trust only entries with an actually valid copied output
	if [[ -f "$done_log" ]]; then
		while IFS= read -r idx; do
			[[ -n "$idx" ]] || continue
			out_file="$OUT_DIR_1/frame_${idx}.log"
			if gaussian_log_ok "$out_file"; then
				don["$idx"]=1
			fi
		done < "$done_log"
	fi

	# 1) Logs already copied into OUT_DIR_1 (e.g., previous run copied some results)
	for f in "$OUT_DIR_1"/frame_*.log; do
		[[ -f "$f" ]] || continue
		base=$( basename "$f" )
		idx=${base#frame_}
		idx=${idx%.log}
		if gaussian_log_ok "$f"; then
			if [[ -z "${don[$idx]:-}" ]]; then
				echo "$idx" >> "$done_log"
				don["$idx"]=1
			fi
		else
			rm -f "$f"
		fi
	done

	# 2) Logs still living in per-job directories (also handles jobs that are still running)
	for ((num=0; num < num_frames; num++))
	do
		if [[ -n "${don[$num]:-}" ]]; then
			continue
		fi

		LOC_DIR="$JOB_DIR/job_${num}/"
		[[ -d "$LOC_DIR" ]] || continue

		# If a jobid marker exists and the job is still queued/running, skip for now
		# (do not block the whole pipeline on the first running frame)
		if [[ -f "$LOC_DIR/.jobid" ]]; then
			jid=$( head -n 1 "$LOC_DIR/.jobid" || true )
			if [[ -n "$jid" ]] && qstat "$jid" >/dev/null 2>&1; then
				continue
			fi
		fi

		log_file="$LOC_DIR/frame_${num}.log"
		if gaussian_log_ok "$log_file"; then
			cp "$log_file" "$OUT_DIR_1/"
			if [[ -z "${don[$num]:-}" ]]; then
				echo "$num" >> "$done_log"
				don["$num"]=1
			fi
			rm -rf "$LOC_DIR"
		fi
	done

	# 3) Purge stale/broken gaussian job directories (anything not finished)
	for ((num=0; num < num_frames; num++))
	do
		LOC_DIR="$JOB_DIR/job_${num}/"
		[[ -d "$LOC_DIR" ]] || continue

		if [[ -n "${don[$num]:-}" ]]; then
			rm -rf "$LOC_DIR"
			continue
		fi

		# If job still running, keep directory (do not resubmit or delete)
		if [[ -f "$LOC_DIR/.jobid" ]]; then
			jid=$( head -n 1 "$LOC_DIR/.jobid" || true )
			if [[ -n "$jid" ]] && qstat "$jid" >/dev/null 2>&1; then
				continue
			fi
		fi

		rm -rf "$LOC_DIR"
	done

	# If everything is already finished, we can finalize without submitting anything new
	if (( ${#don[@]} == num_frames )); then
		info "All gaussian frames already finished (${#don[@]}/${num_frames}); skipping submission"

		last_frame=$((num_frames - 1))
		check_res_file "frame_$last_frame.log" "$JOB_DIR/nmr" "$job_name"

		# Restore for other pipeline stages
		if [[ $meta == "true" ]]; then
			JOB_META_SELECT_EXTRA="$old_extra"
		fi

		success "$job_name has finished correctly"
		return
	fi

	#Run the jobs in parallel each in different directory and subshell
	pids=()
	max_parallel=10
	#Enter the directory and run the .sh script
	for ((num=0; num < num_frames; num++))
	do
		if [[ -n "${don[$num]:-}" ]]; then
			continue
		fi

		LOC_DIR="$JOB_DIR/job_${num}/"

		# If job already submitted and still queued/running, do not submit it again
		if [[ -f "$LOC_DIR/.jobid" ]]; then
			jid=$( head -n 1 "$LOC_DIR/.jobid" || true )
			if [[ -n "$jid" ]] && qstat "$jid" >/dev/null 2>&1; then
				continue
			fi
		fi

		#create a new dir for the file
		mkdir -p "$LOC_DIR"
		#Constrcut the job file
		if [[ $meta == "true" ]]; then
			substitute_name_sh_meta_start "$LOC_DIR" "${directory}" ""
			substitute_name_sh_meta_end "$LOC_DIR"
			substitute_name_sh "$job_name" "$LOC_DIR" "$gaussian" "$name" "" "$num" "" ""
			construct_sh_meta "$LOC_DIR" "$job_name"
		else
			substitute_name_sh_wolf_start "$LOC_DIR"
			substitute_name_sh "$job_name" "$LOC_DIR" "$gaussian" "$name" "" "" "" ""
			construct_sh_wolf "$LOC_DIR" "$job_name"
		fi
		#Copy the specific frame to the local dir
		cp $JOB_DIR/gauss/frame_$num.gjf $LOC_DIR
		# Patch the resources
		patch_gaussian_link0_resources "$LOC_DIR/frame_${num}.gjf" "$mem_gb" "$ncpus"
		#Then submit the job for run
		( submit_job "$meta" "$job_name" "$LOC_DIR" "$mem_gb" "$ncpus" 0 "02:00:00" ) &
		p=$!
		pids+=("$p")

		while (( ${#pids[@]} >= max_parallel )); do
			if ! wait -n; then
				kill "${pids[@]}" 2>/dev/null
				search=$(qselect -u lukasdubsik)
				qdel "$search"
				die "One of the submit_job calls failed!"
			fi
			tmp=()
			for pid in "${pids[@]}"; do
				if kill -0 "$pid" 2>/dev/null; then
					tmp+=("$pid")
				fi
			done
			pids=("${tmp[@]}")
		done
	done
	#Wait for all jobs to finish; kill all others if just one fails
	for pid in "${pids[@]}"; do
		if ! wait "$pid"; then
			# this pid failed
			kill "${pids[@]}" 2>/dev/null
			search=$(qselect -u lukasdubsik)
			qdel "$search"
			die "The job $pid has failed!"
		fi
	done


	#Copy all the files from the finished jobs dirs and update the local completion log
	for ((num=0; num < num_frames; num++))
	do
		#Already marked as done during resync
		if [[ -n "${don[$num]:-}" ]]; then
			continue
		fi

		# If job is still queued/running, wait it out now (harvest phase)
		LOC_DIR="$JOB_DIR/job_${num}/"
		if [[ -f "$LOC_DIR/.jobid" ]]; then
			jid=$( head -n 1 "$LOC_DIR/.jobid" || true )
			if [[ -n "$jid" ]] && qstat "$jid" >/dev/null 2>&1; then
				info "Waiting for gaussian frame $num (job $jid)"
				wait_job "$jid"
			fi
		fi

		log_file="$JOB_DIR/job_${num}/frame_$num.log"
		if ! gaussian_log_ok "$log_file"; then
			die "Gaussian frame $num did not finish normally (missing or error log): $log_file"
		fi

		cp "$log_file" "$JOB_DIR/nmr"
		echo "$num" >> "$done_log"
		don["$num"]=1

		rm -rf "$JOB_DIR/job_${num}"
	done


	last_frame=$((num_frames - 1))

	#Check that the final files are truly present
	check_res_file "frame_$last_frame.log" "$JOB_DIR/nmr" "$job_name"

	# Restore for other pipeline stages
	if [[ $meta == "true" ]]; then
		JOB_META_SELECT_EXTRA="$old_extra"
	fi

	success "$job_name has finished correctly"

}