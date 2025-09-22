#!/bin/bash

while true; do

    #Save the current position of the cursor
    printf '\033[s'

    #print the current status of the jobs
    pqstat

    #Wait for a time
    sleep 10

    #Return to the original position
    printf '\033[u'
    #Clear from there to the end of the screen
    printf '\033[J'

done
