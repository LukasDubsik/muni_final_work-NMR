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


# run_mcpb NAME DIRECTORY META AMBER
# Runs MCPB.py metal-center parametrization and merges the resulting frcmod
# into the standard parmchk2 frcmod.
# Globals: mcpb_cmd
# Returns: Nothing
# run_mcpb NAME DIRECTORY META AMBER IN_MOL2 LIG_FRCMOD
run_mcpb()
{
    # Get the name of the system
    local name="$1"
    # Get the main directory
    local directory="$2"
    # Get the amber module to load
    local amber="$3"
    # Unused (kept for API compatibility)
    local pdb2pqr="$4"
    # The extra cmd flags for MCPB.py (e.g. "-s 4")
    local mcpb_cmd="$5"

    # Setup the directory to store the results and logs
    local out_dir="$directory/process/preparations/mcpb"
    local in_dir="$directory/process/preparations/parmchk2"

    # Inputs we rely on (already produced earlier in the pipeline)
    local src_mol2="$in_dir/${name}_charges.mol2"
    local src_frcmod="$in_dir/${name}.frcmod"

	local job_name="mcpb"

    info "Started running $job_name"

    # Create/clean the job dir
    prepare_job_dir "$out_dir"

    # Sanity checks
    [[ -f "$src_mol2" ]] || die "mcpb: Missing source mol2: $src_mol2"
    [[ -f "$src_frcmod" ]] || die "mcpb: Missing parmchk2 frcmod: $src_frcmod"

    # Copy ligand inputs into MCPB dir (these names match what MCPB expects)
    cp -f "$src_mol2" "$out_dir/LIG.mol2" || die "mcpb: Failed copying mol2 to LIG.mol2"
    cp -f "$src_frcmod" "$out_dir/LIG.frcmod" || die "mcpb: Failed copying frcmod to LIG.frcmod"

    # Also keep the original mol2 around for debugging/repro
    cp -f "$src_mol2" "$out_dir/${name}_mcpb_source.mol2" || die "mcpb: Failed copying source mol2"

    # Detect the first heavy metal atom (id + coords + element) from the MOL2
    # Output: "<id> <x> <y> <z> <elem>"
    local ion_line ion_id ion_x ion_y ion_z ion_el
    ion_line="$(
        awk '
        function elem_from(n,t, e){
            e=t
            gsub(/[^A-Za-z]/,"",e)
            if (e=="") { e=n; gsub(/[^A-Za-z]/,"",e) }
            if (length(e)>=2) return toupper(substr(e,1,1)) tolower(substr(e,2,1))
            return toupper(substr(e,1,1))
        }
        BEGIN{inatom=0}
        /^@<TRIPOS>ATOM/{inatom=1; next}
        /^@<TRIPOS>BOND/{inatom=0}
        inatom{
            el=elem_from($2,$6)
            u=toupper(el)
            # Extend this list if you need more metals
            if (u=="AU" || u=="HG" || u=="PT" || u=="PD" || u=="AG" || u=="CU" || u=="ZN" || u=="FE" || u=="NI" || u=="CO" || u=="MN") {
                printf "%s %s %s %s %s\n", $1, $3, $4, $5, el
                exit
            }
        }' "$src_mol2"
    )"

    [[ -n "$ion_line" ]] || die "mcpb: Heavy metal not detected in $src_mol2 (but pipeline tried to run MCPB)."

    read -r ion_id ion_x ion_y ion_z ion_el <<< "$ion_line"

    # Create the ion mol2 file required by MCPB (e.g., AU.mol2)
    # Keep filename exactly as MCPB expects (uppercased element).
    local ion_mol2="${ion_el^^}.mol2"
    cat > "$out_dir/$ion_mol2" <<EOF
@<TRIPOS>MOLECULE
${ion_el^^}
 1 0 0 0 0
SMALL
USER_CHARGES

@<TRIPOS>ATOM
1 ${ion_el^^}   ${ion_x} ${ion_y} ${ion_z} ${ion_el^^} 1 ${ion_el^^} 0.0000

@<TRIPOS>SUBSTRUCTURE
1 ${ion_el^^} 1 TEMP 0 **** 0 **** 0
EOF

    # Build a simple PDB from MOL2 (no external tools required)
    # MCPB mainly needs consistent atom serials + coordinates.
    awk '
    function elem_from(n,t, e){
        e=t
        gsub(/[^A-Za-z]/,"",e)
        if (e=="") { e=n; gsub(/[^A-Za-z]/,"",e) }
        if (length(e)>=2) return toupper(substr(e,1,1)) tolower(substr(e,2,1))
        return toupper(substr(e,1,1))
    }
    BEGIN{inatom=0}
    /^@<TRIPOS>ATOM/{inatom=1; next}
    /^@<TRIPOS>BOND/{inatom=0; print "TER"; print "END"; exit}
    inatom{
        id=$1; an=$2; x=$3; y=$4; z=$5; el=elem_from($2,$6)
        printf "ATOM  %5d %-4s LIG A%4d    %8.3f%8.3f%8.3f  1.00  0.00          %-2s\n", id, substr(an,1,4), 1, x, y, z, el
    }
    END{ if (inatom==1) { print "TER"; print "END" } }
    ' "$src_mol2" > "$out_dir/${name}_mcpb.pdb" || die "mcpb: Failed generating PDB from MOL2"

    # Generate the MCPB input file (general, driven by NAME/DIRECTORY substitutions)
    # IMPORTANT: step 4 needs NAME_standard.fingerprint, so the job will run 1->4.
    cat > "$out_dir/${name}_mcpb.in" <<EOF
group_name = ${name}
original_pdb = ${name}_mcpb.pdb

# Ions
ion_ids = [${ion_id}]
ion_info = []
ion_mol2files = ['${ion_mol2}']
ion_paraset = 12_6

# Non-standard residues
naa_mol2files = ['LIG.mol2']
frcmod_files = ['LIG.frcmod']
gaff = 1

# General settings
cut_off = 2.8
force_field = ff19SB
water_model = OPC
software_version = gau

# Skip QM/sqm stages (pipeline intent: keep MCPB light and deterministic)
sqm_opt = 0
smmodel_chg = -99
smmodel_spin = -99
lgmodel_chg = -99
lgmodel_spin = -99
EOF

    # Touch jobs_info so the job can append reliably
    : > "$out_dir/jobs_info.txt"

    # Create the job script directly (do NOT rely on the old template; it still runs MCPB.py without -i)
    local amber_mod="${amber#/}"
    cat > "$out_dir/mcpb.sh" <<EOF
#!/bin/bash -l

DATADIR=$out_dir

echo "\$PBS_JOBID is running on node \$(hostname -f) in a scratch directory \$SCRATCHDIR" >> "\$DATADIR/jobs_info.txt"

test -n "\$SCRATCHDIR" || { echo >&2 "Variable SCRATCHDIR is not set!"; exit 1; }

cp \$DATADIR/* \$SCRATCHDIR || { echo >&2 "Error while copying input file(s)!"; exit 2; }

cd \$SCRATCHDIR || { echo >&2 "Failed to cd to SCRATCHDIR"; exit 3; }

module add amber/${amber_mod}

# Run steps 1-3 first so NAME_standard.fingerprint exists for step 4
MCPB.py -i ${name}_mcpb.in -s 1
MCPB.py -i ${name}_mcpb.in -s 2
MCPB.py -i ${name}_mcpb.in -s 3

# Final stage (usually "-s 4" from your config)
MCPB.py -i ${name}_mcpb.in ${mcpb_cmd:-"-s 4"}

echo "The files in the directory at the end" >> "\$DATADIR/jobs_info.txt"
ls >> "\$DATADIR/jobs_info.txt"

cp * \$DATADIR/ || { echo >&2 "Result file(s) copying failed (with a code \$?) !!"; exit 4; }

clean_scratch
EOF

    chmod +x "$out_dir/mcpb.sh"

    # Submit the job
    submit_job "mcpb" "$out_dir/mcpb.sh"

    # Expected outputs from MCPB
    check_result "$out_dir/mcpbpy.frcmod"

    # Create a tleap include file that your main tleap can source
    # (this is what your pipeline is currently checking for)
    if [[ ! -f "$out_dir/${name}_tleap.in" ]]; then
        cat > "$out_dir/${name}_tleap.in" <<'EOF'
# Auto-generated by pipeline (MCPB include)
# Load ligand base params + MCPB metal-center params
loadamberparams DIRECTORY/process/preparations/mcpb/LIG.frcmod
loadamberparams DIRECTORY/process/preparations/mcpb/mcpbpy.frcmod

# If MCPB.py generated/updated MOL2/LIB, these are typically the files you want tleap to use:
# (Uncomment if your main tleap script does NOT already load them.)
# loadoff DIRECTORY/process/preparations/mcpb/LIG.lib
# LIG = loadmol2 DIRECTORY/process/preparations/mcpb/LIG.mol2
EOF
        substitute_name_in "$out_dir/${name}_tleap.in" "$directory" "$name"
    fi

    check_result "$out_dir/${name}_tleap.in"

    log_finished "mcpb"
    set_status "mcpb" true
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
	local mcpb_cmd=$6

	local job_name="parmchk2"

	info "Started running $job_name"

    #Start by converting the input mol into a xyz format -necessary for crest
	JOB_DIR="process/preparations/$job_name"
	ensure_dir $JOB_DIR

	SRC_DIR="process/preparations/antechamber"

	#Copy the data from antechamber
	move_inp_file "${name}_charges.mol2" "$SRC_DIR" "$JOB_DIR"

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
    submit_job "$meta" "$job_name" "$JOB_DIR" 32 32 0 "01:00:00"

	#Check that the final files are truly present
	check_res_file "${name}.frcmod" "$JOB_DIR" "$job_name"

	# Run MCPB.py only if heavy metal is present (needed for metal-center parameters)
    run_mcpb "$name" "$directory" "$meta" "$amber" "$JOB_DIR/${name}_charges.mol2" "$JOB_DIR/${name}.frcmod"

	success "$job_name has finished correctly"

	#Write to the log a finished operation
	add_to_log "$job_name" "$LOG"
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

	#Construct the job file
	if [[ $meta == "true" ]]; then
		substitute_name_sh_meta_start "$JOB_DIR" "${directory}" ""
		substitute_name_sh_meta_end "$JOB_DIR"
		substitute_name_sh "$job_name" "$JOB_DIR" "$amber" "$name" "$in_file.in" "" "" ""
		construct_sh_meta "$JOB_DIR" "$job_name"
	else
		substitute_name_sh_wolf_start "$JOB_DIR"
		substitute_name_sh "$job_name" "$JOB_DIR" "$amber" "$name" "$in_file.in" "" "" ""
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