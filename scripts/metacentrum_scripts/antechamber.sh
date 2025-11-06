#!/bin/bash -l

DATADIR=${dir}/process/preparations/antechamber

echo "$PBS_JOBID is running on node $(hostname -f) in a scratch directory $SCRATCHDIR" >> "$DATADIR/jobs_info.txt"

module add amber/22.1.3-gcc-10.2.1-man1

test -n "$SCRATCHDIR" || { echo >&2 "Variable SCRATCHDIR is not set!"; exit 1; }

cp "$DATADIR/${name}.mol2"  $SCRATCHDIR || { echo >&2 "Error while copying input file(s)!"; exit 2; }

cd $SCRATCHDIR 

module add amber-14

antechamber -i ${name}.mol2 -fi mol2 -o ${name}_charges.mol2 -fo mol2 ${comms}

echo "The files in the directory at the end" >> "$DATADIR/jobs_info.txt"
ls >> "$DATADIR/jobs_info.txt"

cp ${name}_charges.mol2 $DATADIR/ || { echo >&2 "Result file(s) copying failed (with a code $?) !!"; exit 4; }

clean_scratch