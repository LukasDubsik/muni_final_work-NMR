# shellcheck disable=SC2148
# Guard so we don't load twice
[[ ${_SIMULATION_PARALLEL_SH_LOADED:-0} -eq 1 ]] && return
_SIMULATION_PARALLEL_LOADED=1

# run_sim_step_parr NAME DIRECTORY META AMBER IN_FILE RUN_DIR MD_ITERATIONS JOB_NAME
# Run any of the base simulations (from opt_water to md) in parallel mode
# Globals: none
# Returns: Nothing
run_sim_step_parr() {
	#Load the inputs
	local name=$1
	local directory=$2
	local meta=$3
	local amber=$4
	local in_file=$5
	local md_iterations=$6
	local job_name=$7

	pids=()
	max_parallel=10

	info "Started running $job_name"

	for ((COUNTER=0; COUNTER < md_iterations; COUNTER++))
	do
		run_dir="run_$COUNTER"
		ensure_dir process/"$run_dir"

		(
			# Optimaze the water
			run_"$job_name" "$name" "$directory" "$meta" "$amber" "$in_file" "$run_dir"
 
		) &
		pids+=("$!")

		# Limit the number of concurrent runs
		while (( ${#pids[@]} >= max_parallel )); do
			if ! wait -n; then
				# One of the subshells failed: kill the rest
				kill "${pids[@]}" 2>/dev/null || true
				# Optional: if your run_* functions submit cluster jobs, you can also qdel them here.
				die "One of the parralel $job_name iteration runs failed!"
			fi

			# Clean up finished PIDs from the list
			tmp=()
			for pid in "${pids[@]}"; do
				if kill -0 "$pid" 2>/dev/null; then
					tmp+=("$pid")
				fi
			done
			pids=("${tmp[@]}")
		done
	done

	# Wait for all runs to finish; kill all others if just one fails
	for pid in "${pids[@]}"; do
		if ! wait "$pid"; then
			kill "${pids[@]}" 2>/dev/null || true
			die "One of the parralel $job_name iteration runs failed!"
		fi
	done

	success "The $job_name has finished!"

	#All the optims have finished
}

# run_cpptraj_parr NAME DIRECTORY META AMBER CURR_RUN
# Run cpptraj in parallel mode
# Globals: none
# Returns: Nothing
run_cpptraj_parr() {
	#Load the inputs
	local name=$1
	local directory=$2
	local meta=$3
	local amber_mod=$4
	local inc=$5
	local LIMIT=$6
	local cpptraj=$7
	local cpptraj_mode=$8
	local mamba=$9

	shift 9

	local md_iterations=$1


	pids=()
	max_parallel=10
	COUNTER=0

	job_name="cpptraj"

	info "Started running $job_name"

	for ((COUNTER=0; COUNTER < md_iterations; COUNTER++))
	do
		run_dir="run_$COUNTER"
		curr_start=$((inc * COUNTER))

		(
			# Optimaze the water
			run_"$job_name" "$name" "$directory" "$meta" "$amber_mod" "$curr_start" "$LIMIT" "$cpptraj" "$cpptraj_mode" "$mamba" "$run_dir"

			move_finished_job $run_dir

		) &
		pids+=("$!")

		# Limit the number of concurrent runs
		while (( ${#pids[@]} >= max_parallel )); do
			if ! wait -n; then
				# One of the subshells failed: kill the rest
				kill "${pids[@]}" 2>/dev/null || true
				# Optional: if your run_* functions submit cluster jobs, you can also qdel them here.
				die "One of the parralel $job_name iteration runs failed!"
			fi

			# Clean up finished PIDs from the list
			tmp=()
			for pid in "${pids[@]}"; do
				if kill -0 "$pid" 2>/dev/null; then
					tmp+=("$pid")
				fi
			done
			pids=("${tmp[@]}")
		done
	done

	# Wait for all runs to finish; kill all others if just one fails
	for pid in "${pids[@]}"; do
		if ! wait "$pid"; then
			kill "${pids[@]}" 2>/dev/null || true
			die "One of the parralel $job_name iteration runs failed!"
		fi
	done

	success "The $job_name has finished!"

	#All the optims have finished
}