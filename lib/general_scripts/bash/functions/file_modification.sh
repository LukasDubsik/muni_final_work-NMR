# shellcheck disable=SC2148
# Guard so we don't load twice
[[ ${_FILE_NMODIFICATION_SH_LOADED:-0} -eq 1 ]] && return
_FILE_NMODIFICATION_SH_LOADED=1


# substitute_name_in FIL DST NAME LIMIT
# Substitute values directly into the input script for the job
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

# force_first_md_start IN_FILE
# For the first MD/heating stage started from minimization, we must NOT
# request velocities from the restart. Force: irest=0, ntx=1.
force_first_md_start() {
	local in_file="$1"

	[[ -f "$in_file" ]] || die "Missing MD input file to patch: $in_file"

	# Patch case-insensitively (Amber namelist keywords are case-insensitive)
	sed -E -i \
		-e 's/(^|[[:space:],])([iI][rR][eE][sS][tT])[[:space:]]*=[[:space:]]*[0-9]+/\1irest=0/g' \
		-e 's/(^|[[:space:],])([nN][tT][xX])[[:space:]]*=[[:space:]]*[0-9]+/\1ntx=1/g' \
		"$in_file" || die "Failed to patch irest/ntx in: $in_file"
}

# force_safe_heating_start IN_FILE
# For initial heating, keep constraints to H-bonds only and use a conservative dt.
# This reduces instability risk in metal systems and avoids SHAKE-on-all-bonds (ntc/ntf=3).
force_safe_heating_start() {
	local in_file="$1"

	[[ -f "$in_file" ]] || die "Missing MD input file to patch: $in_file"

	sed -E -i \
		-e 's/(^|[[:space:],])([nN][tT][cC])[[:space:]]*=[[:space:]]*[0-9]+/\1ntc=2/g' \
		-e 's/(^|[[:space:],])([nN][tT][fF])[[:space:]]*=[[:space:]]*[0-9]+/\1ntf=2/g' \
		-e 's/(^|[[:space:],])([dD][tT])[[:space:]]*=[[:space:]]*[0-9.+-Ee]+/\1dt=0.001/g' \
		-e 's/(^|[[:space:],])([iI][gG])[[:space:]]*=[[:space:]]*-?[0-9]+/\1ig=-1/g' \
		"$in_file" || die "Failed to patch safe heating settings in: $in_file"
}

# wrap_pmemd_cuda_fallback SH_FILE
# Rewrites the first pmemd.cuda invocation into a guarded form:
#   - exports OMP_NUM_THREADS=1
#   - retries on CPU with pmemd if pmemd.cuda fails (including segfault exit code)
#   - retries with sander if pmemd also fails (sander often emits a clearer error)
wrap_pmemd_cuda_fallback() {
	local sh_file="$1"

	[[ -f "$sh_file" ]] || die "Missing job script to patch: $sh_file"

	awk '
	BEGIN { done=0 }
	{
		if (!done && $0 ~ /(^|[[:space:];])pmemd\.cuda[[:space:]]/) {
			cmd=$0
			cpu=$0
			sand=$0
			sub(/pmemd\.cuda/, "pmemd", cpu)
			sub(/pmemd\.cuda/, "sander", sand)

			print "export OMP_NUM_THREADS=1"
			print cmd " || { rc=$?; echo \"[WARN] pmemd.cuda failed (rc=${rc}) - retrying with pmemd\" 1>&2; " \
			      cpu " || { rc2=$?; echo \"[WARN] pmemd failed (rc=${rc2}) - retrying with sander\" 1>&2; " \
			      sand "; }; }"
			done=1
			next
		}
		print
	}
	' "$sh_file" > "${sh_file}.tmp" || die "Failed to patch job script: $sh_file"

	mv "${sh_file}.tmp" "$sh_file" || die "Failed to update job script: $sh_file"
}

# substitute_name_in FIL DST NAME LIMIT SIGMA
# Substitute values directly into the input script for the job
# Globals: none
# Returns: Nothing
substitute_name_sh_data() {
	# Sed used to replace the name
	local fil=$1 dst=$2 name=$3 limit=$4 sigma=$5 charge=$6
	local src="lib/general_scripts/bash/${fil}"
	local dst_full="${dst}"
	[[ -f "$src" ]] || die "Missing input file: $src"
	sed "s#\${name}#${name}#g; s#\${limit}#${limit}#g; s#\${sigma}#${sigma}#g; s#\${charge}#${charge}#g" "$src" >"$dst_full" || die "sed couldn't be performed on: $src"
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
	local fil=$1 dst=$2 module=$3 name=$4 file=$5 num=$6 params=$7 charge=$8
	local src="lib/job_scripts/programs/${fil}.txt"
	local dst_full="${dst}/job_file.txt"
	[[ -f "$src" ]] || die "Missing template: $src"
	sed "s#\${module}#${module}#g; s#\${name}#${name}#g; s#\${file}#${file}#g; s#\${num}#${num}#g; s#\${params}#${params}#g; s#\${charge}#${charge}#g" "$src" >"$dst_full" || die "sed couldn't be performed on: $src"
}

# construct_sh_wolf DIR NAME
# Combines the starting file for WOLF cluster with the already substituted file for the job itself
# 	Thus creating a fully working .sh script ready to be submitted to the cluster.
# Globals: none
# Returns: Nothing
construct_sh_wolf() {
	local dir=$1 name=$2
	local full_name="${dir}/${name}.sh"

	#Create the resulting file (truncate if it already exists)
	: > "$full_name"

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

	#Create the resulting file (truncate if it already exists)
	: > "$full_name"

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