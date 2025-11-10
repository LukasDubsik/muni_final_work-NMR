# shellcheck disable=SC2148
# Guard so we don't load twice
[[ ${_UTILITIES_SH_LOADED:-0} -eq 1 ]] && return
_UTILITIES_SH_LOADED=1

# ensure_dir DIR_NAME
# Makes sure the dir exists by creating it
# Globals: none
# Returns: Nothing
ensure_dir() { mkdir -p "$1"; }

clean_process() {
	local last_command=$1
	local curr_sys=""

	for key in "${!LOG_MAP[@]}"; do
		num=${LOG_MAP[$key]}
		if [[ $num -gt $last_command ]]; then
			if [[ $num -ge 1 && $num -le 5 ]]; then
				curr_sys="preparations"
			elif [[ $num -ge 6 && $num -le 11 ]]; then
				curr_sys="simulation"
			else
				curr_sys="spectrum"
			fi
			rm -rf "process/${curr_sys}/${key}/"
		fi
	done
}

# find_sim_num MD_ITER
# Finds what number of job should now be run
# Globals: none
# Returns: 0 if everyting okay, otherwise number that causes error
find_sim_num() {
	local MD_ITER=$1

	SEARCH_DIR="process/"

	for ((i=1; i <= MD_ITER; i++)); do 
		if [[ -d "$SEARCH_DIR/run_$i" ]]; then
			continue
		else
			COUNTER=$i
			break
		fi
	done

	info "The md runs have stopped at (wasn't completed): $COUNTER"
}