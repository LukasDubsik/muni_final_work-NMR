#!/bin/bash

#Color schemes
RED='\033[0;31m'
GREEN='\033[0;32m'

#Checmark, cross, etc
NC='\033[0m' # No Color
CHECKMARK="${GREEN}\xE2\x9C\x94${NC}"
CROSS="${RED}\xE2\x9C\x98${NC}"

#Export for all scripts to run from here on
export RED GREEN NC CHECKMARK CROSS

#Some basic variables
filename="inputs/sim.txt"
line_number=0
res=""

#File to store the progress of the simulation

#Functions
#Iterate through the "sim.txt"file
file_iterate(){
    pattern=$1
    while true; do
        ((line_number++))

        #sed the current line by line number
        line=$(sed -n "${line_number}p" $filename)
        
        #If line starts with #, skip it
        [[ $line =~ ^#.*$ ]] && continue
        #If line is empty, skip it
        [[ -z $line ]] && continue
        
        #Then check if it has the input_type:=, if so get what is after
        if [[ $line =~ ^${pattern}:=(.*)$ ]]; then
            res=$(echo $line | sed "s/${pattern}:=//")
            return 1
        fi

        #If we reach the end of the file, break
        if [ $line_number -ge $(wc -l < $filename) ]; then
            return 0
        fi
    done
}

#Check for given .in file
check_in_file(){
    pattern=$1
    file_iterate $pattern
    ret=$?
    if [[ $ret -eq 0 ]]; then
        echo -e "\t\t\t[$CROSS] ${RED} ${pattern} not specified in $filename! Required for NMR!${NC}"
        exit 1
    else
        #Check that it ends in .in
        check=$(echo $res | grep -E '\.in$')
        if [[ -z $check ]]; then
            echo -e "\t\t\t[$CROSS] ${RED} ${pattern} in $filename must end with .in!${NC}"
            exit 1
        else
            if [[ ! -f inputs/simulation/${res} ]]; then
                echo -e "\t\t\t[$CROSS] ${RED} Input file ${res} not found in inputs/simulation/!${NC}"
                exit 1
            else
                echo -e "\t\t\t[$CHECKMARK] Input file ${res} found in inputs/simulation/."
            fi
        fi
    fi
}

#Check for given .sh files
check_sh_file(){
    pattern=$1
    file_iterate $pattern
    ret=$?
    if [[ $ret -eq 0 ]]; then
        echo -e "\t\t\t[$CROSS] ${RED} ${pattern} not specified in $filename! Required as .mol2 given. If no additions to running the program just leave \"\".${NC}"
        exit 1
    else
        #Check that it ends in .sh
        check=$(echo $res | grep -E '^".*"$')
        if [[ -z $check ]]; then
            echo -e "\t\t\t[$CROSS] ${RED} ${pattern} in $filename must end with .sh!${NC}"
            exit 1
        else
            res=$(echo $res | sed 's/"//g')
            com=$(tail -n 1 $SCRIPTS/${pattern}.sh)
            #Replace the $1 by the name
            com=$(echo $com | sed "s/\${name}/"${name}"/g")
            echo -e "\t\t\t[$CHECKMARK] ${pattern} specified and will be run as\n\t\t\t\t" $com ${res}
        fi
    fi
}

#General script to run .sh simulation scripts
run_sh_sim(){
    #Load the inputs to the function
    script_name=$1
    path=process/$2
    hook=$3
    comms=$4
    fi=$5
    mem=$6
    ncpus=$7
    ngpus=$8
    num=$9
    n=${10}
    if [[ -z $n ]]; then
        n=1
    fi

    #Make directory workable for sed by reworking /
    dir_esc=${dir//&/\\&}
    dir_esc=${dir_esc//\//\\/}

    #Substite ';' for ' ' and combine the hook for copying
    hook=$(echo "${hook//;/ }")
    
    #Save current directory so we can return to it
    curr_dir=$(pwd)
    #Create the enviroment for running 
    mkdir -p $path
    cp -r $hook $path/ || { echo -e "\t\t\t[$CROSS] ${RED} Failed to copy the hook files to $path!${NC}"; return 0; }
    #Modify the .sh file - substitute the file name, number and directory
    sed "s/\${name}/${name}/g; s/\${num}/${num}/g; s/\${dir}/${dir_esc}/g; s/\${comms}/${comms}/g; s/\${file}/${file}/g" $SCRIPTS/$script_name.sh > $path/$script_name.sh || { echo -e "\t\t\t[$CROSS] ${RED} Failed to modify the $script_name.sh file!${NC}"; return 0; }
    #echo $comms >> $path/$script_name.sh
    cd $path || { echo -e "\t\t\t[$CROSS] ${RED} Failed to enter the $path directory!${NC}"; return 0; }
    [ $n -ne 0 ] && echo -e "\t\t\t[$CHECKMARK] Starting enviroment created succesfully"

    #Depending where we are running it
    if [[ $META == true ]]; then
        #Submit the job by running through psubmit -> metacentrum
        jobid=$(qsub -q default -l select=1:ncpus=${ncpus}:ngpus=${ngpus}:mem=${mem}gb -l walltime=0:40:00 ${script_name}.sh | tail -2 || { echo -e "\t\t\t[$CROSS] ${RED} Failed to submit the job!${NC}"; return 0; })
    else
        jobid=$(psubmit -ys default ${script_name}.sh ncpus=${ncpus} mem=${mem}gb ngpus=${ngpus} | tail -2 || { echo -e "\t\t\t[$CROSS] ${RED} Failed to submit the job!${NC}"; return 0; })
    fi
    #Get the job id from second to last line
    #echo $jobid
    IFS='.' read -r -a jobid_arr <<< "$jobid"
    IFS=' ' read -r -a jobid_arr2 <<< "${jobid_arr[0]}"
    #Then save the final form 
    jobid=${jobid_arr2[-1]}
    #echo $jobid

    #Check if the jobid is really a number
    re='^[0-9]+$'
    if ! [[ $jobid =~ $re ]]; then
        echo -e "\t\t\t[$CROSS] ${RED} Job was submitted incorrectly!${NC}"
        return 0
    else
        [ $n -ne 0 ] && echo -e "\t\t\t[$CHECKMARK] Job ${jobid} submitted succesfully, waiting for it to finish."
    fi

    #Cycle till the job is finished (succesfully/unsuccesfully)
    while :; do
        #Run qstat to pool the job
        qstat $jobid > /dev/null 2>&1
        res=$?
        #If we have returned "153" job has not been run
        if [[ $res -eq 153 ]]; then
            echo -e "\t\t\t[$CROSS] ${RED} Job $jobid has not started (qstat says not listed)!${NC}"
            return 0
        fi
        #If we have 35 job has finished running (even if incorrectly)
        if [[ $res -eq 35 ]]; then
            break
        fi
        sleep 10
    done    

    #Check if the final file is generated - if not, we have an error
    if [[ ! -f $fi && $wai -ne 0 ]]; then
        echo -e "\t\t\t[$CROSS] ${RED} ${script_name}.sh failed, the expected files failed to be found!${NC}"
        return 0
    else
        [ $n -ne 0 ] && echo -e "\t\t\t[$CHECKMARK] ${script_name}.sh finished successfully, ${fi} found."
    fi

    #Before deleting files, save the files ending with .stdout in current dir to logs
    #cat *.stdout > ${curr_dir}/data_results/logs/${script_name}.log

    #Remove all files except those having given extension or in files array
    #for file in *; do
    #    #Check if file matches any of the extensions
    #    match_ext=false
    #    for ext in "${ext_array[@]}"; do
    #        if [[ $file == *.$ext ]]; then
    #            match_ext=true
    #            break
    #        fi
    #    done

    #    #Check if file matches any of the files
    #    match_file=false
    #    for fname in "${files_array[@]}"; do

    #        if [[ $file == $fname ]]; then
    #            match_file=true
    #            break
    #        fi
    #    done

    #    #If it doesn't match either, remove it
    #    if [[ $match_ext == false && $match_file == false ]]; then
    #        rm -rf "$file"
    #    fi
    #done

    #return to the original directory
    cd $curr_dir

    return 1
}

substitute_name_in(){
    script_name=$1
    path=process/$2
    sed "s/\${name}/${name}/g; s/\${num}/${limit}/g" inputs/simulation/${script_name} > $path/$script_name || return 0
    return 1
}

move_for_presentation(){
    input_dir=$1
    destination_dir=$2

    mkdir -p $destination_dir

    #Remove all files except those having given extension or in files array
    for file in $input_dir; do
        #Check if file matches any of the extensions
        match_ext=false
        for ext in "${ext_array[@]}"; do
            if [[ $file == *.$ext ]]; then
                match_ext=true
                break
            fi
        done

        #Check if file matches any of the files
        match_file=false
        for fname in "${files_array[@]}"; do

            if [[ $file == $fname ]]; then
                match_file=true
                break
            fi
        done

        #If it doesn't match either, remove it
        if [[ $match_ext == false && $match_file == false ]]; then
            rm -rf "$file"
        fi

        #Then copy the results to the resulting dir
        cp -r $input_dir $destination_dir
    done
}

#Starting to write the log
echo -e "Starting the simulation process..."
echo -e "\t Checking the presence of necessary files:"

#Is the sim.txt file present?
if [ ! -f $filename ]; then
    echo -e "\t\t[$CROSS] ${RED} Input file $filename not found!${NC}"
    exit 1
else
    echo -e "\t\t[$CHECKMARK] Input file $filename found."
fi

#Is the name of the files given?
file_iterate "name"
ret=$?
if [[ $ret -eq 0 ]]; then
    echo -e "\t\t[$CROSS] ${RED} name not specified in $filename!${NC}"
    exit 1
else
    name=$res
    echo -e "\t\t[$CHECKMARK] Name of the files is set to '$name'."
fi

#Is the name for the save given
file_iterate "save_as"
ret=$?
if [[ $ret -eq 0 ]]; then
    echo -e "\t\t[$CROSS] ${RED} name to save not specified in $filename!${NC}"
    exit 1
else
    save_as=$res
    echo -e "\t\t[$CHECKMARK] Name of the save directory is set to '$save_as'."
fi

#Is the correct structure file then provided?
file_iterate "input_type"
ret=$?

#Check that the correct files are present based on input_type
if [[ $ret -eq 0 ]]; then
    echo -e "\t\t[$CROSS] ${RED} input_type not specified in $filename!${NC}"
    exit 1
else
    input_type=$res
    if [[ $input_type != "mol2" && $input_type != "7" ]]; then
        echo -e "\t\t[$CROSS] ${RED} input_type must be either 'mol2' or '7'!${NC}"
        exit 1
    else
        if [[ $input_type == "mol2" && ! -f inputs/structures/${name}.mol2 ]]; then
            echo -e "\t\t[$CROSS] ${RED} input_type is set to 'mol2' but no .mol2 files found in inputs/structures/!${NC}"
        elif [[ $input_type == "7" && (! -f inputs/structures/${name}.rst7 || ! -f inputs/structures/${name}.parm7) ]]; then
            echo -e "\t\t[$CROSS] ${RED} input_type is set to '7' but no .rst7 or .parm7 files found in inputs/structures/!${NC}"
        else
            echo -e "\t\t[$CHECKMARK] All necessary files found for input_type '$input_type'."
        fi
    fi
fi

#Get the number of atoms from the initial mol file
limit=$(grep -A 2 "^@<TRIPOS>MOLECULE" inputs/structures/${name}.mol2 | tail -n 1 | awk '{print $1}')


#Check if the simulation is in metacentrum mode
file_iterate "meta"
ret=$?
if [[ $ret -eq 0 ]]; then
    echo -e "\t\t[$CROSS] ${RED} If running in metacentrum not specified $filename!${NC}"
    exit 1
else
    META=$res
    echo -e "\t\t[$CHECKMARK] It is going to be run in metacentrum: '$META'."
fi

#Choose the script folder based on META
if [[ $META == true ]]; then
    SCRIPTS="scripts_meta"
else
    SCRIPTS="scripts"
fi

#Get the directory for the metacentrum
if [[ $META == true ]]; then
    file_iterate "directory"
    ret=$?
    if [[ $ret -eq 0 ]]; then
        echo -e "\t\t[$CROSS] ${RED} name of the metacentrum directory not given in $filename!${NC}"
        exit 1
    else
        dir=$res
        echo -e "\t\t[$CHECKMARK] Name of the metacentrum directory is set to '$dir'."
    fi
fi

#If the simulation is to be qmmm
file_iterate "qmmm"
if [[ $ret -eq 0 ]]; then
    echo -e "\t\t[$CROSS] ${RED} Not found qmmm specification in $filename!${NC}"
    exit 1
else
    qmmm=$res
    echo -e "\t\t[$CHECKMARK] QM?MM is set to: '$qmmm'."
fi

#Checking that all .in files are present
echo -e "\t\t Checking if .in files present!"

#Check for each .in file
check_in_file "tleap"
tleap_file=$res
check_in_file "opt_water"
opt_water_file=$res
check_in_file "opt_all"
opt_all_file=$res
check_in_file "opt_temp"
opt_temp_file=$res
check_in_file "opt_pres"
opt_pres_file=$res
check_in_file "md"
md_file=$res

#Check if tpl is present - only if qmmm set already
file_iterate "tpl"
ret=$?
if [[ $ret -eq 0 ]]; then
    echo -e "\t\t[$CROSS] ${RED} Tpl not specified even if tpl set!${NC}"
    exit 1
else
    tpl=$res
    echo -e "\t\t[$CHECKMARK] Name of the tpl file is: '$tpl'."
fi
#Check if the file exists
if [[ ! -f inputs/simulation/${res} ]]; then
    echo -e "\t\t\t[$CROSS] ${RED} Input file ${res} not found in inputs/simulation/!${NC}"
    exit 1
fi

#Check that all necessary .sh files are meantioned and present
#If .mol2 specified, check that antechamber and parmchk2 are given
if [[ $input_type == "mol2" ]]; then
    echo -e "\t\t Checking if necessary .sh files present for input_type 'mol2'!"

    check_sh_file "antechamber"
    commands_antechamber=$res
    check_sh_file "parmchk2"
    commands_parmchk2=$res
fi

###

#Check that files and extensions to save are mentioned and extract that data
file_iterate "extensions"
ret=$?
if [[ $ret -eq 0 ]]; then
    echo -e "\t\t[$CROSS] ${RED} extensions not specified in $filename! Required for moving files to data_results!${NC}"
    exit 1
else
    extensions=$res
    #Convert to array by separation with ;
    IFS=';' read -r -a ext_array <<< "$extensions"
    echo -e "\t\t[$CHECKMARK] Extensions to be saved are set to '$extensions'."
fi

file_iterate "files"
ret=$?
if [[ $ret -eq 0 ]]; then
    echo -e "\t\t[$CROSS] ${RED} files not specified in $filename! Required for moving files to data_results!${NC}"
    exit 1
else
    files=$res
    #Convert to array by separation with ;
    IFS=';' read -r -a files_array <<< "$files"
    echo -e "\t\t[$CHECKMARK] Files to be saved are set to '$files'."
fi

#Split to individual images of the simulation and convert to gauss format
echo -e "\t\t Splitting the frames and converting to .gjf format..."
mkdir -p "process/spectrum/gauss_prep/"
#Then convert each frame to .gjf format by running xyz_to_gfj.sh
cp $SCRIPTS/xyz_to_gfj.sh process/spectrum/gauss_prep/.
mkdir -p process/spectrum/gauss_prep/gauss
cd process/spectrum/gauss_prep/ || { echo -e "\t\t\t[$CROSS] ${RED} Failed to enter the gauss_prep directory!${NC}"; exit 1; }
bash xyz_to_gfj.sh || { echo -e "\t\t\t[$CROSS] ${RED} Failed to convert to .gjf format!${NC}"; exit 1; }
cd ../../../ || { echo -e "\t\t\t[$CROSS] ${RED} Failed to return to main directory after converting!${NC}"; exit 1; }
if [[ ! -d process/spectrum/gauss_prep/gauss || -z "$(ls -A process/spectrum/gauss_prep/gauss)" ]]; then
    echo -e "\t\t\t[$CROSS] ${RED} Conversion to .gjf format failed, no files found!${NC}"
    exit 1
else
    echo -e "\t\t\t[$CHECKMARK] Conversion to .gjf format successful."
fi

#Run the gaussian simulation on each file and store the results
echo -e "\t\t Running Gaussian NMR calculations..."
mkdir -p "process/spectrum/NMR/"
#Copy the .sh script
#cp scripts/run_NMR.sh process/spectrum/NMR/.
#Copy the generated .gjf files directory
mkdir -p process/spectrum/NMR/nmr
#Run the jobs in parallel each in different directory and subshell
pids=()
#Enter the directory and run the .sh script
for num in {1..100}; do
    #create a new dir for the file
    mkdir -p "process/spectrum/NMR/job_${num}/"
    ( run_sh_sim "run_NMR" "spectrum/NMR/job_${num}/" "process/spectrum/gauss_prep/gauss/frame.${num}.gjf" "" "frame.${num}.log" 15 4 0 ${num} 0 ) &
    pids+=($!)
done
#Wait for all jobs to finish; kill all others if just one fails
for pid in "${pids[@]}"; do
    wait $pid
    if [[ $? -eq 0 ]]; then
        kill "${pids[@]}" 2>/dev/null        
        echo -e "\t\t\t[$CROSS] ${RED} One of the Gaussian NMR jobs failed! Exiting...${NC}"
        qdel $(qselect -u lukasdubsik)
        exit 1
    fi
done
#All jobs finished successfully
echo -e "\t\t\t[$CHECKMARK] All Gaussian NMR jobs submitted, waiting for them to finish."
#Create the resulting directory nmr
mkdir -p "process/spectrum/NMR/nmr"
#Move the log and delete each of the job dirs
for i in {1..100}; do
    mv process/spectrum/NMR/job_${i}/frame.${i}.log process/spectrum/NMR/nmr/
    rm -rf process/spectrum/NMR/job_${i}
done
echo -e "\t\t\t[$CHECKMARK] Gaussian NMR calculations finished successfully."

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
cd ../../../ || { echo -e "\t\t\t[$CROSS] ${RED} Failed to return to main directory after plotting!${NC}"; exit 1; }
if [[ ! -f process/spectrum/plotting/${name}_nmr.png ]]; then
    echo -e "\t\t\t[$CROSS] ${RED} Plotting the NMR spectrum failed, no file found!${NC}"
    exit 1
else
    echo -e "\t\t\t[$CHECKMARK] Plotting the NMR spectrum successful."
fi

#Start moving the results to data_results - separate by main directories (preparations, equlibration...)
#Don't duplicate files
echo -e "\t Moving the results to data_results/${name}/"
#delete the file for save if already present
rm -rf data_results/${save_as}/
mkdir -p data_results/${save_as}/
#Move the logs in there
mv logs/ data_results/${save_as}/ 2>/dev/null
#Copy everything for posterity
cp -r process/ data_results/${save_as}/
#Start with preparations
prep=data_results/${name}/preparations
mkdir -p $prep
move_for_presentation process/preparations/antechamber/ data_results/${name}/preparations/ 2>/dev/null
move_for_presentation process/preparations/parmchk2/ data_results/${name}/preparations/ 2>/dev/null
move_for_presentation process/preparations/tleap/ data_results/${name}/preparations/ 2>/dev/null
#Then equilibration
mkdir -p data_results/${name}/equilibration
move_for_presentation process/equilibration/opt_water/ data_results/${name}/equilibration/ 2>/dev/null
move_for_presentation process/equilibration/opt_all/ data_results/${name}/equilibration/ 2>/dev/null
move_for_presentation process/equilibration/opt_temp/ data_results/${name}/equilibration/ 2>/dev/null
move_for_presentation process/equilibration/opt_pres/ data_results/${name}/equilibration/ 2>/dev/null
#Then md
mkdir -p data_results/${name}/md
move_for_presentation process/md/ data_results/${name}/md/ 2>/dev/null
move_for_presentation process/md/ data_results/${name}/md/ 2>/dev/null
#Then spectrum
mkdir -p data_results/${name}/spectrum
move_for_presentation process/spectrum/cpptraj/ data_results/${name}/spectrum/ 2>/dev/null
move_for_presentation process/spectrum/plotting/ data_results/${name}/spectrum/ 2>/dev/null

#Delete the process directory
#rm -rf process/*

#Zip the results for better movement
zip -r data_results/${name}.zip data_results/${name}/
rm -rf data_results/${name}
