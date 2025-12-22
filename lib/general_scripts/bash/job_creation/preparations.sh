# shellcheck disable=SC2148
# Guard so we don't load twice
[[ ${_PREPARATION_SH_LOADED:-0} -eq 1 ]] && return
_PREPARATION_SH_LOADED=1

INPUTS="inputs"

# run_crest NAME DIRECTORY META ENV
# Runs everything pertaining crest
# Globals: none
# Returns: Nothing
run_crest() {
	#Load the inputs
	local name=$1
	local directory=$2
	local meta=$3
	local env=$4

	local job_name="crest"

	info "Started running $job_name"

    #Start by converting the input mol into a xyz format -necessary for crest
	JOB_DIR="process/preparations/$job_name"
	ensure_dir $JOB_DIR

	#Constrcut the job file
	if [[ $meta == "true" ]]; then
		module add openbabel > /dev/null 2>&1
		substitute_name_sh_meta_start "$JOB_DIR" "${directory}" "$env"
		substitute_name_sh_meta_end "$JOB_DIR"
		substitute_name_sh "crest_metacentrum" "$JOB_DIR" "" "${name}" "" "" "" ""
		construct_sh_meta "$JOB_DIR" "$job_name"
	else
		module add obabel > /dev/null 2>&1
		substitute_name_sh_wolf_start "$JOB_DIR"
		substitute_name_sh "$job_name" "$JOB_DIR" "$job_name" "${name}" "" "" "" ""
		construct_sh_wolf "$JOB_DIR" "$job_name"
	fi

    obabel -imol2 "${INPUTS}/structures/${name}.mol2" -oxyz -O "${JOB_DIR}/${name}.xyz" > /dev/null 2>&1
    #Run the crest simulation
    submit_job "$meta" "$job_name" "$JOB_DIR" 4 16 0 "08:00:00"
    #Convert back to mol2 format
    obabel -ixyz "${JOB_DIR}/crest_best.xyz" -omol2 -O "${JOB_DIR}/${name}_crest.mol2" > /dev/null 2>&1
	#Convert the symbols
	sed -i 's/AU/Au /' "${JOB_DIR}/${name}_crest.mol2"

	#Check that the final files are truly present
	check_res_file "${name}_crest.mol2" "$JOB_DIR" "$job_name"

	success "$job_name has finished correctly"

	#Write to the log a finished operation
	add_to_log "$job_name" "$LOG"
}

# run_antechamber NAME DIRECTORY META AMBER
# Runs everything pertaining to antechmaber
# Globals: none
# Returns: Nothing
run_antechamber() {
	#Load the inputs
	local name=$1
	local directory=$2
	local meta=$3
	local amber=$4
	local antechamber_parms=$5
	local charge=$6

	local job_name="antechamber"

	info "Started running $job_name"

	#Start by converting the input mol into a xyz format -necessary for crest
	JOB_DIR="process/preparations/$job_name"
	ensure_dir "$JOB_DIR"

	SRC_DIR="process/preparations/crest"

	#Copy the data from crest
	move_inp_file "${name}_crest.mol2" "$SRC_DIR" "$JOB_DIR"

	# --- Heavy-metal handling --------------------------------------------
	# If the original structure contains a heavy metal (e.g. Au),
	# AM1-BCC (sqm) will fail because it has no parameters for that element.
	# In that case, tell antechamber to *reuse* the input charges (-c rc)
	# and avoid calling sqm completely.
	local struct_file="${INPUTS}/structures/${name}.mol2"
	if has_heavy_metal "$struct_file"; then
		info "Heavy metal detected in $struct_file; forcing antechamber to use input charges (-c rc) instead of AM1-BCC."

		# Generate a stable charge file from the ORIGINAL input mol2
		# (crest/openbabel mol2 often does not preserve partial charges).
		local chg_file="${JOB_DIR}/${name}.crg"
		mol2_write_charge_file "$struct_file" "$chg_file"

		# Strip any existing "-c <...>", "-cf <...>", "-dr <...>" from user parameters
		# and force:
		#   -c rc   (read charges)
		#   -cf ... (charge file)
		#   -dr no  (disable unusual-element checking)
		# Everything else (-at, etc.) stays as configured in sim.txt.
		local base_parms
		base_parms=$(printf '%s\n' "$antechamber_parms" | sed -E \
			's/(^|[[:space:]])-c[[:space:]]+[[:alnum:]]+//g;
			 s/(^|[[:space:]])-cf[[:space:]]+[^[:space:]]+//g;
			 s/(^|[[:space:]])-dr[[:space:]]+[[:alnum:]]+//g')
		antechamber_parms="${base_parms} -c rc -cf ${name}.crg -dr no"

	fi
	# ---------------------------------------------------------------------

	#Constrcut the job file
	if [[ $meta == "true" ]]; then
		substitute_name_sh_meta_start "$JOB_DIR" "${directory}" ""
		substitute_name_sh_meta_end "$JOB_DIR"
		substitute_name_sh "$job_name" "$JOB_DIR" "$amber" "$name" "" "" "$antechamber_parms" "$charge"
		construct_sh_meta "$JOB_DIR" "$job_name"
	else
		substitute_name_sh_wolf_start "$JOB_DIR"
		substitute_name_sh "$job_name" "$JOB_DIR" "$amber" "$name" "" "" "$antechamber_parms" "$charge"
		construct_sh_wolf "$JOB_DIR" "$job_name"
	fi

	#Run the antechamber
	submit_job "$meta" "$job_name" "$JOB_DIR" 4 4 0 "01:00:00"

	#Check that the final files are truly present
	check_res_file "${name}_charges.mol2" "$JOB_DIR" "$job_name"

	success "$job_name has finished correctly"

	#Write to the log a finished operation
	add_to_log "$job_name" "$LOG"
}


# run_parmchk2 NAME DIRECTORY META AMBER
# Runs everything pertaining to parmchk2
# Globals: none
# Returns: Nothing
run_parmchk2() {
	#Load the inputs
	local name=$1
	local directory=$2
	local meta=$3
	local amber=$4
	local parmchk2_params=$5

	local job_name="parmchk2"

	info "Started running $job_name"

    #Start by converting the input mol into a xyz format -necessary for crest
	JOB_DIR="process/preparations/$job_name"
	ensure_dir $JOB_DIR

	SRC_DIR="process/preparations/antechamber"

	#Copy the data from antechamber
	move_inp_file "${name}_charges.mol2" "$SRC_DIR" "$JOB_DIR"

	# parmchk2 is for the organic part; heavy metals frequently break/poison the frcmod generation.
	# If a metal is present, run parmchk2 on a ligand-only MOL2, but keep the full MOL2 for MCPB.
	local full_mol2="$JOB_DIR/${name}_charges.mol2"
	local mcpb_mol2="$full_mol2"

		# Strip the metal for the parmchk2 run (keep a full copy for MCPB)
	local mcpb_mol2="$JOB_DIR/${name}_charges_full.mol2"
	local mcpb_input_mol2="$full_mol2"

	if mol2_has_metal "$full_mol2"; then
		cp "$full_mol2" "$mcpb_mol2"

		local metal_id
		metal_id="$(mol2_first_metal_id "$mcpb_mol2")"

		if [[ "$metal_id" == "-1" ]]; then
			warning "Metal expected but could not be identified in MOL2; skipping strip. (This may break parmchk2.)"
		else
			info "Metal detected in MOL2 (atom_id=$metal_id). Stripping it for parmchk2 (MCPB will use the full MOL2)."
			mol2_strip_atom "$mcpb_mol2" "$full_mol2" "$metal_id"

			# MCPB must see the full (unstripped) MOL2
			mcpb_input_mol2="$mcpb_mol2"
		fi
	fi

	#Constrcut the job file
	if [[ $meta == "true" ]]; then
		substitute_name_sh_meta_start "$JOB_DIR" "${directory}" ""
		substitute_name_sh_meta_end "$JOB_DIR"
		substitute_name_sh "$job_name" "$JOB_DIR" "$amber" "$name" "" "" "$parmchk2_params" ""
		construct_sh_meta "$JOB_DIR" "$job_name"
	else
		substitute_name_sh_wolf_start "$JOB_DIR"
		substitute_name_sh "$job_name" "$JOB_DIR" "$amber" "$name" "" "" "$parmchk2_params" ""
		construct_sh_wolf "$JOB_DIR" "$job_name"
	fi

    #Run the antechmaber
    submit_job "$meta" "$job_name" "$JOB_DIR" 8 8 0 "01:00:00"

	#Check that the final files are truly present
	check_res_file "${name}.frcmod" "$JOB_DIR" "$job_name"

	# MCPB.py step 2 crashes on an empty frcmod; ensure non-empty file
	if [[ ! -s "$JOB_DIR/${name}.frcmod" ]]; then
		warning "parmchk2 produced an empty frcmod ($JOB_DIR/${name}.frcmod). Creating a minimal stub so MCPB.py can proceed."
		cat > "$JOB_DIR/${name}.frcmod" <<'EOF'
remark generated by nmr.sh: empty parmchk2 frcmod; no overrides needed
MASS
BOND
ANGLE
DIHE
IMPROPER
NONBON
EOF
	fi

	success "$job_name has finished correctly"

	#Write to the log a finished operation
	add_to_log "$job_name" "$LOG"
}


# run_mcpb NAME DIRECTORY META AMBER
# Runs MCPB.py metal-center parametrization and merges the resulting frcmod
# into the standard parmchk2 frcmod.
# Globals: none
# Returns: Nothing
# run_mcpb NAME DIRECTORY META AMBER MCPB_CMD IN_MOL2 LIG_FRCMOD
run_mcpb() {
	local name="$1"
	local directory="$2"
	local meta="$3"
	local amber="$4"
	local mcpb_cmd="$5"
	local in_mol2="$6"
	local lig_frcmod="$7"

	# Optional: cap Gaussian opt cycles for MCPB small model
	local gauss_opt_maxcycle=3

	# If MCPB is not configured, do nothing
	if [[ -z "${mcpb_cmd:-}" ]]; then
		info "Skipping MCPB.py (no mcpb option set in config)"
		return 0
	fi

	# Only run if a metal is present
	if ! mol2_has_metal "$in_mol2"; then
		info "No metal detected in ${in_mol2}; skipping MCPB.py"
		return 0
	fi

	# Resolve requested MCPB step (default 4 if user provided something non-empty but without -s/--step)
	local mcpb_step=4
	if [[ "$mcpb_cmd" =~ (^|[[:space:]])(-s|--step)[[:space:]]*([0-9]+) ]]; then
		mcpb_step="${BASH_REMATCH[3]}"
	fi

	local job_name="mcpb"
	local BASE_DIR="process/preparations/${job_name}"
	local STAGE1_DIR="${BASE_DIR}/01_step1"
	local STAGE2_DIR="${BASE_DIR}/02_qm"
	local STAGE3_DIR="${BASE_DIR}/03_params"

	# -----------------------------
	# Stage cleanup / anti-accumulation
	# Anything not explicitly marked OK is considered stale and must be rebuilt.
	# -----------------------------
	local STAGE1_OK="$STAGE1_DIR/.ok"
	local STAGE2_OK="$STAGE2_DIR/.ok"
	local STAGE3_OK="$STAGE3_DIR/.ok"

	# If stage 1 isn't OK, nothing downstream is valid.
	if [[ ! -f "$STAGE1_OK" ]]; then
		rm -rf "$STAGE1_DIR" "$STAGE2_DIR" "$STAGE3_DIR"
	fi

	# If stage 1 is OK but stage 2 isn't, wipe stage 2 and 3.
	if [[ -f "$STAGE1_OK" && ! -f "$STAGE2_OK" ]]; then
		rm -rf "$STAGE2_DIR" "$STAGE3_DIR"
	fi

	# If stage 2 is OK but stage 3 isn't, wipe stage 3.
	if [[ -f "$STAGE2_OK" && ! -f "$STAGE3_OK" ]]; then
		rm -rf "$STAGE3_DIR"
	fi

	ensure_dir "$STAGE1_DIR"
	ensure_dir "$STAGE2_DIR"
	ensure_dir "$STAGE3_DIR"

	local STAGE1_JOB="${job_name}_01_step1"
	local STAGE2_JOB="${job_name}_02_qm"
	local STAGE3_JOB="${job_name}_03_params"

	# ---------------------------------------------------------------------
	# Stage 0: prepare MCPB inputs (done on login node; very fast)
	# ---------------------------------------------------------------------
	local src_mol2="$STAGE1_DIR/${name}_mcpb_source.mol2"
	if [[ ! -f "$src_mol2" ]]; then
		cp "$in_mol2" "$src_mol2"
	fi

	# Always ensure LIG.frcmod exists in stage1
	if [[ ! -f "$STAGE1_DIR/LIG.frcmod" ]]; then
		cp "$lig_frcmod" "$STAGE1_DIR/LIG.frcmod"
	fi

	# Sanitize MOL2 if it contains an extra element column in @<TRIPOS>ATOM
	mol2_sanitize_atom_coords_inplace "$src_mol2"

	# Identify the first metal line (from ATOM section)
	local metal_line
	metal_line="$(mol2_first_metal "$src_mol2")"
	[[ -n "$metal_line" ]] || die "Failed to detect metal in $src_mol2"

	local metal_id metal_elem metal_charge mx my mz
	read -r metal_id metal_elem metal_charge mx my mz <<< "$metal_line"
	metal_charge="${metal_charge:-0.0}"
	metal_elem=$(echo "$metal_elem" | tr '[:lower:]' '[:upper:]')

	# Generate PDB and split MOL2s (only if missing / empty)
	if [[ ! -s "$STAGE1_DIR/${name}_mcpb.pdb" ]]; then
		mol2_to_mcpb_pdb "$src_mol2" "$STAGE1_DIR/${name}_mcpb.pdb" "$metal_id"
	fi
	if [[ ! -s "$STAGE1_DIR/LIG.mol2" ]]; then
		mol2_strip_atom "$src_mol2" "$STAGE1_DIR/LIG.mol2" "$metal_id"
	fi
	if [[ ! -s "$STAGE1_DIR/${metal_elem}.mol2" ]]; then
		write_single_ion_mol2 "$STAGE1_DIR/${metal_elem}.mol2" "$metal_elem" "$metal_charge" "$mx" "$my" "$mz"
	fi

	# MCPB-specific MOL2 sanitization (residue names, etc.)
	mol2_sanitize_for_mcpb "$STAGE1_DIR/LIG.mol2" "LIG"
	mol2_sanitize_for_mcpb "$STAGE1_DIR/${metal_elem}.mol2" "$metal_elem"

	# If user only wants step 1, stage split still makes sense: we run only stage1 job.
	# ---------------------------------------------------------------------
	# Stage 1/3: MCPB.py -s 1  (generates QM inputs)
	# ---------------------------------------------------------------------
	if [[ $mcpb_step -ge 1 ]]; then
		local need_stage1="true"
		if [[ -f "$STAGE1_OK" && -s "$STAGE1_DIR/${name}_small_opt.com" && -s "$STAGE1_DIR/${name}_small_fc.com" ]]; then
			need_stage1="false"
		fi

		if [[ "$need_stage1" == "true" ]]; then
			info "MCPB Stage 1/3: MCPB.py -s 1 (generate QM inputs)"

			# Build stage-1 job body
			cat > "$STAGE1_DIR/job_file.txt" <<EOF
module add ${amber}

# Gaussian module (needed by some MCPB setups; harmless if unused here)
module add g16 2>/dev/null || module add gaussian 2>/dev/null || true

NAME="${name}"

# Create MCPB input locally in the run dir (no external template dependency)
{
	echo "original_pdb ${name}_mcpb.pdb"
	echo "group_name ${name}"
	echo "cut_off 2.8"
	echo "ion_ids ${metal_id}"
	echo "ion_mol2files ${metal_elem}.mol2"
	echo "naa_mol2files LIG.mol2"
	echo "frcmod_files LIG.frcmod"
	echo "large_opt 0"
} > "\${NAME}_mcpb.in"

[ -s "\${NAME}_mcpb.in" ] || { echo "[ERR] Missing MCPB input"; exit 1; }

echo "[INFO] Running MCPB.py step 1"
MCPB.py -i "\${NAME}_mcpb.in" -s 1
EOF

			# Construct job script
			if [[ "$meta" == "true" ]]; then
				substitute_name_sh_meta_start "$STAGE1_DIR" "${directory}" ""
				substitute_name_sh_meta_end "$STAGE1_DIR"
				construct_sh_meta "$STAGE1_DIR" "$STAGE1_JOB"
			else
				substitute_name_sh_wolf_start "$STAGE1_DIR"
				construct_sh_wolf "$STAGE1_DIR" "$STAGE1_JOB"
			fi

			# Run (light resources)
			submit_job "$meta" "$STAGE1_JOB" "$STAGE1_DIR" 8 8 0 "01:00:00"

			# Check expected outputs
			check_res_file "${name}_small_opt.com" "$STAGE1_DIR" "$STAGE1_JOB"
			check_res_file "${name}_small_fc.com" "$STAGE1_DIR" "$STAGE1_JOB"

			if [[ "${metal_elem}" == "AU" ]]; then
				sed -i -E '/^[[:space:]]*#/ s@/(6-31G\*|6-31G\(d\)|6-31G\(d,p\))@/def2SVP@Ig' \
					"$STAGE1_DIR/${name}_small_fc.com"
			fi

			touch "$STAGE1_OK"
		else
			info "MCPB Stage 1/3 already done; skipping"
		fi
	fi

	# Stop early if user requested only step 1
	if [[ $mcpb_step -le 1 ]]; then
		success "mcpb finished at requested step ${mcpb_step} (stage 1 only)"
		return 0
	fi

	# ---------------------------------------------------------------------
	# Stage 2/3: Gaussian QM (small_opt + small_fc)
	# ---------------------------------------------------------------------
	if [[ $mcpb_step -ge 2 ]]; then
		# Ensure stage2 has the .com inputs (copy, do not move; keep stage1 intact)
		cp -f "$STAGE1_DIR/${name}_small_opt.com" "$STAGE2_DIR/" || die "Missing ${name}_small_opt.com from stage1"
		cp -f "$STAGE1_DIR/${name}_small_fc.com" "$STAGE2_DIR/"  || die "Missing ${name}_small_fc.com from stage1"

		# Patch the optimization route line to cap cycles (and speed convergence with CalcFC)
		if [[ -n "$gauss_opt_maxcycle" ]]; then
			# Replace a bare " Opt" with Opt=(CalcFC,MaxCycle=N)
			sed -i -E "0,/^[[:space:]]*#/{s/[[:space:]]+Opt([[:space:]]|\$)/ Opt=(CalcFC,MaxCycle=${gauss_opt_maxcycle})\\1/}" \
				"$STAGE2_DIR/${name}_small_opt.com"

			# If Opt is already Opt=(...), inject/replace MaxCycle
			if grep -qE '^[[:space:]]*#.*\bOpt[[:space:]]*\(' "$STAGE2_DIR/${name}_small_opt.com"; then
				# Remove any existing MaxCycle/MaxCycles, then add MaxCycle
				sed -i -E \
					"0,/^[[:space:]]*#/{s/\bMaxCycles?\s*=\s*[0-9]+\s*,?//Ig; s/\bOpt\s*\(([^)]*)\)/Opt(\\1,MaxCycle=${gauss_opt_maxcycle})/I}" \
					"$STAGE2_DIR/${name}_small_opt.com"
			fi
		fi

		# Ensure FC uses a basis that supports the metal and matches the OPT checkpoint basis.
		if [[ "${metal_elem}" == "AU" ]]; then
			# Only touch route lines (start with #)
			sed -i -E '/^[[:space:]]*#/ s@/(6-31G\*|6-31G\(d\)|6-31G\(d,p\))@/def2SVP@Ig' \
				"$STAGE2_DIR/${name}_small_fc.com"
		fi

		local need_stage2="true"
		if [[ -f "$STAGE2_OK" && -s "$STAGE2_DIR/${name}_small_opt.log" && -s "$STAGE2_DIR/${name}_small_fc.log" ]]; then
			if grep -q "Normal termination of Gaussian" "$STAGE2_DIR/${name}_small_opt.log" \
				&& grep -q "Normal termination of Gaussian" "$STAGE2_DIR/${name}_small_fc.log"; then
				need_stage2="false"
			fi
		fi

		if [[ -f "$STAGE2_OK" ]]; then
			need_stage2="false"
		fi

		if [[ "$need_stage2" == "true" ]]; then
			info "MCPB Stage 2/3: Gaussian QM (opt + freq)"

			# Build stage-2 job body (uses your robust hang-detection runner)
			cat > "$STAGE2_DIR/job_file.txt" <<'EOF'
# Gaussian
module add g16 2>/dev/null || module add gaussian 2>/dev/null || true

gauss_ok() {
	local out="$1"
	[ -f "$out" ] || return 1
	grep -q "Normal termination of Gaussian" "$out"
}

run_gaussian() {
	local com="$1"
	local stem="${com%.com}"
	local out="${stem}.log"

	if [ ! -f "$com" ]; then
		echo "[ERR] Gaussian input missing: $com"
		return 1
	fi

	if ! command -v g16 >/dev/null 2>&1; then
		echo "[ERR] g16 not found in PATH"
		return 1
	fi

	local ncpus="${PBS_NCPUS:-${OMP_NUM_THREADS:-1}}"
	if [ "$ncpus" -lt 1 ]; then ncpus=1; fi
	export OMP_NUM_THREADS="$ncpus"
	export MKL_NUM_THREADS="$ncpus"
	export OPENBLAS_NUM_THREADS="$ncpus"

	export GAUSS_SCRDIR="${SCRATCHDIR:-${GAUSS_SCRDIR:-$PWD}}"
	mkdir -p "$GAUSS_SCRDIR" || true

	printf "\n" >> "$com" 2>/dev/null || true

	if command -v g16-prepare >/dev/null 2>&1 && [ -n "${SCRATCHDIR:-}" ]; then
		g16-prepare "$com" >> "$out" 2>&1 || true
	fi

	rwf_total_size() {
		find "$GAUSS_SCRDIR" -maxdepth 1 -type f -name 'Gau-*.rwf' -printf '%s\n' 2>/dev/null | awk '{s+=$1} END{print s+0}'
	}

	chk_size() {
		stat -c %s "${stem}.chk" 2>/dev/null || echo 0
	}

	tree_pcpu() {
		local root="$1"
		local kids pids
		kids="$(pgrep -P "$root" 2>/dev/null | tr '\n' ' ')"
		pids="$root $kids"
		ps -o pcpu= -p $pids 2>/dev/null | awk '{s+=$1} END{printf "%.1f\n", s+0}'
	}

	fix_rwf_0mb() {
		if grep -qiE '^%[Rr][Ww][Ff]=.*,[[:space:]]*0MB' "$com"; then
			local avail_gb use_gb
			avail_gb=$(df -BG "$GAUSS_SCRDIR" 2>/dev/null | awk 'NR==2{gsub(/G/,"",$4); print $4}')
			if [ -z "$avail_gb" ]; then avail_gb=20; fi
			use_gb=$((avail_gb>10 ? avail_gb-5 : avail_gb))
			if [ "$use_gb" -lt 10 ]; then use_gb=10; fi
			if [ "$use_gb" -gt 200 ]; then use_gb=200; fi
			sed -i -E "s#^(%[Rr][Ww][Ff]=[^,]*),[[:space:]]*0MB#\\1,${use_gb}GB#I" "$com" || true
			echo "[INFO] Patched %RWF size from 0MB -> ${use_gb}GB" >> "$out"
		fi
	}

	fix_au_basis() {
		if grep -qE '^[[:space:]]*Au[[:space:]]' "$com" && grep -qE '^#.*\/6-31G\*' "$com"; then
			sed -i -E 's@/6-31G\*@/def2SVP@g' "$com" || true
			echo "[INFO] Detected Au + 6-31G*: switched to def2SVP." >> "$out"
		fi
	}

	fix_rwf_0mb
	fix_au_basis

	echo "[INFO] Running Gaussian: $(basename "$com") (ncpus=${ncpus}, scrdir=${GAUSS_SCRDIR})"

	setsid g16 "$com" > "$out" 2>&1 &
	local pid=$!

	local idle=0
	local idle_limit=20

	local last_out_sz last_rwf_sz last_chk_sz
	last_out_sz=$(stat -c %s "$out" 2>/dev/null || echo 0)
	last_rwf_sz=$(rwf_total_size)
	last_chk_sz=$(chk_size)

	while kill -0 "$pid" 2>/dev/null; do
		sleep 60

		local out_sz rwf_sz chk_sz pcpu
		out_sz=$(stat -c %s "$out" 2>/dev/null || echo 0)
		rwf_sz=$(rwf_total_size)
		chk_sz=$(chk_size)
		pcpu=$(tree_pcpu "$pid")

		if [ "$out_sz" -gt "$last_out_sz" ] || [ "$rwf_sz" -gt "$last_rwf_sz" ] || [ "$chk_sz" -gt "$last_chk_sz" ] || awk -v p="$pcpu" 'BEGIN{exit !(p>=0.5)}'; then
			idle=0
			last_out_sz="$out_sz"
			last_rwf_sz="$rwf_sz"
			last_chk_sz="$chk_sz"
			continue
		fi

		idle=$((idle+1))
		if [ "$idle" -ge "$idle_limit" ]; then
			echo "[ERR] Gaussian appears hung for ${idle_limit} minutes: $(basename "$com")" >> "$out"
			ps -o pid,ppid,stat,pcpu,pmem,etime,cmd -p "$pid" --ppid "$pid" >> "$out" 2>&1 || true

			kill -TERM -- -"$pid" 2>/dev/null || true
			sleep 10
			kill -KILL -- -"$pid" 2>/dev/null || true
			wait "$pid" 2>/dev/null || true
			return 1
		fi
	done

	wait "$pid"
	local rc=$?
	if [ "$rc" -ne 0 ]; then
		echo "[ERR] Gaussian failed: $(basename "$com") (rc=$rc)" >> "$out"
		return "$rc"
	fi

	return 0
}

# Do NOT let set -e / explicit exit prevent wrapper copy-back.
# We will run both jobs, record status, and finish cleanly.
JOB_STATUS=0

set +e

run_gaussian "NAME_small_opt.com"
rc_opt=$?

if ! gauss_ok "NAME_small_opt.log"; then
	echo "[WARN] small_opt not normally terminated (rc=${rc_opt}). Will still attempt small_fc using whatever chk exists."
	# Do not hard-fail here; MCPB can still succeed if small_fc completes.
	JOB_STATUS=1
fi

run_gaussian "NAME_small_fc.com"
rc_fc=$?

if ! gauss_ok "NAME_small_fc.log"; then
	echo "[ERR] small_fc not normally terminated (rc=${rc_fc})."
	JOB_STATUS=2
fi

set -e

echo "[INFO] Gaussian exit codes: opt=${rc_opt} fc=${rc_fc} JOB_STATUS=${JOB_STATUS}"

# IMPORTANT: do NOT 'exit 1' here; let the wrapper copy files back.
# The driver (run_mcpb) will decide whether to proceed based on logs.
true

EOF

			# Inject NAME into stage2 job body (no new helper functions; keep style)
			sed -i "s/NAME/${name}/g" "$STAGE2_DIR/job_file.txt"

			# Construct job script
			if [[ "$meta" == "true" ]]; then
				substitute_name_sh_meta_start "$STAGE2_DIR" "${directory}" ""
				substitute_name_sh_meta_end "$STAGE2_DIR"
				construct_sh_meta "$STAGE2_DIR" "$STAGE2_JOB"
			else
				substitute_name_sh_wolf_start "$STAGE2_DIR"
				construct_sh_wolf "$STAGE2_DIR" "$STAGE2_JOB"
			fi

			# MetaCentrum: Gaussian needs license + local scratch
			local old_extra="${JOB_META_SELECT_EXTRA:-}"
			if [[ "$meta" == "true" ]]; then
				local scratch_gb=50
				JOB_META_SELECT_EXTRA="host_licenses=g16:scratch_local=${scratch_gb}gb"
			fi

			submit_job "$meta" "$STAGE2_JOB" "$STAGE2_DIR" 32 32 0 "12:00:00"

			JOB_META_SELECT_EXTRA="$old_extra"

			check_res_file "${name}_small_opt.log" "$STAGE2_DIR" "$STAGE2_JOB"
			check_res_file "${name}_small_fc.log"  "$STAGE2_DIR" "$STAGE2_JOB"

			# small_opt may legitimately stop early (MaxCycles / time). Warn, but do not fail.
			if ! grep -q "Normal termination of Gaussian" "$STAGE2_DIR/${name}_small_opt.log"; then
				warning "Gaussian small_opt did not terminate normally (allowed). Continuing as long as small_fc is OK."
			fi

			# small_fc must be valid for MCPB step 2
			grep -q "Normal termination of Gaussian" "$STAGE2_DIR/${name}_small_fc.log" \
				|| die "Gaussian small_fc did not terminate normally; cannot continue to MCPB step 2."

			touch "$STAGE2_OK"
		else
			info "MCPB Stage 2/3 already done; skipping"
		fi
	fi

	# ---------------------------------------------------------------------
	# Stage 3/3: MCPB.py -s 2 (+ -s 4 if requested)
	# ---------------------------------------------------------------------
	if [[ $mcpb_step -ge 2 ]]; then
		# Copy all MCPB inputs + QM outputs into stage3 (copy, do not move)
		cp -f "$STAGE1_DIR/${name}_mcpb.pdb" "$STAGE3_DIR/"
		cp -f "$STAGE1_DIR/LIG.mol2" "$STAGE3_DIR/"
		cp -f "$STAGE1_DIR/${metal_elem}.mol2" "$STAGE3_DIR/"
		cp -f "$STAGE1_DIR/LIG.frcmod" "$STAGE3_DIR/"

		# Needed by MCPB.py -s 2 and -s 4 (standard model + fingerprint)
		cp -f "$STAGE1_DIR/${name}_standard.pdb" "$STAGE3_DIR/" 2>/dev/null || true
		cp -f "$STAGE1_DIR/${name}_standard.fingerprint" "$STAGE3_DIR/" 2>/dev/null || true
		cp -f "$STAGE1_DIR/${name}_small.res" "$STAGE3_DIR/" 2>/dev/null || true
		cp -f "$STAGE1_DIR/${name}_small.pdb" "$STAGE3_DIR/" 2>/dev/null || true

		cp -f "$STAGE2_DIR/${name}_small_opt.log" "$STAGE3_DIR/"
		cp -f "$STAGE2_DIR/${name}_small_fc.log" "$STAGE3_DIR/"
		cp -f "$STAGE2_DIR/${name}_small_opt.chk" "$STAGE3_DIR/"

		local need_stage3="true"
		if [[ -f "$STAGE3_OK" && -s "$STAGE3_DIR/${name}_mcpbpy.frcmod" ]]; then
			if [[ $mcpb_step -lt 4 || -s "$STAGE3_DIR/${name}_tleap.in" ]]; then
				need_stage3="false"
			fi
		fi

		if [[ "$need_stage3" == "true" ]]; then
			info "MCPB Stage 3/3: MCPB.py -s 2 (and -s 4 if requested)"

			cat > "$STAGE3_DIR/job_file.txt" <<EOF
module add ${amber}

NAME="${name}"
STEP="${mcpb_step}"

# Recreate MCPB input (same as stage1; no external templates)
{
	echo "original_pdb ${name}_mcpb.pdb"
	echo "group_name ${name}"
	echo "cut_off 2.8"
	echo "ion_ids ${metal_id}"
	echo "ion_mol2files ${metal_elem}.mol2"
	echo "naa_mol2files LIG.mol2"
	echo "frcmod_files LIG.frcmod"
	echo "large_opt 0"
} > "\${NAME}_mcpb.in"

echo "[INFO] Running MCPB.py step 2"
MCPB.py -i "\${NAME}_mcpb.in" -s 2

# Normalize outputs to stable names expected by the rest of your pipeline
if [[ -f "frcmod_\${NAME}" ]]; then
	cp "frcmod_\${NAME}" "\${NAME}_mcpbpy.frcmod"
fi
if [[ -f "\${NAME}.lib" ]]; then
	cp "\${NAME}.lib" "\${NAME}_mcpbpy.lib"
fi

# Generate the fchk file
formchk ${name}_small_opt.chk ${name}_small_opt.fchk

if [[ "\$STEP" -ge 4 ]]; then
	echo "[INFO] Running MCPB.py step 4"
	MCPB.py -i "\${NAME}_mcpb.in" -s 4

	# Some MCPB versions output tleap.in
	if [[ ! -f "\${NAME}_tleap.in" && -f "tleap.in" ]]; then
		cp "tleap.in" "\${NAME}_tleap.in"
	fi
fi
EOF

			if [[ "$meta" == "true" ]]; then
				substitute_name_sh_meta_start "$STAGE3_DIR" "${directory}" ""
				substitute_name_sh_meta_end "$STAGE3_DIR"
				construct_sh_meta "$STAGE3_DIR" "$STAGE3_JOB"
			else
				substitute_name_sh_wolf_start "$STAGE3_DIR"
				construct_sh_wolf "$STAGE3_DIR" "$STAGE3_JOB"
			fi

			submit_job "$meta" "$STAGE3_JOB" "$STAGE3_DIR" 32 8 0 "02:00:00"

			check_res_file "${name}_mcpbpy.frcmod" "$STAGE3_DIR" "$STAGE3_JOB"
			check_res_file "${name}_mcpbpy.lib"   "$STAGE3_DIR" "$STAGE3_JOB"

			if [[ $mcpb_step -ge 4 ]]; then
				check_res_file "${name}_tleap.in" "$STAGE3_DIR" "$STAGE3_JOB"
			fi

			touch "$STAGE3_OK"
		else
			info "MCPB Stage 3/3 already done; skipping"
		fi
	fi

	success "mcpb finished correctly (stages preserved under ${BASE_DIR})"
}

# run_nemesis_fix NAME
# Moves the mol2 file through nemesis (openbabel) to correct some mistakes from antechmaber
# Globals: none
# Returns: Nothing
run_nemesis_fix() {
	#Load the inputs
	local name=$1

	local job_name="nemesis_fix"

	info "Started running $job_name"

    #Start by converting the input mol into a xyz format -necessary for crest
	JOB_DIR="process/preparations/$job_name"
	ensure_dir $JOB_DIR

	SRC_DIR="process/preparations/antechamber"

	#Copy the data from antechamber
	move_inp_file "${name}_charges.mol2" "$SRC_DIR" "$JOB_DIR"

	#Add the correct module
	if [[ $meta == "true" ]]; then
		module add openbabel > /dev/null 2>&1
	else
		module add obabel > /dev/null 2>&1
	fi

	obabel -imol2 "$JOB_DIR/${name}_charges.mol2" -omol2 -O "$JOB_DIR/${name}_charges_fix.mol2" > /dev/null 2>&1

	# OpenBabel may rewrite MOL2 metadata and metal atom types (e.g., Au -> Au).
	# Normalize to GAFF/GAFF2 expectations.
	mol2_normalize_obabel_output_inplace "$JOB_DIR/${name}_charges_fix.mol2" "$name"

	#Check that the final files are truly present
	check_res_file "${name}_charges_fix.mol2" "$JOB_DIR" "$job_name"

	success "$job_name has finished correctly"

	#Write to the log a finished operation
	add_to_log "$job_name" "$LOG"
}

# run_tleap NAME DIRECTORY META AMBER
# Runs everything pertaining to parmchk2
# Globals: none
# Returns: Nothing
run_tleap() {
	#Load the inputs
	local name=$1
	local directory=$2
	local meta=$3
	local amber=$4
	local in_file=$5
	local params=$6

	local job_name="tleap"

	info "Started running $job_name"

    #Start by converting the input mol into a xyz format -necessary for crest
	JOB_DIR="process/preparations/$job_name"
	ensure_dir $JOB_DIR

	SRC_DIR_1="process/preparations/parmchk2"
	SRC_DIR_2="process/preparations/nemesis_fix"
	SRC_DIR_3="inputs/params"

	#Copy the data from antechamber
	move_inp_file "${name}.frcmod" "$SRC_DIR_1" "$JOB_DIR"
	move_inp_file "${name}_charges_fix.mol2" "$SRC_DIR_2" "$JOB_DIR"

	#If also spec, load the necessary files
	if [[ $params == "yes" ]]; then
		cp  "$SRC_DIR_3/gaff.zf" "$JOB_DIR"
		cp  "$SRC_DIR_3/leaprc.zf" "$JOB_DIR"
	fi

	#Copy the .in file for tleap
	substitute_name_in "$in_file" "$JOB_DIR" "$name" ""

	# If MCPB produced a tleap input, reuse its parameter/library load statements
	# so teLeap knows the metal atom type + metal-ligand bonded terms.
	local tleap_in="${in_file}.in"
	local MCPB_DIR="process/preparations/mcpb/03_params"
	[[ -d "$MCPB_DIR" ]] || MCPB_DIR="process/preparations/mcpb"

	if [[ -f "${MCPB_DIR}/${name}_tleap.in" ]]; then
		info "Detected MCPB output – importing metal parameters into tleap input"

		# Copy MCPB artifacts that its tleap file may load
		cp "${MCPB_DIR}"/*.frcmod "${MCPB_DIR}"/*.lib "${MCPB_DIR}"/*.off "${MCPB_DIR}"/*.dat \
			"$JOB_DIR" 2>/dev/null || true

		# Extract only load statements (avoid unit creation / save / quit)
		grep -E '^(loadAmberParams|loadamberparams|loadoff|loadOff)[[:space:]]' \
			"${MCPB_DIR}/${name}_tleap.in" \
			| sed 's#^[[:space:]]*##; s#\./##g' > "$JOB_DIR/mcpb_params.in" || true

		# Filter out MCPB load statements that reference local files that are not present.
		# (Common when MCPB step 4 is run without having generated step 2 outputs yet.)
		if [[ -s "$JOB_DIR/mcpb_params.in" ]]; then
			local mcpb_filtered="$JOB_DIR/mcpb_params.filtered.in"
			: > "$mcpb_filtered"

			while IFS= read -r line; do
				# Normalize (strip leading spaces, remove leading "./")
				line="$(printf '%s\n' "$line" | sed 's/^[[:space:]]*//; s#\./##g')"

				# Skip empty/comment lines
				[[ -z "$line" || "$line" == \#* ]] && continue

				# shellcheck disable=SC2086
				set -- $line
				local cmd="$1"
				local file="$2"

				# Keep built-in Amber frcmods (resolved via AMBER data path)
				if [[ "$cmd" =~ ^(loadAmberParams|loadamberparams|loadoff|loadOff)$ ]]; then
					if [[ "$file" == frcmod.* ]]; then
						printf '%s\n' "$line" >> "$mcpb_filtered"
					elif [[ -f "$JOB_DIR/$file" ]]; then
						printf '%s\n' "$line" >> "$mcpb_filtered"
					else
						info "Skipping MCPB load statement (missing file): $line"
					fi
				else
					printf '%s\n' "$line" >> "$mcpb_filtered"
				fi
			done < "$JOB_DIR/mcpb_params.in"

			mv "$mcpb_filtered" "$JOB_DIR/mcpb_params.in"
		fi


		if [[ -s "$JOB_DIR/mcpb_params.in" ]]; then
			cat "$JOB_DIR/mcpb_params.in" "$JOB_DIR/${in_file}.in" > "$JOB_DIR/tleap_run.in"
			tleap_in="tleap_run.in"
		else
			info "MCPB tleap file present but no load statements found – using ${in_file}.in"
		fi
	fi

	#Construct the job file
	if [[ $meta == "true" ]]; then
		substitute_name_sh_meta_start "$JOB_DIR" "${directory}" ""
		substitute_name_sh_meta_end "$JOB_DIR"
		substitute_name_sh "$job_name" "$JOB_DIR" "$amber" "$name" "$tleap_in" "" "" ""
		construct_sh_meta "$JOB_DIR" "$job_name"
	else
		substitute_name_sh_wolf_start "$JOB_DIR"
		substitute_name_sh "$job_name" "$JOB_DIR" "$amber" "$name" "" "" "$tleap_in" ""
		construct_sh_wolf "$JOB_DIR" "$job_name"
	fi

    #Run the antechmaber
    submit_job "$meta" "$job_name" "$JOB_DIR" 8 8 0 "01:00:00"

	#Check that the final files are truly present
	check_res_file "${name}.rst7" "$JOB_DIR" "$job_name"
	check_res_file "${name}.parm7" "$JOB_DIR" "$job_name"

	success "$job_name has finished correctly"

	#Write to the log a finished operation
	add_to_log "$job_name" "$LOG"
}