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
			if [[ $num -ge 0 && $num -le 4 ]]; then
				curr_sys="preparations"
			elif [[ $num -ge 5 && $num -le 10 ]]; then
				curr_sys="simulation"
			else
				curr_sys="spectrum"
			fi
			rm -rf "process/${curr_sys}/${key}/"
		fi
	done
}