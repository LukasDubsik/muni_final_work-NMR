#!/bin/bash

#Color schemes
RED='\033[0;31m'
GREEN='\033[0;32m'

#CChecmark, cross, etc
NC='\033[0m' # No Color
CHECKMARK="${GREEN}\xE2\x9C\x94${NC}"
CROSS="${RED}\xE2\x9C\x98${NC}"

#Export for all scripts to run from here on
export RED GREEN NC CHECKMARK CROSS

#Some basic variables
filename="inputs/sim.txt"
line_number=0
res=""

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
        echo -e "\t\t[$CROSS] ${RED} ${pattern} not specified in $filename! Required for NMR!${NC}"
        exit 1
    else
        #Check that it ends in .in
        check=$(echo $res | grep -E '\.in$')
        if [[ -z $check ]]; then
            echo -e "\t\t[$CROSS] ${RED} ${pattern} in $filename must end with .in!${NC}"
            exit 1
        else
            if [[ ! -f inputs/simulation/${res} ]]; then
                echo -e "\t\t[$CROSS] ${RED} Input file ${res} not found in inputs/simulation/!${NC}"
                exit 1
            else
                echo -e "\t\t[$CHECKMARK] Input file ${res} found in inputs/simulation/."
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
        echo -e "\t\t[$CROSS] ${RED} ${pattern} not specified in $filename! Required as .mol2 given. If no additions to running the program just leave \"\".${NC}"
        exit 1
    else
        #Check that it ends in .sh
        check=$(echo $res | grep -E '^".*"$')
        if [[ -z $check ]]; then
            echo -e "\t\t[$CROSS] ${RED} ${pattern} in $filename must end with .sh!${NC}"
            exit 1
        else
            res=$(echo $res | sed 's/"//g')
            command=$(tail -n 1 scripts/${pattern}.sh)
            #Replace the $1 by the name
            command=$(echo $command | sed "s/\${1}/${name}/g")
            echo -e "\t\t[$CHECKMARK] ${pattern} specified and will be run as\n\t\t\t" $command ${res}
        fi
    fi
}

#General script to run .sh simulation scripts
run_sh_sim(){
    #Load the inputs to the function
    script_name=$1
    path=process/$2
    hook=$3
    mem=$4
    ncpus=$5
    #Create the enviroment for running 
    mkdir -p $path
    cp scripts/$script_name.sh $path/ || return 0
    cd $path || return 0
    cp -r $hook . || return 0
    #Move necessary files to the directory
    #Submit the job by running through psubmit -> metacentrum
    psubmit -l select=1:ncpus=${ncpus}:mem=${mem}gb default ${script_name}.sh || return 0
    #Remove all files except those having given extension or in files array
    for file in *; do
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
    done

    return 1
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

#Checking that all .in files are present
echo -e "\t\t Checking if .in files present!"

#Check for each .in file
check_in_file "tleap"
check_in_file "opt_water"
check_in_file "opt_all"
check_in_file "opt_temp"
check_in_file "opt_pres"
check_in_file "md"

### Currently in process of possible additions

#Check that all necessary .sh files are meantioned and present
#If .mol2 specified, check that antechamber and parmchk2 are given
if [[ $input_type == "mol2" ]]; then
    echo -e "\t\t Checking if necessary .sh files present for input_type 'mol2'!"

    check_sh_file "antechamber"
    check_sh_file "parmchk2"
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


#All checks done
##Begin with simulations
mkdir -p data_results/${name}/logs #The directory to move all results to

#Starting with converting the structures .mol2 (if given) to the rst7/parm7 format
if [[ $input_type == "mol2" ]]; then
    echo -e "\t Starting with structure conversion from .mol2 to .rst7/.parm7 format."

    #Firstly, run the antechamber program
    run_sh_sim "antechamber" "preparations/antechamber/" "../../../inputs/structures/${name}.mol2" 4 2
    if [[ $? -eq 0 ]]; then
        echo -e "\t\t[$CROSS] ${RED} Antechamber failed! Exiting...${NC}"
        exit 1
    else
        echo -e "\t\t[$CHECKMARK] Antechamber finished successfully."
    fi
fi
