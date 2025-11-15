# shellcheck disable=SC2148
# Guard so we don't load twice
[[ ${_DATA_SH_LOADED:-0} -eq 1 ]] && return
_DATA_SH_LOADED=1

# run_analysis META NUM_FRAMES
# Analyze the results from the gauss nmr run and get necessary data
# Globals: none
# Returns: Nothing
run_analysis() {
	#Load the inputs
	local meta=$1
	local num_frames=$2

	local job_name="analysis"

	info "Started running $job_name"

    #Start by converting the input mol into a xyz format -necessary for crest
	JOB_DIR="process/spectrum/$job_name"
	ensure_dir $JOB_DIR

	SRC_DIR_1="lib/general_scripts/bash/general"

	move_inp_file "xyz_to_gfj.sh" "$SRC_DIR_1" "$JOB_DIR"

	#Ensure the final dir exists
    ensure_dir $JOB_DIR/gauss

	#Run the bash script
	cd "$JOB_DIR" || die "Couldn't enter the cpptraj directory"
	bash xyz_to_gfj.sh
	cd ../../../ || die "Couldn't return back from the cpptraj dir"

	#Check that the final files are truly present
	check_res_file "$JOB_DIR/gauss/frame.$num_frames.gfj" "$JOB_DIR" "$job_name"

	success "$job_name has finished correctly"

	#Write to the log a finished operation
	add_to_log "$job_name" "$LOG"
}


#Combine the resulting files and plot the final spectrum
echo -e "\t\t Plotting the final NMR spectrum..."
mkdir -p "process/spectrum/plotting/plots/"
sigma=32.2 #Assumed solvent TMS shielding constant
echo -e "\t\t\t[$CHECKMARK] Number of atoms in the molecule set to $limit, sigma for TMS set to $sigma."
#Copy the .sh and .awk and .plt scripts while replacing the values
sed "s/\${sigma}/${sigma}/g; s/\${limit}/${limit}/g" $SCRIPTS/log_to_plot.sh > process/spectrum/plotting/log_to_plot.sh || { echo -e "\t\t\t[$CROSS] ${RED} Failed to modify the log_to_plot.sh file!${NC}"; exit 1; }
cp $SCRIPTS/gjf_to_plot.awk process/spectrum/plotting/gjf_to_plot.awk || { echo -e "\t\t\t[$CROSS] ${RED} Failed to modify the log_to_plot.awk file!${NC}"; exit 1; }
cp $SCRIPTS/average_plot.sh process/spectrum/plotting/average_plot.sh || { echo -e "\t\t\t[$CROSS] ${RED} Failed to copy the average_plot.sh file!${NC}"; exit 1; }
sed "s/\${name}/${name}/g" $SCRIPTS/plot_nmr.plt > process/spectrum/plotting/plot_nmr.plt || { echo -e "\t\t\t[$CROSS] ${RED} Failed to modify the plot_nmr.plt file!${NC}"; exit 1; }
cp -r process/spectrum/NMR/nmr process/spectrum/plotting/.
echo -e "\t\t\t[$CHECKMARK] All necessary files copied to plotting directory."
#Run the script
cd process/spectrum/plotting || { echo -e "\t\t\t[$CROSS] ${RED} Failed to enter the plotting directory!${NC}"; exit 1; }   
bash log_to_plot.sh || { echo -e "\t\t\t[$CROSS] ${RED} Failed to plot the NMR spectrum!${NC}"; exit 1; }
echo -e "\t\t\t[$CHECKMARK] Log file converted to plot data."
#Finally plot and check presence of the graphic file
gnuplot plot_nmr.plt || { echo -e "\t\t\t[$CROSS] ${RED} Failed to run gnuplot for NMR spectrum!${NC}"; exit 1; }
mv "${name}"_nmr.png "${save_as}".png
cd ../../../ || { echo -e "\t\t\t[$CROSS] ${RED} Failed to return to main directory after plotting!${NC}"; exit 1; }
if [[ ! -f process/spectrum/plotting/${save_as}.png ]]; then
    echo -e "\t\t\t[$CROSS] ${RED} Plotting the NMR spectrum failed, no file found!${NC}"
    exit 1
else
    echo -e "\t\t\t[$CHECKMARK] Plotting the NMR spectrum successful."
fi