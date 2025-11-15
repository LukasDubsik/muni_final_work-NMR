# shellcheck disable=SC2148
# Guard so we don't load twice
[[ ${_INFO_SH_LOADED:-0} -eq 1 ]] && return
_INFO_SH_LOADED=1

send_email() {
	#Load the input
	local env=$1
	local save_as=$2

	#Move to the script enviroment
	cd "lib/general_scripts/python/" || die "Couldn't move to the script enviroment"

	#Activate the python enviroment
	conda activate "$env"
	#Run the python script
	python -W "ignore" send_message.py "$save_as"
	#Then deactive it
	conda deactivate

	#Return back
	cd ../../.. || die "Couldn't retun back to the root"
}