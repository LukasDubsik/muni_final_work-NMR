# shellcheck disable=SC2148
# Guard so we don't load twice
[[ ${_GAUSS_SH_LOADED:-0} -eq 1 ]] && return
_GAUSS_LOADED=1

# run_gauss_convert META NUM_FRAMES
# Convert the xyz files from the amber simulation into log files for gaussian
# Globals: none
# Returns: Nothing
run_gauss_prep() {
	#Load the inputs
	local meta=$1
	local num_frames=$2

	local job_name="gauss_prep"

	info "Started running $job_name"

    #Start by converting the input mol into a xyz format -necessary for crest
	JOB_DIR="process/spectrum/$job_name"
	ensure_dir $JOB_DIR

	SRC_DIR_1="lib/general_scripts/bash/general"

	move_inp_file "xyz_to_gfj.sh" "$SRC_DIR_1" "$JOB_DIR"

	#Ensure the final dir exists
    ensure_dir $JOB_DIR/gauss

	#Run the bash script
	cd "$JOB_DIR" || die "Couldn't enter the cpptraj directory"
	bash xyz_to_gfj.sh
	cd ../../../ || die "Couldn't return back from the cpptraj dir"

	#Check that the final files are truly present
	check_res_file "gauss/frame.$num_frames.gfj" "$JOB_DIR" "$job_name"

	success "$job_name has finished correctly"

	#Write to the log a finished operation
	add_to_log "$job_name" "$LOG"
}

# run_gaussian META NUM_FRAMES
# For each gjf file run gaussian and acquire the log file of the results
# Globals: none
# Returns: Nothing
run_gaussian() {
	#Load the inputs
	local meta=$1
	local num_frames=$2

	local job_name="gaussian"

	info "Started running $job_name"

    #Start by converting the input mol into a xyz format -necessary for crest
	JOB_DIR="process/spectrum/$job_name"
	ensure_dir $JOB_DIR

	#Directory where to store inputs
	INP_DIR_1="process/spectrum/$job_name/nmr"
	ensure_dir $INP_DIR_1

	#Copy the input files
	SRC_DIR_1="process/spectrum/gauss_prep/"

	cp -r $SRC_DIR_1/gauss/* $INP_DIR_1

	#Run the jobs in parallel each in different directory and subshell
	pids=()
	#Enter the directory and run the .sh script
	for ((num=1; num <= num_frames; num++))
	do
		#create a new dir for the file
		mkdir -p "$JOB_DIR/job_${num}/"
		( run_sh_sim "run_NMR" "spectrum/NMR/job_${num}/" "process/spectrum/gauss_prep/gauss/frame.${num}.gjf" "" "frame.${num}.log" 15 4 0 ${num} 0 ) &
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

    #Run the antechmaber
    submit_job "$meta" "$job_name" "$JOB_DIR" 8 8 0 "02:00:00"

	#Ensure the final dir exists
    ensure_dir $JOB_DIR/gauss

	#Run the bash script
	cd "$JOB_DIR" || die "Couldn't enter the cpptraj directory"
	bash xyz_to_gfj.sh
	cd ../../../ || die "Couldn't return back from the cpptraj dir"

	#Check that the final files are truly present
	check_res_file "gauss/frame.$num_frames.gfj" "$JOB_DIR" "$job_name"

	success "$job_name has finished correctly"

	#Write to the log a finished operation
	add_to_log "$job_name" "$LOG"
}


#Run the jobs in parallel each in different directory and subshell
pids=()
#Enter the directory and run the .sh script
for num in {1..100}; do
    #create a new dir for the file
    mkdir -p "process/spectrum/NMR/job_${num}/"
    ( run_sh_sim "run_NMR" "spectrum/NMR/job_${num}/" "process/spectrum/gauss_prep/gauss/frame.${num}.gjf" "" "frame.${num}.log" 15 4 0 ${num} 0 ) &
    pids+=($!)
done
#Wait for all jobs to finish; kill all others if just one fails
for pid in "${pids[@]}"; do
    wait $pid
    if [[ $? -eq 0 ]]; then
        kill "${pids[@]}" 2>/dev/null        
        echo -e "\t\t\t[$CROSS] ${RED} One of the Gaussian NMR jobs failed! Exiting...${NC}"
        qdel $(qselect -u lukasdubsik)
        exit 1
    fi
done
#All jobs finished successfully
echo -e "\t\t\t[$CHECKMARK] All Gaussian NMR jobs submitted, waiting for them to finish."
#Create the resulting directory nmr
mkdir -p "process/spectrum/NMR/nmr"
#Move the log and delete each of the job dirs
for i in {1..100}; do
    mv process/spectrum/NMR/job_${i}/frame.${i}.log process/spectrum/NMR/nmr/
    rm -rf process/spectrum/NMR/job_${i}
done
echo -e "\t\t\t[$CHECKMARK] Gaussian NMR calculations finished successfully."



run_md() {
	#Load the inputs
	local name=$1
	local directory=$2
	local meta=$3
	local amber=$4
	local in_file=$5

	local job_name="md"

	info "Started running $job_name"

    #Start by converting the input mol into a xyz format -necessary for crest
	JOB_DIR="process/simulation/$job_name"
	ensure_dir $JOB_DIR

	SRC_DIR_1="process/simulation/opt_pres"

	#Copy the data from antechamber
	move_inp_file "${name}_opt_pres.rst7" "$SRC_DIR_1" "$JOB_DIR"
	move_inp_file "${name}.parm7" "$SRC_DIR_1" "$JOB_DIR"

	#Copy the .in file for tleap
	substitute_name_in "$in_file" "$JOB_DIR" "$name" ""

	#Constrcut the job file
	if [[ $meta == "true" ]]; then
		substitute_name_sh_meta_start "$JOB_DIR" "${directory}" ""
		substitute_name_sh_meta_end "$JOB_DIR"
		substitute_name_sh "$job_name" "$JOB_DIR" "$amber" "$name" "$in_file.in" "" ""
		construct_sh_meta "$JOB_DIR" "$job_name"
	else
		substitute_name_sh_wolf_start "$JOB_DIR"
		substitute_name_sh "$job_name" "$JOB_DIR" "$amber" "$name" "$in_file.in" "" ""
		construct_sh_wolf "$JOB_DIR" "$job_name"
	fi

    #Run the antechmaber
    submit_job "$meta" "$job_name" "$JOB_DIR" 8 8 2 "24:00:00"

	#Check that the final files are truly present
	check_res_file "${name}_md.rst7" "$JOB_DIR" "$job_name"

	success "$job_name has finished correctly"

	#Write to the log a finished operation
	add_to_log "$job_name" "$LOG"
}