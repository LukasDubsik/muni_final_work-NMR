#!/bin/bash -l

DATADIR=${dir}/process/equilibration/opt_water

echo "$PBS_JOBID is running on node $(hostname -f) in a scratch directory $SCRATCHDIR" >> "$DATADIR/jobs_info.txt"

module add amber-14

test -n "$SCRATCHDIR" || { echo >&2 "Variable SCRATCHDIR is not set!"; exit 1; }

cp $DATADIR/{opt_water.in,${name}.parm7,${name}.rst7}  $SCRATCHDIR || { echo >&2 "Error while copying input file(s)!"; exit 2; }

cd $SCRATCHDIR 

module add amber-14

pmemd -O -i opt_water.in -p ${name}.parm7 -c ${name}.rst7 -ref ${name}.rst7 -o optim.out -r ${name}_opt_water.rst7

echo "The files in the directory at the end" >> "$DATADIR/jobs_info.txt"
ls >> "$DATADIR/jobs_info.txt"

cp {optim.out,${name}_opt_water.rst7} $DATADIR/ || { echo >&2 "Result file(s) copying failed (with a code $?) !!"; exit 4; }

clean_scratch