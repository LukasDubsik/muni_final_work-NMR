# shellcheck disable=SC2148
# Guard so we don't load twice
[[ ${_LOGGING_SH_LOADED:-0} -eq 1 ]] && return
_LOGGING_SH_LOADED=1

#Declare existence of an associative array
declare -A LOG_MAP=(
  ["crest"]=1
  ["antechamber"]=2
  ["parmchk2"]=3
  ["tleap"]=4
  ["opt_water"]=5
  ["opt_all"]=6
  ["opt_temp"]=7
  ["opt_pres"]=8
  ["md"]=9
  ["cpptraj"]=10
  ["gauss_prep"]=11
  ["nmr"]=12
  ["plotting"]=13
)

# read_log LOG_FILE
# Reads the current log file and returns the number of the last succesfull operation, then nulls it.
# Globals: none
# Returns: The number of the last file
read_log() {
	local LOG_FILE=$1
	#If the logging is not present, it is okay, just return 0
	#Means that nothing has yet been run
	[[ -f "$LOG_FILE" ]] || return 0

	#Read the last line
	LOG_LAST=$( tail -n 1 "$LOG_FILE" )

	#Restructure the log
	rm -f "$LOG_FILE"

	#Convert that lineinto a number nd return it
	return "${LOG_MAP["$LOG_LAST"]}"
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