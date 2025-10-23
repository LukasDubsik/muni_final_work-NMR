#!/bin/bash -l

DATADIR=$(pwd)

echo "$PBS_JOBID is running on node $(hostname -f) in a scratch directory $SCRATCHDIR" >> "$DATADIR/jobs_info.txt"

module add amber-14

test -n "$SCRATCHDIR" || { echo >&2 "Variable SCRATCHDIR is not set!"; exit 1; }

cp "$DATADIR/${name}.mol2"  $SCRATCHDIR || { echo >&2 "Error while copying input file(s)!"; exit 2; }

cd $SCRATCHDIR 

module add amber-14

antechamber -i ${name}.mol2 -fi mol2 -o ${name}_charges.mol2 -fo mol2 