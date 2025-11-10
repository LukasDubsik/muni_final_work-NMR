# shellcheck disable=SC2148
# Guard so we don't load twice
[[ ${_FILE_NMODIFICATION_SH_LOADED:-0} -eq 1 ]] && return
_FILE_NMODIFICATION_SH_LOADED=1


# substitute_name_in FIL DST NAME
# Substitute values directly into the input script dor the job
# Globals: none
# Returns: Nothing
substitute_name_in() {
	# Sed used to replace the name
	local fil=$1 dst=$2 name=$3 limit=$4
	local src="inputs/simulation/${fil}.in"
	local dst_full="${dst}/${fil}.in"
	[[ -f "$src" ]] || die "Missing input file: $src"
	sed "s#\${name}#${name}#g; s#\${limit}#${limit}#g" "$src" >"$dst_full" || die "sed couldn't be performed on: $src"
}

# substitute_name_sh_meta_start DST COPY DIR JOB
# Setup the start of the metacentrum job
# Globals: none
# Returns: Nothing
substitute_name_sh_meta_start() {
	# Sed used to replace the name
	local dst=$1 dir=$2 env=$3
	local src="lib/job_scripts/metacentrum_start.txt"
	local dst_full="${dst}/start.txt"
	[[ -f "$src" ]] || die "Missing template: $src"
	sed "s#\${dir}#${dir}#g; s#\${job}#${dst}#g; s#\${env}#${env}#g" "$src" >"$dst_full" || die "sed couldn't be performed on: $src"
}

# substitute_name_sh_meta_end DST
# What files to copy back to our working dir from the running dir
# Globals: none
# Returns: Nothing
substitute_name_sh_meta_end() {
	# Sed used to replace the name
	local dst=$1
	local src="lib/job_scripts/metacentrum_end.txt"
	local dst_full="${dst}/end.txt"
	[[ -f "$src" ]] || die "Missing template: $src"
	cp "$src" "$dst_full" || die "sed couldn't be performed on: $src"
}

# substitute_name_sh_wolf_start DST
# Just copies to the resulting dir the starting wolf file
# Globals: none
# Returns: Nothing
substitute_name_sh_wolf_start() {
	# Sed used to replace the name
	local dst=$1
	local src="lib/job_scripts/wolf_start.txt"
	local dst_full="${dst}/start.txt"
	[[ -f "$src" ]] || die "Missing template: $src"
	cp "$src" "$dst_full" || die "sed couldn't be performed on: $src"
}

# substitute_name_sh FIL DST MODULE NAME FILE NUM
# Substitute values directly into the running script of ythe job
# Globals: none
# Returns: Nothing
substitute_name_sh() {
	# Sed used to replace the name
	local fil=$1 dst=$2 module=$3 name=$4 file=$5 num=$6 params=$7
	local src="lib/job_scripts/programs/${fil}.txt"
	local dst_full="${dst}/job_file.txt"
	[[ -f "$src" ]] || die "Missing template: $src"
	sed "s#\${module}#${module}#g; s#\${name}#${name}#g; s#\${file}#${file}#g; s#\${num}#${num}#g; s#\${params}#${params}#g" "$src" >"$dst_full" || die "sed couldn't be performed on: $src"
}

# construct_sh_wolf DIR NAME
# Combines the starting file for WOLF cluster with the already substituted file for the job itself
# 	Thus creating a fully working .sh script ready to be submitted to the cluster.
# Globals: none
# Returns: Nothing
construct_sh_wolf() {
	local dir=$1 name=$2
	local full_name="${dir}/${name}.sh"

	#Create the resulting file
	touch "$full_name"

	#Add the start
	cat "${dir}/start.txt" >> "$full_name"

	#And add the script itself
	cat "${dir}/job_file.txt" >> "$full_name"

	#Remove the .txt files used for construction
	rm -f "${dir}/start.txt"
	rm -f "${dir}/job_file.txt"
}

# construct_sh_meta DIR NAME
# Combines the starting file for Metacentrum with the already substituted file for the job itself
# 	Thus creating a fully working .sh script ready to be submitted to the cluster.
# Globals: none
# Returns: Nothing
construct_sh_meta() {
	local dir=$1 name=$2
	local full_name="${dir}/${name}.sh"

	#Create the resulting file
	touch "$full_name"

	{
		#Add the start
		cat "${dir}/start.txt"

		#And add the script itself
		cat "${dir}/job_file.txt"

		#Lastly add the end of the script
		cat "${dir}/end.txt" 
	} >> "$full_name"

	#Remove the .txt files used for construction
	rm -f "${dir}/start.txt"
	rm -f "${dir}/job_file.txt"
	rm -f "${dir}/end.txt"
}