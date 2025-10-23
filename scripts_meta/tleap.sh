#!/bin/bash -l

DATADIR=${dir}/process/preparations/tleap

echo "$PBS_JOBID is running on node $(hostname -f) in a scratch directory $SCRATCHDIR" >> "$DATADIR/jobs_info.txt"

module add amber-14

test -n "$SCRATCHDIR" || { echo >&2 "Variable SCRATCHDIR is not set!"; exit 1; }

cp "$DATADIR/{tleap.in,${name}.frcmod,${name}_charges_fix.mol2}"  $SCRATCHDIR || { echo >&2 "Error while copying input file(s)!"; exit 2; }

cd $SCRATCHDIR 

module add amber-14

tleap -f tleap.in

cp {${name}.parm7,${name}.rst7} $DATADIR/ || { echo >&2 "Result file(s) copying failed (with a code $?) !!"; exit 4; }

clean_scratch