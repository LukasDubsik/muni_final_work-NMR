# shellcheck disable=SC2148
# Guard so we don't load twice
[[ ${_GAUSS_SH_LOADED:-0} -eq 1 ]] && return
_GAUSS_SH_LOADED=1

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

	success "$job_name has finished correctly"

	#Write to the log a finished operation
	add_to_log "$job_name" "$LOG"
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

	#Directory where to store inputs
	INP_DIR_1="process/spectrum/$job_name/gauss"
	ensure_dir $INP_DIR_1

	#Directory where to store outputs
	OUT_DIR_1="process/spectrum/$job_name/nmr"
	ensure_dir $OUT_DIR_1

	#Copy the input files
	SRC_DIR_1="process/spectrum/gauss_prep/gauss"

	cp -r $SRC_DIR_1/* $INP_DIR_1

	#Run the jobs in parallel each in different directory and subshell
	pids=()
	max_parallel=10
	#Enter the directory and run the .sh script
	for ((num=0; num < num_frames; num++))
	do
		LOC_DIR="$JOB_DIR/job_${num}/"
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
		#Then submit the job for run
		( submit_job "$meta" "$job_name" "$LOC_DIR" 16 16 0 "08:00:00" ) &
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


	#Copy all the files from the finished jobs dirs
	for ((num=0; num < num_frames; num++))
	do
		cp $JOB_DIR/job_${num}/frame_$num.log $JOB_DIR/nmr
		rm -rf $JOB_DIR/job_${num}
	done

	last_frame=$((num_frames - 1))

	#Check that the final files are truly present
	check_res_file "frame_$last_frame.log" "$JOB_DIR/nmr" "$job_name"

	# Restore for other pipeline stages
	if [[ $meta == "true" ]]; then
		JOB_META_SELECT_EXTRA="$old_extra"
	fi

	success "$job_name has finished correctly"

	#Write to the log a finished operation
	add_to_log "$job_name" "$LOG"
}
