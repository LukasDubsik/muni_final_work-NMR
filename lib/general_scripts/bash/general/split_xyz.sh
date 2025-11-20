#!/bin/bash

reading=0
file="frames/frame_"
num=$1
name=""
str=0

while read line; do

    if [ $str -eq 2 ]; then
        echo "$line" >> $name #Append the Conf x ... line to the current file
        ((str--)) #Return str to normal format
        continue #Go to the atom names
    fi
    
    #If we have started reading a new frame, start svaing to a new file
    if [ ${#line} -eq 2 ]; then
        name="${file}${num}.xyz" #Change the name of the file to save into
        rm -f $name #Remove if exists
        ((str++)) #Indicate that we are passing onto a Conf x. ... line
        echo "$line" >> $name #Write into the results
		((num++)) #Increase the file safe name
        continue #Just go next, nothing new to do    
    fi

    #Otherwise Atom line... just append
    echo "$line" >> $name

done
