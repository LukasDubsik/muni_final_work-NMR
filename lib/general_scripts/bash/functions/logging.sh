# shellcheck disable=SC2148
# Guard so we don't load twice
[[ ${_LOGGING_SH_LOADED:-0} -eq 1 ]] && return
_LOGGING_SH_LOADED=1

#Declare existence of an associative array
declare -A LOG_MAP=(
  ["crest"]=1
  ["antechamber"]=2
  ["parmchk2"]=3
  ["nemesis_fix"]=4
  ["tleap"]=5
  ["md_run"]=6
  ["gauss_prep"]=7
  ["gaussian"]=8
  ["analysis"]=9
  ["plotting"]=10
)

# read_log LOG_FILE
# Reads the current log file and returns the number of the last succesfull operation, then nulls it.
# Globals: none
# Returns: Nothing
read_log() {
	local LOG_FILE=$1
	#If the logging is not present, it is okay, just return 0
	#Means that nothing has yet been run
	[[ -f "$LOG_FILE" ]] || return 0

	#Read the last line
	LOG_LAST=$( tail -n 1 "$LOG_FILE" )

	#Restructure the log
	#rm -f "$LOG_FILE"

	if [[ $LOG_LAST == "" ]]; then
		LOG_LAST="empty"
		LOG_POSITION=0
	else
		LOG_POSITION="${LOG_MAP[$LOG_LAST]}"
	fi

	info "Detected Log position as: $LOG_LAST -> $LOG_POSITION"
}

# add_to_log RUNNED_NAME LOG_FILE
# Ads to the log file name of the currently run operation
# Globals: none
# Returns: Nothing
add_to_log() {
	local NAME=$1
	local LOG=$2

	echo "$NAME" >> "$LOG"
}

# remove_run_log LOG_FILE
# Removes the last N lines of log representing one md run so infor about the next may be started
# Globals: none
# Returns: Nothing
remove_run_log() {
	local LOG_FILE=$1
	local N=$2

	# shellcheck disable=SC2034
	for ((i=1; i <= N; i++)); do 
		sed '$d' -i "$LOG_FILE"
	done
}