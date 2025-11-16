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

	local job_name="gauss_prep"

	info "Started running $job_name"

    #Start by converting the input mol into a xyz format -necessary for crest
	JOB_DIR="process/spectrum/$job_name"
	ensure_dir $JOB_DIR
	ensure_dir $JOB_DIR/frames

	#Move the frames into the gaussian prep run
	cp -r process/spectrum/frames/* $JOB_DIR/frames/

	SRC_DIR_1="lib/general_scripts/bash/general"

	substitute_name_sh_data "general/xyz_to_gfj.sh" "$JOB_DIR/xyz_to_gfj.sh" "" "$limit" ""

	#Ensure the final dir exists
    ensure_dir $JOB_DIR/gauss

	#Run the bash script
	cd "$JOB_DIR" || die "Couldn't enter the cpptraj directory"
	bash xyz_to_gfj.sh
	cd ../../../ || die "Couldn't return back from the cpptraj dir"

	last_frame=$((num_frames - 1))

	#Check that the final files are truly present
	check_res_file "$JOB_DIR/gauss/frame_$last_frame.gfj" "$JOB_DIR" "$job_name"

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
	#Enter the directory and run the .sh script
	for ((num=1; num <= num_frames; num++))
	do
		LOC_DIR="$JOB_DIR/job_${num}/"
		#create a new dir for the file
		mkdir -p "$LOC_DIR"
		#Constrcut the job file
		if [[ $meta == "true" ]]; then
			substitute_name_sh_meta_start "$LOC_DIR" "${directory}" ""
			substitute_name_sh_meta_end "$LOC_DIR"
			substitute_name_sh "$job_name" "$LOC_DIR" "$gaussian" "$name" "" "$num" ""
			construct_sh_meta "$LOC_DIR" "$job_name"
		else
			substitute_name_sh_wolf_start "$LOC_DIR"
			substitute_name_sh "$job_name" "$LOC_DIR" "$gaussian" "$name" "" "" ""
			construct_sh_wolf "$LOC_DIR" "$job_name"
		fi
		( submit_job "$meta" "$job_name" "$LOC_DIR" 8 8 0 "08:00:00" ) &
		pids+=($!)
	done
	#Wait for all jobs to finish; kill all others if just one fails
	for pid in "${pids[@]}"; do
		pid_res=$(wait "$pid")
		if [[ "$pid_res" -eq 0 ]]; then
			kill "${pids[@]}" 2>/dev/null        
			search=$(qselect -u lukasdubsik)
			qdel "$search"
			die "The job $pid has failed!"
		fi
	done

	#Check that the final files are truly present
	check_res_file "$JOB_DIR/nmr/frame.$num_frames.log" "$JOB_DIR" "$job_name"

	success "$job_name has finished correctly"

	#Write to the log a finished operation
	add_to_log "$job_name" "$LOG"
}
