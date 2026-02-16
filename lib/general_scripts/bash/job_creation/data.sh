# shellcheck disable=SC2148
# Guard so we don't load twice
[[ ${_DATA_SH_LOADED:-0} -eq 1 ]] && return
_DATA_SH_LOADED=1

# run_analysis SIGMA LIMIT
# Analyze the results from the gauss nmr run and get necessary data
# Globals: none
# Returns: Nothing
run_analysis() {
	#Load the inputs
	local sigma=$1
	local limit=$2

	local job_name="analysis"

	info "Started running $job_name"

    #Start by converting the input mol into a xyz format -necessary for crest
	JOB_DIR="process/spectrum/$job_name"
	ensure_dir $JOB_DIR

	local ok="$JOB_DIR/.ok"
	if [[ -f "$ok" ]]; then
		if [[ -s "$JOB_DIR/avg.dat" && -s "$JOB_DIR/all_peaks.dat" ]]; then
			info "$job_name already complete; skipping"
			return 0
		else
			rm -f "$ok"
		fi
	fi

	SRC_DIR_1="lib/general_scripts/bash/general"
	SRC_DIR_2="lib/general_scripts/awk"
	SRC_DIR_3="process/spectrum/gaussian/nmr"

	substitute_name_sh_data "general/log_to_plot.sh" "$JOB_DIR/log_to_plot.sh" "" "$limit" "$sigma" ""
	move_inp_file "average_plot.sh" "$SRC_DIR_1" "$JOB_DIR"
	move_inp_file "gjf_to_plot.awk" "$SRC_DIR_2" "$JOB_DIR"

	ensure_dir $JOB_DIR/plots

	#Copy the log files from gaussian runs
	cp -r $SRC_DIR_3 $JOB_DIR
 
		# Move to the directory to run the scripts
	cd $JOB_DIR || die "Couldn'r enter the $JOB_DIR"

	#############################################
	# TMS reference: compute SIGMA_TMS (absolute shielding)
	# If user passed sigma explicitly, keep it. If sigma is "auto" or empty => compute via Gaussian(TMS).
	#############################################
	if [[ -z "${sigma:-}" || "${sigma}" == "auto" ]]; then
		local tms_dir="tms_ref"
		local tms_job="${tms_dir}/job_tms"
		local tms_log="${tms_dir}/frame_tms.log"
		local tms_ref_out="nmr/tms.log"

		local mem_gb=8
		local ncpus=8

		ensure_dir "$tms_dir"
		ensure_dir "$tms_job"
		ensure_dir "nmr"

		# If we already have a valid cached reference log in this analysis dir, reuse it
		if gaussian_log_ok "$tms_ref_out"; then
			info "TMS reference already present; reusing $tms_ref_out"
		else
			info "Creating and running Gaussian TMS reference job (to compute SIGMA_TMS)"

			# Clean any previous failed attempt
			rm -f "$tms_job/frame_tms.gjf" "$tms_job/frame_tms.log" "$tms_job/.jobid" 2>/dev/null || true

			# Build TMS Gaussian input (Opt + NMR) with COSMO, consistent with your solute settings
			# Geometry from NIST CCCBDB cartesian coordinates :contentReference[oaicite:2]{index=2}
			cat > "$tms_job/frame_tms.gjf" <<'EOF'
%chk=tms.chk
#P B3LYP/6-31++G(d,p) Opt SCRF=COSMO SCF=(XQC,Tight) Int=UltraFine

TMS reference (Opt, COSMO)

0 1
Si   0.0000   0.0000   0.0000
C    1.0825   1.0825   1.0825
C   -1.0825  -1.0825   1.0825
C   -1.0825   1.0825  -1.0825
C    1.0825  -1.0825  -1.0825
H    1.7241   0.4345   1.7241
H    1.7241   1.7241   0.4345
H    0.4345   1.7241   1.7241
H   -1.7241  -1.7241   0.4345
H   -0.4345  -1.7241   1.7241
H   -1.7241  -0.4345   1.7241
H   -1.7241   0.4345  -1.7241
H   -1.7241   1.7241  -0.4345
H   -0.4345   1.7241  -1.7241
H    1.7241  -1.7241  -0.4345
H    0.4345  -1.7241  -1.7241
H    1.7241  -0.4345  -1.7241

--Link1--
%chk=tms.chk
#P B3LYP/6-31++G(d,p) NMR=GIAO SCRF=COSMO Geom=AllCheck Guess=Read SCFX=(QC,Tight) Int=UltraFine CPHF=Grid=UltraFine

TMS reference (NMR, COSMO)

0 1
EOF

			# Make sure gaussian input resource lines match allocation
			patch_gaussian_link0_resources "$tms_job/frame_tms.gjf" "$mem_gb" "$ncpus"

			# If on MetaCentrum: reserve scratch + require g16 license just like your main gaussian stage
			local old_extra="${JOB_META_SELECT_EXTRA:-}"
			if [[ "${meta:-false}" == "true" ]]; then
				JOB_META_SELECT_EXTRA="host_licenses=g16:scratch_local=10gb"
			fi

			# Build and submit the job using the SAME gaussian job-template machinery you already use,
			# but with num="tms" so the template runs frame_tms.gjf -> frame_tms.log.
			if [[ "${meta:-false}" == "true" ]]; then
				substitute_name_sh_meta_start "$tms_job" "${directory}" ""
				substitute_name_sh_meta_end "$tms_job"
				substitute_name_sh "gaussian" "$tms_job" "${gaussian}" "tms_ref" "" "tms" "" ""
				construct_sh_meta "$tms_job" "gaussian"
			else
				substitute_name_sh_wolf_start "$tms_job"
				substitute_name_sh "gaussian" "$tms_job" "${gaussian}" "tms_ref" "" "tms" "" ""
				construct_sh_wolf "$tms_job" "gaussian"
			fi

			# Submit + wait
			submit_job "${meta:-false}" "gaussian" "$tms_job" "$mem_gb" "$ncpus" 0 "01:00:00"

			local jid=""
			jid=$(head -n 1 "$tms_job/.jobid" 2>/dev/null || true)
			[[ -n "$jid" ]] || die "TMS reference: submission did not produce a jobid"

			wait_job "$jid"

			# Validate and cache into nmr/tms.log
			gaussian_log_ok "$tms_log" || die "TMS reference Gaussian did not finish normally: $tms_log"
			cp "$tms_log" "$tms_ref_out"

			# Restore scheduler extras
			if [[ "${meta:-false}" == "true" ]]; then
				JOB_META_SELECT_EXTRA="$old_extra"
			fi
		fi

		# Extract σ(TMS) from the reference log (first H isotropic shielding in the NMR block)
		# Gaussian prints "Magnetic shielding tensor ... H Isotropic = ..." :contentReference[oaicite:3]{index=3}
		sigma=$(
			awk '
			/Magnetic shielding tensor/ {inblock=1}
			inblock && /Isotropic/ {
				line=$0
				gsub(/Isotropic=/,"Isotropic =",line)
				n=split(line,a,/[[:space:]]+/)
				# Expected:  <idx> <elem> Isotropic = <value>
				for (i=1;i<=n-4;i++) {
					if (a[i] ~ /^[0-9]+$/ && a[i+1]=="H" && a[i+2]=="Isotropic") {
						v = (a[i+3]=="="?a[i+4]:a[i+3])
						gsub(/[dD]/,"E",v)
						print v
						exit
					}
				}
			}
			inblock && /^$/ {inblock=0}
			' "$tms_ref_out"
		)
		[[ -n "$sigma" ]] || die "Failed to parse SIGMA_TMS from $tms_ref_out"
		info "Computed SIGMA_TMS (TMS reference) = $sigma ppm"
	fi

	# Run the script and average the resulting nmr spectra (export global reference!)
	SIGMA_TMS="$sigma" bash log_to_plot.sh

	#Return back
	cd ../../.. || die "Couldn't back to the main directory"

	#Check that the final files are truly present
	check_res_file "avg.dat" "$JOB_DIR" "$job_name"
	check_res_file "all_peaks.dat" "$JOB_DIR" "$job_name"

	success "$job_name has finished correctly"
	mark_step_ok "$JOB_DIR"

}

# run_plotting
# Given the results from analysis of the gaussian runs plot the resulting nmr spectra
# Globals: none
# Returns: Nothing
run_plotting() {
	#Load the inputs
	local name=$1
	local save_as=$2
	local filter=$3

	local job_name="plotting"

	info "Started running $job_name"

    #Start by converting the input mol into a xyz format -necessary for crest
	JOB_DIR="process/spectrum/$job_name"
	ensure_dir $JOB_DIR

	local ok="$JOB_DIR/.ok"
	if [[ -f "$ok" ]]; then
		# Final outputs are renamed to save_as; check for both expected PNGs
		if [[ -s "$JOB_DIR/${save_as}.png" && -s "$JOB_DIR/${save_as}_all_peaks.png" ]]; then
			info "$job_name already complete; skipping"
			return 0
		fi
		# If user changed save_as, fall back to generic names
		if [[ -s "$JOB_DIR/nmr.png" && -s "$JOB_DIR/nmr_all_peaks.png" ]]; then
			info "$job_name already complete; skipping"
			return 0
		fi
		rm -f "$ok"
	fi

	SRC_DIR_1="process/spectrum/analysis"
	SRC_DIR_2="lib/general_scripts/gnuplot"

	move_inp_file "avg.dat" "$SRC_DIR_1" "$JOB_DIR"
	move_inp_file "all_peaks.dat" "$SRC_DIR_1" "$JOB_DIR"

	if [[ $filter == "none" ]]; then
		move_inp_file "plot_nmr.plt" "$SRC_DIR_2" "$JOB_DIR"
		move_inp_file "plot_nmr_all_peaks.plt" "$SRC_DIR_2" "$JOB_DIR"
	elif [[ $filter == "alpha_beta" ]]; then
		cp "lib/general_scripts/python/filter/filter_alpha_beta.py" "$JOB_DIR"
		cp "inputs/structures/$name.mol2" "$JOB_DIR"
		move_inp_file "plot_nmr_alpha_beta.plt" "$SRC_DIR_2" "$JOB_DIR"
		move_inp_file "plot_nmr_all_peaks.plt" "$SRC_DIR_2" "$JOB_DIR"
	else
		die "Unknown filter parameter"
	fi

	#Move to the directory to run the scripts
	cd $JOB_DIR || die "Couldn't enter the $JOB_DIR"

	#Run the script(s) and generate two outputs:
	#  1) averaged/smoothed spectrum (existing behavior)
	#  2) all-peaks "stick spectrum" (no averaging, no broadening)
	if [[ $filter == "none" ]]; then
		gnuplot plot_nmr.plt
		gnuplot plot_nmr_all_peaks.plt
	elif [[ $filter == "alpha_beta" ]]; then
		python filter_alpha_beta.py avg.dat "$name.mol2" filtered_avg.dat
		gnuplot plot_nmr_alpha_beta.plt
		gnuplot plot_nmr_all_peaks.plt
	else
		die "Unknown filter parameter"
	fi

	#Return back
	cd ../../.. || die "Couldn't back to the main directory"

	#Check that the final files are truly present
	check_res_file "nmr.png" "$JOB_DIR" "$job_name"
	check_res_file "nmr_all_peaks.png" "$JOB_DIR" "$job_name"

	mv $JOB_DIR/nmr.png $JOB_DIR/"$save_as".png
	mv $JOB_DIR/nmr_all_peaks.png $JOB_DIR/"${save_as}_all_peaks".png

	success "$job_name has finished correctly"
	mark_step_ok "$JOB_DIR"

}