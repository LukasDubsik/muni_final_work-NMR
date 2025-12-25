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

	local total_charge="$charge"

	# Heavy-metal workflow state (used later after antechamber finishes)
	local heavy_metal="false"
	local complex_mol2=""
	local metal_id=""
	local metal_elem=""

	local job_name="antechamber"

	info "Started running $job_name"

	#Start by converting the input mol into a xyz format -necessary for crest
	JOB_DIR="process/preparations/$job_name"
	ensure_dir "$JOB_DIR"

	SRC_DIR="process/preparations/crest"

	#Copy the data from crest
	move_inp_file "${name}_crest.mol2" "$SRC_DIR" "$JOB_DIR"
	
	local mcpb_needs_full="false"
	local crest_full=""
	local metal_mid=""

	if mol2_has_metal "$JOB_DIR/${name}_crest.mol2"; then
		mcpb_needs_full="true"
		metal_mid="$(mol2_first_metal "$JOB_DIR/${name}_crest.mol2" | awk 'NR==1{print $1}')"
		info "Metal detected (id=${metal_mid}) – stripping metal for antechamber (GAFF2 typing only; charges will come from MCPB.py)."

		# Preserve the original (metal-containing) MOL2 so we can reattach the metal+bonds after typing
		crest_full="$JOB_DIR/${name}_crest_full.mol2"
		cp -f "$JOB_DIR/${name}_crest.mol2" "$crest_full" || die "Failed to preserve full MOL2 for MCPB: $crest_full"

		# Feed antechamber a metal-free ligand MOL2 (GAFF2 typing only)
		local tmp_lig="$JOB_DIR/${name}_crest_ligand_only.mol2"
		mol2_strip_atom "$crest_full" "$tmp_lig" "$metal_mid"
		mv -f "$tmp_lig" "$JOB_DIR/${name}_crest.mol2" || die "Failed to replace antechamber input with metal-stripped ligand MOL2"

		# Ensure antechamber does NOT compute charges for metal systems (MCPB.py will do that).
		# We must prevent AM1-BCC from running sqm. Use -c rc (read charges from input MOL2; your crest MOL2 has 0.0 charges).
		antechamber_parms="$(echo "$antechamber_parms" | sed -E 's/(^|[[:space:]])-c[[:space:]]+[^[:space:]]+//g')"
		antechamber_parms="${antechamber_parms} -c rc"

	fi

	#Constrcut the job file
	if [[ $meta == "true" ]]; then
		substitute_name_sh_meta_start "$JOB_DIR" "${directory}" ""
		substitute_name_sh_meta_end "$JOB_DIR"
		substitute_name_sh "$job_name" "$JOB_DIR" "$amber" "$name" "${name}_crest.mol2" "" "$antechamber_parms" "$charge"
		construct_sh_meta "$JOB_DIR" "$job_name"
	else
		substitute_name_sh_wolf_start "$JOB_DIR"
		substitute_name_sh "$job_name" "$JOB_DIR" "$amber" "$name" "${name}_crest.mol2" "" "$antechamber_parms" "$charge"
		construct_sh_wolf "$JOB_DIR" "$job_name"
	fi

	#Run the antechamber
	submit_job "$meta" "$job_name" "$JOB_DIR" 32 16 0 "8:00:00"

	#Check that the final files are truly present
	check_res_file "${name}_charges.mol2" "$JOB_DIR" "$job_name"

	# For metal systems: rebuild a metal-containing MOL2 for MCPB.py using
	# (1) GAFF-typed ligand from antechamber and (2) metal+bonds from the original MOL2.
	if [[ "$mcpb_needs_full" == "true" ]]; then
		mol2_build_full_with_first_metal "$crest_full" "$JOB_DIR/${name}_charges.mol2" "$JOB_DIR/${name}_charges_full.mol2"
		check_res_file "${name}_charges_full.mol2" "$JOB_DIR" "$job_name"
	fi

	if [[ "$heavy_metal" == "true" ]]; then
		check_res_file "${name}_charges_full.mol2" "$JOB_DIR" "$job_name"
	fi

	# # If we stripped a metal for charge generation, overlay charges back onto the full complex MOL2.
	# if [[ "$heavy_metal" == "true" && -n "${complex_mol2:-}" && -s "$complex_mol2" ]]; then
	# 	local lig_charged="${JOB_DIR}/${name}_charges.mol2"
	# 	local out_complex="${JOB_DIR}/${name}_charges_complex.mol2"
	# 	local out_user="${JOB_DIR}/${name}_charges_complex_user.mol2"

	# 	# Sum ligand charges from the antechamber output (metal-stripped MOL2)
	# 	local lig_net
	# 	lig_net="$(awk 'BEGIN{in_atom=0;sum=0}
	# 		/^@<TRIPOS>ATOM/{in_atom=1;next}
	# 		/^@<TRIPOS>/{if(in_atom){in_atom=0}}
	# 		in_atom && $1~/^[0-9]+$/{sum+=$NF}
	# 		END{printf "%.6f", sum}' "$lig_charged")"

	# 	# Enforce the configured total charge by assigning the metal the residual charge
	# 	local metal_charge
	# 	metal_charge="$(awk -v tot="$total_charge" -v lig="$lig_net" 'BEGIN{printf "%.6f", (tot - lig)}')"

	# 	info "Overlaying ligand charges onto full complex: ligand_net=${lig_net}; total=${total_charge}; metal_charge=${metal_charge}"

	# 	# Apply ligand charges to the full complex and set the metal charge
	# 	mol2_overlay_ligand_charges "$lig_charged" "$complex_mol2" "$out_complex" "$metal_charge"

	# 	# Ensure USER_CHARGES header
	# 	mol2_force_user_charges "$out_complex" "$out_user"

	# 	# Keep the ligand-only charged MOL2 for debugging, and replace final output with the full complex
	# 	mv -f "$lig_charged" "${JOB_DIR}/${name}_ligand_charges.mol2"
	# 	mv -f "$out_user" "${JOB_DIR}/${name}_charges.mol2"
	# 	rm -f "$out_complex" || true

	# 	# Re-check final output after overlay
	# 	check_res_file "${name}_charges.mol2" "$JOB_DIR" "$job_name"
	# fi

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

	# If antechamber built a full (metal-containing) MOL2 for MCPB.py, carry it forward.
	if [[ -f "$SRC_DIR/${name}_charges_full.mol2" ]]; then
		move_inp_file "${name}_charges_full.mol2" "$SRC_DIR" "$JOB_DIR"
	fi

	local full_mol2="$JOB_DIR/${name}_charges.mol2"
	local mcpb_mol2="$JOB_DIR/${name}_charges_full.mol2"

	# If the MOL2 we will feed into parmchk2 still contains a metal, strip it now.
	if mol2_has_metal "$full_mol2"; then
		# Ensure MCPB sees a full MOL2 even if antechamber did not preserve one
		if [[ ! -f "$mcpb_mol2" ]]; then
			cp -f "$full_mol2" "$mcpb_mol2"
		fi

		local metal_id
		metal_id="$(mol2_first_metal "$mcpb_mol2" | awk 'NR==1{print $1}')"

		if [[ -z "$metal_id" || "$metal_id" == "-1" ]]; then
			warning "Metal expected but could not be identified in MOL2; skipping strip. (This may break parmchk2.)"
		else
			info "Metal detected in MOL2 (atom_id=$metal_id). Stripping it for parmchk2 (MCPB will use ${name}_charges_full.mol2)."
			local tmp_strip="$JOB_DIR/${name}_charges_ligand_only.mol2"
			mol2_strip_atom "$mcpb_mol2" "$tmp_strip" "$metal_id"
			mv -f "$tmp_strip" "$full_mol2"
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
	local total_charge="${8:-0}"

	# Optional: cap Gaussian opt cycles for MCPB small model
	local gauss_opt_maxcycle=100

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

	# If the MCPB input MOL2 changed since the last successful run, cached stages
	# must be invalidated; otherwise stale connectivity (e.g., metal bonds) may be reused.
	local in_mol2_sha
	in_mol2_sha="$(sha256sum "$in_mol2" | awk '{print $1}')"
	local MOL2_SHA_FILE="$STAGE1_DIR/.input_mol2.sha256"

	if [[ -f "$STAGE1_OK" && ! -f "$MOL2_SHA_FILE" ]]; then
		warning "MCPB cache is missing input hash; invalidating cached MCPB stages."
		rm -rf "$STAGE1_DIR" "$STAGE2_DIR" "$STAGE3_DIR"
	elif [[ -f "$MOL2_SHA_FILE" ]]; then
		local old_sha
		old_sha="$(cat "$MOL2_SHA_FILE" 2>/dev/null || true)"
		if [[ -n "$old_sha" && "$old_sha" != "$in_mol2_sha" ]]; then
			warning "MCPB input MOL2 changed; invalidating cached MCPB stages."
			rm -rf "$STAGE1_DIR" "$STAGE2_DIR" "$STAGE3_DIR"
		fi
	fi

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
	cp -f "$in_mol2" "$src_mol2" || die "Failed to copy MCPB source MOL2: $in_mol2 -> $src_mol2"
	printf '%s\n' "$in_mol2_sha" > "$MOL2_SHA_FILE" || true

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
	[[ -n "${metal_elem:-}" ]] || die "Failed to parse metal element from MOL2 (mol2_first_metal returned: '$metal_line')"
	metal_charge="${metal_charge:-0.0}"
	metal_elem=$(echo "$metal_elem" | tr '[:lower:]' '[:upper:]')

	# Generate PDB and split MOL2s (only if missing / empty)
	if [[ ! -s "$STAGE1_DIR/${name}_mcpb.pdb" ]]; then
		mol2_to_mcpb_pdb "$src_mol2" "$STAGE1_DIR/${name}_mcpb.pdb" "$metal_id"
	fi
	if [[ ! -s "$STAGE1_DIR/LIG.mol2" ]]; then
		local lig_mol2_src
		lig_mol2_src="$(dirname "$lig_frcmod")/${name}_charges.mol2"

		if [[ -s "$lig_mol2_src" ]]; then
			cp -f "$lig_mol2_src" "$STAGE1_DIR/LIG.mol2" || die "Failed to copy ligand MOL2 for MCPB.py: $lig_mol2_src"
		else
			mol2_strip_atom "$src_mol2" "$STAGE1_DIR/LIG.mol2" "$metal_id"
		fi
	fi

	# Derive a reasonable metal formal charge from total charge and ligand charge sum
	local lig_charge
	lig_charge="$(awk '
		BEGIN{inA=0; s=0}
		/^@<TRIPOS>ATOM/{inA=1; next}
		/^@<TRIPOS>/{if(inA) inA=0}
		inA && NF>=9 { s += $9 }
		END{ printf "%.6f", s }
	' "$STAGE1_DIR/LIG.mol2")"

	local metal_charge_from_total
	metal_charge_from_total="$(awk -v tot="$total_charge" -v lig="$lig_charge" '
		BEGIN{
			v = tot - lig
			# round-to-nearest integer for ion charge handling
			if (v >= 0) printf "%d", int(v + 0.5)
			else        printf "%d", int(v - 0.5)
		}
	')"

	info "Derived metal charge: total=${total_charge}, ligand≈${lig_charge} => metal≈${metal_charge_from_total}"
	metal_charge="$metal_charge_from_total"


	if [[ ! -s "$STAGE1_DIR/${metal_elem}.mol2" ]]; then
		write_single_ion_mol2 "$STAGE1_DIR/${metal_elem}.mol2" "$metal_elem" "$metal_charge" "$mx" "$my" "$mz"
	fi

	# MCPB-specific MOL2 sanitization (residue names, etc.)
	mol2_sanitize_for_mcpb "$STAGE1_DIR/LIG.mol2" "LIG"
	mol2_sanitize_for_mcpb "$STAGE1_DIR/${metal_elem}.mol2" "$metal_elem"

	# Explicitly tell MCPB which atoms are bonded to the metal (critical for e.g. Au–C)
	local bonded_ids
	bonded_ids="$(mol2_bonded_atoms "$src_mol2" "$metal_id")"

	local addbpairs_line=""
	if [[ -n "$bonded_ids" ]]; then
		addbpairs_line="add_bonded_pairs"
		for bid in $bonded_ids; do
			addbpairs_line="$addbpairs_line ${metal_id}-${bid}"
		done
	fi

	# If preserved stages were created without add_bonded_pairs, they are not safe to reuse
	if [[ -f "$STAGE1_OK" && -n "$addbpairs_line" && -f "$STAGE1_DIR/${name}_mcpb.in" ]]; then
		if ! grep -qF "$addbpairs_line" "$STAGE1_DIR/${name}_mcpb.in"; then
			warning "MCPB preserved stages were generated without add_bonded_pairs; invalidating cached MCPB stages."
			rm -f "$STAGE1_OK" "$STAGE2_OK" "$STAGE3_OK"
		fi
	fi

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
	echo "${addbpairs_line}"
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
		cp -f "$STAGE1_DIR/${name}_large_mk.com" "$STAGE2_DIR/" 2>/dev/null || true

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

if [ -f "${NAME}_large_mk.com" ]; then
    run_gaussian "${NAME}_large_mk.com"
    rc_mk=$?
    if ! gauss_ok "${NAME}_large_mk.log"; then
        echo "[ERR] ${NAME}_large_mk did not normally terminate (rc=${rc_mk})."
        JOB_STATUS=3
    fi
else
    rc_mk=0
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

			submit_job "$meta" "$STAGE2_JOB" "$STAGE2_DIR" 32 16 0 "12:00:00"

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

		cp -f "$STAGE1_DIR/${name}_large.pdb" "$STAGE3_DIR/" 2>/dev/null || true
		cp -f "$STAGE2_DIR/${name}_large_mk.log" "$STAGE3_DIR/" 2>/dev/null || true

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
module add g16 2>/dev/null || module add gaussian 2>/dev/null || true

NAME="${name}"
STEP="${mcpb_step}"

# Generate the fchk file
formchk ${name}_small_opt.chk ${name}_small_opt.fchk

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

if [[ ! -s "${NAME}_large.pdb" ]]; then
    echo "[ERR] Missing ${NAME}_large.pdb (required for MCPB.py step 3)."
    exit 2
fi
if [[ ! -s "${NAME}_large_mk.log" ]]; then
    echo "[ERR] Missing ${NAME}_large_mk.log (run Gaussian MK/ESP for the large model)."
    exit 2
fi

if [[ "\$STEP" -ge 3 ]]; then
	echo "[INFO] Running MCPB.py step 3 (charge fitting / charge modification)"
	MCPB.py -i "\${NAME}_mcpb.in" -s 3
fi

# Normalize the MCPB-typed PDB name (required by tleap stage)
if [[ -f "\${NAME}_mcpbpy.pdb" ]]; then
	cp "\${NAME}_mcpbpy.pdb" "\${NAME}_mcpbpy.pdb"
elif [[ -f "\${NAME}.pdb" ]]; then
	# Some MCPB variants overwrite NAME.pdb
	cp "\${NAME}.pdb" "\${NAME}_mcpbpy.pdb"
elif [[ -f "mcpbpy.pdb" ]]; then
	cp "mcpbpy.pdb" "\${NAME}_mcpbpy.pdb"
fi

# Normalize outputs to stable names expected by the rest of your pipeline
if [[ -f "frcmod_\${NAME}" ]]; then
	cp "frcmod_\${NAME}" "\${NAME}_mcpbpy.frcmod"
fi
# Normalize library output (if MCPB produced one)
if [[ -f "\${NAME}.lib" ]]; then
	cp "\${NAME}.lib" "\${NAME}_mcpbpy.lib"
elif [[ -f "mcpbpy.lib" ]]; then
	cp "mcpbpy.lib" "\${NAME}_mcpbpy.lib"
else
	lib_any="\$(ls -1 *.lib 2>/dev/null | head -n 1 || true)"
	if [[ -n "\$lib_any" ]]; then
		cp "\$lib_any" "\${NAME}_mcpbpy.lib"
	fi
fi

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

			# MCPB does NOT always produce a .lib (especially if you are not doing charge fitting via step 3).
			# Charges can also come from MOL2; do not hard-fail here.
			if [[ -f "${STAGE3_DIR}/${name}_mcpbpy.lib" ]]; then
				success "MCPB library found: ${STAGE3_DIR}/${name}_mcpbpy.lib"
			else
				warning "MCPB library missing (${name}_mcpbpy.lib). Continuing: tleap will rely on MOL2 charges instead."
			fi

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

		# Copy MCPB outputs into tleap job dir
		cp "${MCPB_DIR}"/*.{frcmod,lib,off,dat,mol2,pdb} "$JOB_DIR" 2>/dev/null || true

		local mcpb_tleap_in="${MCPB_DIR}/${name}_tleap.in"
		local mcpb_params_in="$JOB_DIR/mcpb_params.in"
		local mcpb_params_ok="$JOB_DIR/mcpb_params.ok.in"

		# Extract only MCPB load statements (including "VAR = loadmol2 file.mol2" forms)
		grep -E '^[[:space:]]*([[:alnum:]_]+[[:space:]]*=[[:space:]]*)?(loadAmberParams|loadamberparams|loadoff|loadOff|loadMol2|loadmol2|loadPdb|loadpdb)[[:space:]]+' \
			"$mcpb_tleap_in" \
			| tr -d '\r' \
			| sed -E 's/^[[:space:]]+//; s#[[:space:]]+$##; s#\./##g' \
			> "$mcpb_params_in" || true

		# Resolve/validate referenced files; never keep a loadPdb unless templates are present
		local missing_templates="false"
		local have_mcpb_lib="false"
		if [[ -f "$MCPB_DIR/${name}.lib" || -f "$MCPB_DIR/${name}_mcpbpy.lib" || -f "$MCPB_DIR/${name}.off" || -f "$MCPB_DIR/${name}_mcpbpy.off" ]]; then
			have_mcpb_lib="true"
		fi

		: > "$mcpb_params_ok"

		while IFS= read -r line; do
			[[ -z "$line" ]] && continue

			local cmd="" file=""
			if [[ "$line" =~ ^[[:alnum:]_]+[[:space:]]*=[[:space:]]*(loadMol2|loadmol2|loadPdb|loadpdb)[[:space:]]+([^[:space:]]+) ]]; then
				cmd="${BASH_REMATCH[1]}"
				file="${BASH_REMATCH[2]}"
			elif [[ "$line" =~ ^(loadAmberParams|loadamberparams|loadoff|loadOff|loadMol2|loadmol2|loadPdb|loadpdb)[[:space:]]+([^[:space:]]+) ]]; then
				cmd="${BASH_REMATCH[1]}"
				file="${BASH_REMATCH[2]}"
			else
				continue
			fi

			# strip quotes if present
			file="${file#\"}"; file="${file%\"}"
			file="${file#\'}"; file="${file%\'}"

			local base="${file##*/}"
			base="${base#./}"

			# If we have a MCPB library/off file, do NOT load AU*/LG* MOL2 templates:
			# they may carry placeholder charges and can override RESP charges from the lib.
			if [[ "$have_mcpb_lib" == "true" && "$cmd" =~ ^(loadMol2|loadmol2)$ && "$base" =~ ^(AU[0-9]+|LG[0-9]+)[.]mol2$ ]]; then
				info "Skipping MCPB MOL2 template (RESP charges will come from lib/off): $base"
				continue
			fi

			# If a referenced MOL2 exists but is malformed, remove it so we regenerate it.
			if [[ -f "$JOB_DIR/$base" && "$base" == *.mol2 ]]; then
				if ! mol2_quick_validate_for_tleap "$JOB_DIR/$base"; then
					warning "MCPB template appears malformed (will regenerate): $base"
					rm -f "$JOB_DIR/$base"
				fi
			fi

			# Built-in frcmod.* is searched in AMBER paths; keep even if not local
			if [[ "$cmd" =~ ^(loadAmberParams|loadamberparams)$ && "$base" == frcmod.* ]]; then
				printf '%s\n' "$line" >> "$mcpb_params_ok"
				continue
			fi

			# Absolute path: keep as-is
			if [[ "$file" == /* ]]; then
				printf '%s\n' "$line" >> "$mcpb_params_ok"
				continue
			fi

			# If file exists in MCPB dir but not in job dir, copy it
			if [[ ! -f "$JOB_DIR/$base" && -f "$MCPB_DIR/$base" ]]; then
				cp -f "$MCPB_DIR/$base" "$JOB_DIR/" 2>/dev/null || true
			fi

			# Derive common MCPB naming mismatches (LG1/AU1) from available sources
			if [[ ! -f "$JOB_DIR/$base" ]]; then
				if [[ "$base" =~ ^LG[0-9]+[.]mol2$ ]]; then
					# Prefer regenerating from the current post-processed MOL2 (more reliable than stale MCPB LIG.mol2)
					if [[ -f "$JOB_DIR/${name}_charges_fix.mol2" ]]; then
						local mid
						mid="$(mol2_first_metal "$JOB_DIR/${name}_charges_fix.mol2" | awk 'NR==1{print $1}')"
						if [[ -n "$mid" && "$mid" != "-1" ]]; then
							mol2_strip_atom "$JOB_DIR/${name}_charges_fix.mol2" "$JOB_DIR/$base" "$mid"
						else
							cp -f "$JOB_DIR/${name}_charges_fix.mol2" "$JOB_DIR/$base"
						fi
					elif [[ -f "$JOB_DIR/LIG.mol2" ]]; then
						cp -f "$JOB_DIR/LIG.mol2" "$JOB_DIR/$base"
					fi

					if [[ -f "$JOB_DIR/$base" ]]; then
						mol2_sanitize_for_mcpb "$JOB_DIR/$base" "${base%.mol2}"
						info "Derived missing MCPB template: $base <- ${name}_charges_fix.mol2/LIG.mol2"
					fi

				elif [[ "$base" =~ ^AU[0-9]+[.]mol2$ ]]; then
					# Prefer MCPB AU.mol2 if present; otherwise regenerate as a single-ion MOL2
					if [[ -f "$JOB_DIR/AU.mol2" ]]; then
						cp -f "$JOB_DIR/AU.mol2" "$JOB_DIR/$base"
						mol2_sanitize_for_mcpb "$JOB_DIR/$base" "${base%.mol2}"
						info "Derived missing MCPB template: $base <- AU.mol2"
					elif [[ -f "$JOB_DIR/${name}_charges_fix.mol2" ]]; then
						local meta mid elem q x y z
						meta="$(mol2_first_metal "$JOB_DIR/${name}_charges_fix.mol2" | head -n1)"
						mid="$(awk '{print $1}' <<<"$meta")"
						elem="$(awk '{print $2}' <<<"$meta")"
						q="$(awk '{print $3}' <<<"$meta")"
						x="$(awk '{print $4}' <<<"$meta")"
						y="$(awk '{print $5}' <<<"$meta")"
						z="$(awk '{print $6}' <<<"$meta")"

						if [[ -n "$mid" && "$mid" != "-1" ]]; then
							write_single_ion_mol2 "$JOB_DIR/$base" "$elem" "$q" "$x" "$y" "$z"
							mol2_sanitize_for_mcpb "$JOB_DIR/$base" "${base%.mol2}"
							info "Derived missing MCPB template: $base <- ${name}_charges_fix.mol2 (single-ion)"
						fi
					fi

				elif [[ "$base" == "${name}_mcpbpy.pdb" && -f "$MCPB_DIR/${name}_mcpbpy.pdb" ]]; then
					cp -f "$MCPB_DIR/${name}_mcpbpy.pdb" "$JOB_DIR/" 2>/dev/null || true
				fi
			fi

			# MCPB.py frcmod uses M1 as the metal atom type.
			# Ensure AU*.mol2 residue templates use M1 so teLeap can match MASS/NONB parameters.
			if [[ "$base" =~ ^AU[0-9]+[.]mol2$ && -f "$JOB_DIR/$base" ]]; then
				mol2_force_atom_type_inplace "$JOB_DIR/$base" "M1"
			fi

			# Final safety: if we produced a MOL2 template, validate it before keeping loadMol2
			if [[ -f "$JOB_DIR/$base" && "$base" == *.mol2 ]]; then
				if ! mol2_quick_validate_for_tleap "$JOB_DIR/$base"; then
					warning "Template still malformed after derivation (will be treated as missing): $base"
					rm -f "$JOB_DIR/$base"
				fi
			fi


			# If still missing:
			if [[ ! -f "$JOB_DIR/$base" ]]; then
				# If RESP lib/off is present, missing AU*/LG* MOL2 templates are not fatal.
				if [[ "$have_mcpb_lib" == "true" && "$cmd" =~ ^(loadMol2|loadmol2)$ && "$base" =~ ^(AU[0-9]+|LG[0-9]+)[.]mol2$ ]]; then
					info "Ignoring missing MCPB MOL2 template (RESP lib/off will define residues): $base"
					continue
				fi

				# Missing template => cannot safely load MCPB PDB
				if [[ "$cmd" =~ ^(loadMol2|loadmol2)$ ]]; then
					missing_templates="true"
				fi
				warning "Skipping MCPB load statement (missing file): ${line}"
				continue
			fi

			# If templates are missing, do NOT keep loadPdb lines (prevents 'no type' fatal)
			if [[ "$cmd" =~ ^(loadPdb|loadpdb)$ && "$missing_templates" == "true" ]]; then
				warning "Skipping MCPB PDB load (templates missing earlier): ${line}"
				continue
			fi

			printf '%s\n' "$line" >> "$mcpb_params_ok"
		done < "$mcpb_params_in"

		local MCPB_FRCMOD="$MCPB_DIR/${name}_mcpbpy.frcmod"
		if [[ -f "$MCPB_FRCMOD" ]]; then
			cp -f "$MCPB_FRCMOD" "$JOB_DIR/${name}_mcpbpy.frcmod"
			# MCPB.py typically drives LEaP via *_tleap.in and residue mol2 files.
			# Copy all mol2/frcmod generated by MCPB so the input script can resolve them.
			cp -f "$MCPB_DIR"/*.mol2 "$JOB_DIR/" 2>/dev/null || true
			cp -f "$MCPB_DIR"/*.frcmod "$JOB_DIR/" 2>/dev/null || true

			# If MCPB PDB is preserved in the prepended MCPB lines, we must use it as SYS.
			# Otherwise teLeap will pick up Au/cl/cc atom types from ${name}_charges_fix.mol2 and fail.
			local have_mcpb_pdb="false"
			if grep -qiE "load[Pp]db[[:space:]]+.*${name}_mcpbpy[.]pdb" "$mcpb_params_ok"; then
				have_mcpb_pdb="true"
			fi

			if [[ "$missing_templates" == "false" && "$have_mcpb_pdb" == "true" ]]; then
				info "Detected MCPB output – using MCPB PDB as the solute (do not load ${name}_charges_fix.mol2 as SYS)"

				# Ensure RESP library is loaded before the MCPB PDB.
				local lib_base=""
				if [[ -f "$JOB_DIR/${name}_mcpbpy.lib" ]]; then
					lib_base="${name}_mcpbpy.lib"
				elif [[ -f "$JOB_DIR/${name}.lib" ]]; then
					lib_base="${name}.lib"
				fi

				if [[ -n "$lib_base" ]]; then
					if ! grep -qiE "^[[:space:]]*loadoff[[:space:]]+${lib_base}\\b" "$mcpb_params_ok"; then
						# Insert loadoff immediately before the MCPB PDB load (order matters).
						sed -i -E "/load[Pp]db[[:space:]]+.*${name}_mcpbpy[.]pdb/i\\loadoff ${lib_base}" "$mcpb_params_ok"
					fi
				else
					warning "MCPB PDB detected but no MCPB lib/off found; charges may not be RESP/QM-derived."
				fi

				# Try to reuse the unit variable from MCPB tleap lines (e.g., mol = loadpdb ...).
				local pdb_var=""
				pdb_var="$(
					grep -Ei "^[[:alnum:]_]+[[:space:]]*=[[:space:]]*load[Pp]db[[:space:]]+.*${name}_mcpbpy[.]pdb" \
						"$mcpb_params_ok" | head -n1 | sed -E 's/[[:space:]]*=.*$//'
				)"

				local sys_var="mol"
				if [[ -n "$pdb_var" ]]; then
					sys_var="$pdb_var"
				fi

				# Replace any SYS loadMol2 of the post-processed MOL2 with the MCPB PDB unit.
				if [[ -n "$pdb_var" ]]; then
					sed -i -E \
						"s#^[[:space:]]*SYS[[:space:]]*=[[:space:]]*load[Mm]ol2[[:space:]]+(\\.|\\./)?${name}_charges_fix[.]mol2#SYS = ${pdb_var}#g" \
						"$JOB_DIR/${in_file}.in"

					sed -i -E \
						"s#^[[:space:]]*[[:alnum:]_]+[[:space:]]*=[[:space:]]*load[Mm]ol2[[:space:]]+(\\.|\\./)?${name}_charges_fix[.]mol2#SYS = ${pdb_var}#g" \
						"$JOB_DIR/${in_file}.in"
				else
					# No variable assignment in MCPB lines => safely reload and assign here.
					sed -i -E \
						"s#^[[:space:]]*SYS[[:space:]]*=[[:space:]]*load[Mm]ol2[[:space:]]+(\\.|\\./)?${name}_charges_fix[.]mol2#SYS = loadPdb ${name}_mcpbpy.pdb#g" \
						"$JOB_DIR/${in_file}.in"

					sed -i -E \
						"s#^[[:space:]]*[[:alnum:]_]+[[:space:]]*=[[:space:]]*load[Mm]ol2[[:space:]]+(\\.|\\./)?${name}_charges_fix[.]mol2#SYS = loadPdb ${name}_mcpbpy.pdb#g" \
						"$JOB_DIR/${in_file}.in"
				fi

				# Remove any remaining bare loadMol2 calls of ${name}_charges_fix.mol2 (prevents accidental overwrite)
				sed -i "/load[Mm]ol2[[:space:]]\+\(\.\?\/\)\?${name}_charges_fix[.]mol2/d" "$JOB_DIR/${in_file}.in"

				# 2) If MCPB used a variable assignment (e.g., mol = loadpdb ...), prefer it
				#    Otherwise just refer to 'mol' (your MCPB line is 'mol = loadpdb ...' as shown by grep)
				sed -i "/load[Pp]db[[:space:]]\+${name}_mcpbpy[.]pdb/a\\SYS = ${sys_var}" "$JOB_DIR/${in_file}.in"

			else
				info "Detected MCPB output – templates/PDB not usable; falling back to typed MOL2"

				# Create a typed MOL2: metal -> M1, coordinated halide(s) -> Y1
				local src_mol2_for_tleap="$JOB_DIR/${name}_charges_fix.mol2"
				local dst_mol2_for_tleap="$JOB_DIR/${name}_mcpbtypes.mol2"

				local mid
				mid="$(mol2_first_metal "$src_mol2_for_tleap" | awk 'NR==1{print $1}')"

				if [[ -z "$mid" || "$mid" == "-1" ]]; then
					warning "Could not detect metal in ${name}_charges_fix.mol2; MCPB typing will not be applied."
				else
					local bonded
					bonded="$(mol2_bonded_atoms "$src_mol2_for_tleap" "$mid")"

					local halide_ids=()
					for bid in $bonded; do
						if mol2_atom_is_halide_by_id "$src_mol2_for_tleap" "$bid"; then
							halide_ids+=("$bid")
						fi
					done

					mol2_write_mcpb_typed_mol2 "$src_mol2_for_tleap" "$dst_mol2_for_tleap" "$mid" "$name" "${halide_ids[@]}"

					sed -i -E \
						"s#load[Mm]ol2[[:space:]]+(\\./)?${name}_charges_fix[.]mol2#loadMol2 ${name}_mcpbtypes.mol2#g" \
						"$JOB_DIR/${in_file}.in"
				fi
			fi

			# Ensure MCPB frcmod is loaded (insert after your ligand frcmod load).
			# Check BOTH the main input and the prepended MCPB lines to avoid duplicates.
			if ! grep -qiE "\\b(loadAmberParams|loadamberparams)[[:space:]]+${name}_mcpbpy[.]frcmod\\b" "$JOB_DIR/${in_file}.in" "$mcpb_params_ok"; then
				sed -i -E \
					"/\\b(loadAmberParams|loadamberparams)[[:space:]]+${name}[.]frcmod\\b/a\\loadamberparams ${name}_mcpbpy.frcmod" \
					"$JOB_DIR/${in_file}.in"
			fi
		fi

		# Prepend MCPB params into tleap script
		cat "$mcpb_params_ok" "$JOB_DIR/${in_file}.in" > "$JOB_DIR/tleap_run.in"
	else
		cp "$JOB_DIR/${in_file}.in" "$JOB_DIR/tleap_run.in"
	fi

	cp -f "$JOB_DIR/tleap_run.in" "$JOB_DIR/${in_file}.in"

	# -----------------------------------------------------------------
	# Sanitize tleap input: remove CRLF, strip inline comments, and remove
	# any control characters / malformed check/charge fragments that break
	# tleap's parser.
	# -----------------------------------------------------------------
	sed -i -E 's/\r$//' "$JOB_DIR/$tleap_in"
	sed -i -E '/^[[:space:]]*#/! s/[[:space:]]+#.*$//' "$JOB_DIR/$tleap_in"

	# Remove ASCII control chars except TAB and NL (fixes literal ^H, etc.)
	perl -pi -e 's/[\x00-\x08\x0b\x0c\x0e-\x1f]//g' "$JOB_DIR/$tleap_in"

	# Drop any (possibly corrupted) check/charge lines
	sed -i -E '/^[[:space:]]*(check|charge|eck|arge)[[:space:]]+SYS([[:space:]]|$)/Id' "$JOB_DIR/$tleap_in"


	# -----------------------------------------------------------------
	# Ensure SYS is defined as a UNIT before solvateBox/addIons/saveAmberParm.
	# When SYS is undefined, teLeap treats it as a String and solvateBox fails:
	#   "solvateBox: Argument #1 is type String must be of type: [unit]"
	# -----------------------------------------------------------------
	if grep -qiE '^[[:space:]]*solvatebox[[:space:]]+SYS\\b' "$JOB_DIR/$tleap_in"; then
		if ! grep -qiE '^[[:space:]]*SYS[[:space:]]*=' "$JOB_DIR/$tleap_in"; then
			local sys_var=""
			sys_var="$(
				grep -Ei "^[[:alnum:]_]+[[:space:]]*=[[:space:]]*load[Pp]db[[:space:]]+.*${name}_mcpbpy[.]pdb\\b" \
					"$JOB_DIR/$tleap_in" \
				| head -n1 \
				| sed -E 's/[[:space:]]*=.*$//'
			)"

			# MCPB usually uses: mol = loadpdb <name>_mcpbpy.pdb
			[[ -n "$sys_var" ]] || sys_var="mol"

			# Insert SYS right after the MCPB PDB load line (so sys_var exists)
			sed -i -E "/load[Pp]db[[:space:]]+${name}_mcpbpy[.]pdb\\b/a\\SYS = ${sys_var}" "$JOB_DIR/$tleap_in"
		fi
	fi

	# -----------------------------------------------------------------
	# teLeap sometimes fails to locate frcmod.gaff2 in certain installs.
	# If your leaprc (or MCPB-derived load lines) requests it, ensure a local copy exists.
	# Prefer the real file if it is present in the Amber installation; otherwise create a safe stub.
	# -----------------------------------------------------------------
	if grep -qiE '\bfrcmod\.gaff2\b' "$JOB_DIR/$tleap_in" "$JOB_DIR/leaprc.zf" "$JOB_DIR/mcpb_params.in" 2>/dev/null; then
		if [[ ! -f "$JOB_DIR/frcmod.gaff2" ]]; then
			if [[ -r "/software/amber-22/v1/dat/leap/parm/frcmod.gaff2" ]]; then
				cp -f "/software/amber-22/v1/dat/leap/parm/frcmod.gaff2" "$JOB_DIR/frcmod.gaff2"
			else
				cat > "$JOB_DIR/frcmod.gaff2" <<'EOF'
remark stub frcmod.gaff2 (cluster install did not provide it)
MASS

BOND

ANGLE

DIHE

IMPROPER

NONBON

EOF
			fi
		fi
	fi

	# -----------------------------------------------------------------
	# Normalize teLeap script:
	#   - teLeap 'check'/'charge' must operate on a UNIT (SYS), not a string
	#     (e.g., MOL2 "MOLECULE name" or a quoted token), otherwise teLeap
	#     throws: "Argument #1 is type String must be of type: [unit ...]".
	# -----------------------------------------------------------------
	# Remove any existing check/charge lines (templates sometimes emit them as strings)
	sed -i -E '/^[[:space:]]*(check|charge)[[:space:]]+/Id' "$JOB_DIR/$tleap_in"

	# Re-insert check/charge right after SYS is defined (only if SYS exists)
	# if grep -qiE '^[[:space:]]*SYS[[:space:]]*=' "$JOB_DIR/$tleap_in"; then
	# 	# Insert charge first, then check, so final order is:
	# 	#   SYS = ...
	# 	#   check SYS
	# 	#   charge SYS
	# 	#sed -i -E '/^[[:space:]]*SYS[[:space:]]*=/a\\charge SYS' "$JOB_DIR/$tleap_in"
	# 	#sed -i -E '/^[[:space:]]*SYS[[:space:]]*=/a\\check SYS' "$JOB_DIR/$tleap_in"
	# fi

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