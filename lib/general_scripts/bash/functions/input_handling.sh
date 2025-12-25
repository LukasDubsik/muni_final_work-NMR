# shellcheck disable=SC2148
# Guard so we don't load twice
[[ ${_INPUT_HANDLING_SH_LOADED:-0} -eq 1 ]] && return
_INPUT_HANDLING_SH_LOADED=1

read_config() {
	#Hardwired location of the input file
	local file="inputs/sim.txt"
	[[ -f "$file" ]] || die "Config file not found: $file"

	#Iterate the file to get all its values
	while IFS= read -r line || [[ -n "$line" ]]; do
		#Skip empty lines and lines starting with # (comments)
		[[ -z "$line" || ${line:0:1} == '#' ]] && continue
		#Extract all lines containing assign
		if [[ "$line" == *":="* ]]; then
			local key=${line%%:=*}
			local val=${line#*:=}
			#Strip all whitespaces from the key
			key=${key//[[:space:]]/}
			Params["$key"]=$val
		fi
	done <"$file"
}

get_cfg() {
	local key=$1
	if [[ -v "Params[$key]" ]]; then 
		printf '%s\n' "${Params[$key]}"; 
	else 
		die "Expected: $key in the sim.txt. It was not present!"; 
	fi
}

get_cfg_opt() {
	local key=$1
	if [[ -v "Params[$key]" ]]; then
		printf "%s\n" "${Params[$key]}"
	else
		printf ''
	fi
}

check_in_file() {
	# Check that given in file truly present
	local name=$1 dir=$2
	local file="$dir/${name}.in"
	[[ -f "$file" ]] || die "Missing input template: $file"
	success ".in present: $file"
}

check_res_file() {
	# Check that given sh script truly present
	local name=$1 dir=$2 job=$3
	local file="$dir/${name}"
	[[ -f "$file" ]] || die "Result ${file} from ${job} is missing!"
}

move_inp_file(){
	local name=$1 src_dir=$2 dst_dir=$3
	local src="$src_dir/$name"
	local dst="$dst_dir/$name"
	[[ -f "$src" ]] || die "Couldn't find $name from previos job in $src_dir!"
	cp "$src" "$dst" || die "The file couldn't be copied from $src_dir to $dst_dir"
}

load_cfg() {
	#Declare the values as explicitly global
	# declare -g \
    # name save_as input_type gpu meta directory amber_ext \
    # tleap opt_water opt_all opt_temp opt_pres md cpptraj \
    # md_iterations antechamber_cmd parmchk2_cmd

	OVR_NAME=$1
	OVR_SAVE=$2

	#See if we have the name for the molecule
	name=${OVR_NAME:-$(get_cfg 'name')}

	#See if we have the save for the molecule
	save_as=${OVR_SAVE:-$(get_cfg 'save_as')}

	#Check that we really want to check available modules
	c_modules=$(get_cfg 'check_modules')

	#How many frames to create
	num_frames=$(get_cfg 'num_frames')

	#If to use specific force field params
	params=$(get_cfg 'params')

	#Get the input type and check it is valid type
	input_type=$(get_cfg 'input_type')
	#Check that it is allowed
	if [[ ! $input_type == 'mol2' && ! $input_type == '7' ]]; then
		exit_program "Only allowed input file types are mol2 and rst/parm7!"
	fi

	#See if we have gpu specified
	gpu=$(get_cfg 'gpu')

	#In what mode to run the cpptraj
	cpptraj_mode=$(get_cfg 'cpptraj_mode')

	#If we want to run the code in metacentrum
	meta=$(get_cfg 'meta')

	#What is the sigma -> spectrum shift
	sigma=$(get_cfg 'sigma')

	#Number of iterations of the md
	md_iterations=$(get_cfg 'md_iterations')

	#Get the overall charge of the system
	charge=$(get_cfg 'charge')

	# Optional: formal charge / oxidation state of the metal ion (e.g., Au(I)=1, Au(III)=3)
	metal_charge=$(get_cfg_opt 'metal_charge')

	info "Config loaded: name=$name, save_as=$save_as, checking modules=$c_modules, number of frames=$num_frames, input_type=$input_type, gpu=$gpu, cpptraj_mode=$cpptraj_mode meta=$meta, sigma=$sigma, md iterations=$md_iterations, charge=$charge, params=$params, metal charge=$metal_charge"

	#By default amber extension is empty
	amber_ext=""

	#If so also see that other important values given
	if [[ $meta == 'true' ]]; then
		#What is our directoryt in which we are running the script
		directory=$(get_cfg 'directory')

		#What version of amber are we using
		amber_ext=$(get_cfg 'amber')

		info "All the informations for metacentrum loaded correctly:"
		info "directory=$directory"
		info "amber=$amber_ext"
	fi

	#Where the crest conda mamda env is located
	mamba=$(get_cfg 'mamba')

	info "mamba=$mamba"

	#Additional parametrs for specfic programs - only for mol2
	if [[ $input_type == "mol2" ]]; then
		antechamber_cmd=$(get_cfg 'antechamber')
		parmchk2_cmd=$(get_cfg 'parmchk2')
		mcpb_cmd=$(get_cfg_opt 'mcpb')

		info "All the additional parametrs for mol2 loaded correctly"
		info "antechamber: $antechamber_cmd"
		info "parmchk2: $parmchk2_cmd"
		if [[ -n "$mcpb_cmd" ]]; then
			info "mcpb: $mcpb_cmd"
		else
			info "mcpb: <disabled>"
		fi
	fi

	#Load the names of the .in files (all need to be under inputs/simulation/)
	tleap=$(get_cfg 'tleap')
	opt_water=$(get_cfg 'opt_water')
	opt_all=$(get_cfg 'opt_all')
	opt_temp=$(get_cfg 'opt_temp')
	opt_pres=$(get_cfg 'opt_pres')
	md=$(get_cfg 'md')
	cpptraj=$(get_cfg 'cpptraj')

	filter=$(get_cfg 'filter')

	info "filter: $filter"
}

check_cfg() {
	#Directory, where the .in fils must be stored
	PATH_TO_INPUTS="inputs/simulation"

	#Go file by file and check if they are present
	check_in_file "$tleap" "$PATH_TO_INPUTS"
	check_in_file "$opt_water" "$PATH_TO_INPUTS"
	check_in_file "$opt_all" "$PATH_TO_INPUTS"
	check_in_file "$opt_temp" "$PATH_TO_INPUTS"
	check_in_file "$opt_pres" "$PATH_TO_INPUTS"
	check_in_file "$md" "$PATH_TO_INPUTS"
	check_in_file "$cpptraj" "$PATH_TO_INPUTS"

	success "All .in files are present and loaded."
}

get_number_of_atoms() {
	local name=$1

	LIMIT=$(grep -A 2 "^@<TRIPOS>MOLECULE" "inputs/structures/${name}.mol2" | tail -n 1 | awk '{print $1}')

	info "The number of atoms of the system are: $LIMIT"
}