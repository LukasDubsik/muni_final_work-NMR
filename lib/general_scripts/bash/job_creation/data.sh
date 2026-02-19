# shellcheck disable=SC2148
# Guard so we don't load twice
[[ ${_DATA_SH_LOADED:-0} -eq 1 ]] && return
_DATA_SH_LOADED=1

# run_analysis SIGMA LIMIT
# Analyze the results from the gauss nmr run and get necessary data
# Globals used: meta, directory, gauss_mod (or derived), JOB_META_SELECT_EXTRA (optional)
run_analysis() {
	# Inputs
	local sigma_in=$1
	local limit=$2
	local job_name="analysis"
	local start_dir="$PWD"

	info "Started running $job_name"

	# Workspace
	local JOB_DIR="process/spectrum/$job_name"
	ensure_dir "$JOB_DIR"

	local ok="$JOB_DIR/.ok"
	if [[ -f "$ok" ]]; then
		if [[ -s "$JOB_DIR/avg.dat" && -s "$JOB_DIR/all_peaks.dat" ]]; then
			info "$job_name already complete; skipping"
			return 0
		else
			rm -f "$ok"
		fi
	fi

	# Source locations (relative to project root; keep CWD in root!)
	local SRC_DIR_1="lib/general_scripts/bash/general"
	local SRC_DIR_2="lib/general_scripts/awk"
	local SRC_DIR_3="process/spectrum/gaussian/nmr"

	# Stage analysis helpers
	ensure_dir "$JOB_DIR/plots"
	move_inp_file "average_plot.sh" "$SRC_DIR_1" "$JOB_DIR"
	move_inp_file "gjf_to_plot.awk" "$SRC_DIR_2" "$JOB_DIR"

	# Copy/refresh Gaussian logs (merge contents; preserve any existing tms.log)
	ensure_dir "$JOB_DIR/nmr"
	if [[ -d "$SRC_DIR_3" ]]; then
		cp -a "$SRC_DIR_3/." "$JOB_DIR/nmr/" || die "Failed to copy gaussian logs from $SRC_DIR_3 to $JOB_DIR/nmr"
	else
		die "Missing gaussian NMR log directory: $SRC_DIR_3"
	fi

	#############################################
	# TMS reference: compute SIGMA_TMS (absolute shielding) if sigma_in is empty or "auto"
	#############################################
	local sigma="$sigma_in"

	# Resolve Gaussian module name (fixes your undefined ${gaussian})
	local GAUSS_MOD="${gauss_mod:-}"
	if [[ -z "$GAUSS_MOD" ]]; then
		if [[ "${meta:-false}" == "true" ]]; then
			GAUSS_MOD="g16"
		else
			GAUSS_MOD="gaussian"
		fi
	fi

	if [[ -z "${sigma:-}" || "${sigma}" == "auto" ]]; then
		local tms_dir="$JOB_DIR/tms_ref"
		local tms_job="$tms_dir/job_tms"
		local tms_gjf="$tms_job/frame_tms.gjf"
		local tms_log="$tms_job/frame_tms.log"
		local tms_ref_out="$JOB_DIR/nmr/tms.log"

		local mem_gb=8
		local ncpus=8

		ensure_dir "$tms_dir"
		ensure_dir "$tms_job"

		# Reuse cached reference if it finished normally
		if gaussian_log_ok "$tms_ref_out"; then
			info "TMS reference already present; reusing $tms_ref_out"
		else
			info "Creating and running Gaussian TMS reference job (to compute SIGMA_TMS)"

			rm -f "$tms_gjf" "$tms_log" "$tms_job/.jobid" 2>/dev/null || true

			# Geometry from NIST CCCBDB (tetramethylsilane Cartesian coordinates)
			cat > "$tms_gjf" <<'EOF'
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
#P B3LYP/6-31++G(d,p) NMR=GIAO SCRF=COSMO Geom=AllCheck Guess=Read SCF=(XQC,Tight) Int=UltraFine CPHF=Grid=UltraFine

TMS reference (NMR, COSMO)

0 1
EOF

			# Match resources to allocation
			patch_gaussian_link0_resources "$tms_gjf" "$mem_gb" "$ncpus"

			# Scheduler extras (MetaCentrum: license + scratch)
			local old_extra="${JOB_META_SELECT_EXTRA:-}"
			if [[ "${meta:-false}" == "true" ]]; then
				JOB_META_SELECT_EXTRA="host_licenses=g16:scratch_local=10gb"
			fi

			# Build & submit job script in tms_job (templates are relative to project root -> keep CWD in root)
			if [[ "${meta:-false}" == "true" ]]; then
				substitute_name_sh_meta_start "$tms_job" "${directory}" ""
				substitute_name_sh_meta_end   "$tms_job"
				substitute_name_sh "gaussian" "$tms_job" "$GAUSS_MOD" "tms_ref" "" "tms" "" ""
				construct_sh_meta "$tms_job" "gaussian"
			else
				substitute_name_sh_wolf_start "$tms_job"
				substitute_name_sh "gaussian" "$tms_job" "$GAUSS_MOD" "tms_ref" "" "tms" "" ""
				construct_sh_wolf "$tms_job" "gaussian"
			fi

			# Submit (submit_job already waits)
			submit_job "${meta:-false}" "gaussian" "$tms_job" "$mem_gb" "$ncpus" 0 "01:00:00"

			# Validate and cache
			gaussian_log_ok "$tms_log" || die "TMS reference Gaussian did not finish normally: $tms_log"
			cp "$tms_log" "$tms_ref_out"

			# Restore scheduler extras
			if [[ "${meta:-false}" == "true" ]]; then
				JOB_META_SELECT_EXTRA="$old_extra"
			fi
		fi

		# Extract σ(TMS) as average over all H in the shielding tensor block
		sigma=$(
			awk '
			/Magnetic shielding tensor/ {in=1; next}
			in {
				# Match: <idx> H Isotropic = <value>
				if (match($0, /^[[:space:]]*[0-9]+[[:space:]]+H[[:space:]]+Isotropic[[:space:]]*=[[:space:]]*/, m)) {
					line=$0
					sub(/.*Isotropic[[:space:]]*=[[:space:]]*/, "", line)
					split(line, a, /[[:space:]]+/)
					v=a[1]
					gsub(/[dD]/, "E", v)
					sum += v
					n++
				}
			}
			in && /^[[:space:]]*$/ {
				if (n > 0) { printf "%.10f\n", sum/n; exit }
				in=0
			}
			END {
				if (n > 0) printf "%.10f\n", sum/n
			}
			' "$JOB_DIR/nmr/tms.log"
		)
		[[ -n "$sigma" ]] || die "Failed to parse SIGMA_TMS from $JOB_DIR/nmr/tms.log"
		info "Computed SIGMA_TMS (TMS reference) = $sigma ppm"
	fi

	# Now that sigma is final, generate log_to_plot.sh with the correct value embedded
	substitute_name_sh_data "general/log_to_plot.sh" "$JOB_DIR/log_to_plot.sh" "" "$limit" "$sigma" ""

	# Run the spectrum processing in the analysis directory (don’t change global CWD)
	( cd "$JOB_DIR" && SIGMA_TMS="$sigma" bash log_to_plot.sh ) || die "log_to_plot.sh failed in $JOB_DIR"

	# Return to original dir
	cd "$start_dir" || die "Couldn't return to: $start_dir"

	# Validate outputs
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