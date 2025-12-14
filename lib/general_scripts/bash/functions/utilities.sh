# shellcheck disable=SC2148
# Guard so we don't load twice
[[ ${_UTILITIES_SH_LOADED:-0} -eq 1 ]] && return
_UTILITIES_SH_LOADED=1

# ensure_dir DIR_NAME
# Makes sure the dir exists by creating it
# Globals: none
# Returns: Nothing
ensure_dir() { mkdir -p "$1"; }

# mol2_has_heavy_metal MOL2_FILE
# Returns 0 if MOL2 contains a heavy metal / non-organic element (e.g., Au, Pt, ...), otherwise 1.
# This is used to:
#   - avoid AM1-BCC (sqm/AM1 has no parameters for many metals)
#   - decide whether to run MCPB.py
mol2_has_heavy_metal() {
	local mol2_file=$1

	[[ -f "$mol2_file" ]] || return 1

	# We scan the @<TRIPOS>ATOM section and check the atom type field (6th column).
	# For metals the type is typically the element symbol (e.g., Au, Zn, Fe, ...).
	awk '
		BEGIN{inatom=0}
		/^@<TRIPOS>ATOM/{inatom=1; next}
		/^@<TRIPOS>BOND/{inatom=0}
		inatom==1{
			at=$6
			gsub(/[^A-Za-z].*$/,"",at)
			if (at ~ /^(Au|Ag|Pt|Pd|Hg|Zn|Cu|Fe|Co|Ni|Mn|Cr|Mo|W|Ir|Ru|Rh|Cd|Pb|Sn|U|Al|Ga|In|Ti|V|Zr)$/) { exit 0 }
		}
		END{ exit 1 }
	' "$mol2_file"
}

clean_process() {
	local last_command=$1
	local num_frames=$2
	local curr_sys=""

	#Delete based on log
	for key in "${!LOG_MAP[@]}"; do
		num=${LOG_MAP[$key]}
		if [[ $num -gt $last_command ]]; then
			if [[ $num -ge 1 && $num -le 5 ]]; then
				curr_sys="preparations"
				rm -rf "process/${curr_sys}/${key}/"
			elif [[ $num -ge 6 && $num -le 11 ]]; then
				curr_sys="run_"
				for ((num=0; num < num_frames; num++))
				do
					rm -rf "process/${curr_sys}${num}/${key}/"
				done
			else
				curr_sys="spectrum"
				rm -rf "process/${curr_sys}/${key}/"
			fi
		fi

		if [[ $num -lt 11 ]]; then
			rm -rf "process/spectrum/frames"
		fi
	done
}

# find_sim_num MD_ITER
# Finds what number of job should now be run
# Globals: none
# Returns: 0 if everyting okay, otherwise number that causes error
find_sim_num() {
	local MD_ITER=$1
	local log=$2

	SEARCH_DIR="process/"

	#If we are below the jobs becessary for run, delete all the runs
	if [[ ($log -lt 6) ]]; then
		for file in "$SEARCH_DIR"/run_*; do
			rm -rf "$file"
		done
	fi

	for ((i=1; i <= MD_ITER; i++)); do 
		if [[ -d $SEARCH_DIR/run_$i ]]; then
			continue
		else
			COUNTER=$i
			break
		fi
	done

	if [[ $COUNTER -eq 0 ]]; then
		COUNTER=$MD_ITER
		info "All the md runs have finished"
	elif [[ $COUNTER -eq 1 ]]; then
		info "No md have yet been run"
	else
		info "The md runs have stopped at (wasn't completed): $COUNTER"
	fi
}