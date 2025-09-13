#!/bin/bash

#Color schemes
RED='\033[0;31m'
GREEN='\033[0;32m'

#CChecmark, cross, etc
NC='\033[0m' # No Color
CHECKMARK="${GREEN}\xE2\x9C\x94${NC}"
CROSS="${RED}\xE2\x9C\x98${NC}"

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