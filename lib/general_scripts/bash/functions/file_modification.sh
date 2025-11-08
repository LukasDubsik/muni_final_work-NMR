# shellcheck disable=SC2148
# Guard so we don't load twice
[[ ${_FILE_NMODIFICATION_SH_LOADED:-0} -eq 1 ]] && return
_FILE_NMODIFICATION_SH_LOADED=1

# substitute_name_sh_start DST COPY DIR JOB
# Setup the start of the metacentrum job
# Globals: none
# Returns: Nothing
substitute_name_sh_start() {
	# Sed used to replace the name
	local dst=$1 copy=$2 dir=$3 job=$4
	local src="lib/job_scripts/metacentrum_start.txt"
	[[ -f "$src" ]] || die "Missing template: $src"
	sed "s/\${copy}/${copy}/g; s/\${dir}/${dir}/g; s/\${job}/${job}/g" "$src" >"$dst" || die "sed couldn't be performed on: $src"
}

# substitute_name_sh_end DST COPY_END
# What files to copy back to our working dir from the running dir
# Globals: none
# Returns: Nothing
substitute_name_sh_end() {
	# Sed used to replace the name
	local dst=$1 cp_end=$2
	local src="lib/job_scripts/metacentrum_end.txt"
	[[ -f "$src" ]] || die "Missing template: $src"
	sed "s/\${copy_end}/${cp_end}/g" "$src" >"$dst" || die "sed couldn't be performed on: $src"
}

${copy}
${job}
${module}
${name}
${file}
${num}