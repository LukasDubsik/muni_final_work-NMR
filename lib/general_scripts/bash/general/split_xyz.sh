#!/bin/bash

file="frames/frame_"
num=$1
name=""
str=0

while IFS= read -r line; do

    if [ $str -eq 2 ]; then
        echo "$line" >> "$name"   # Append the "Conf x ..." comment line
        ((str--))
        continue
    fi

    # Detect the atom-count header: a line containing only a positive integer
    # (handles any number of atoms, not just 2-digit counts)
    if [[ "$line" =~ ^[[:space:]]*[0-9]+[[:space:]]*$ ]]; then
        name="${file}${num}.xyz"
        rm -f "$name"
        ((str++))
        echo "$line" >> "$name"
        ((num++))
        continue
    fi

    # Otherwise it is a coordinate line — append to current file
    echo "$line" >> "$name"

done