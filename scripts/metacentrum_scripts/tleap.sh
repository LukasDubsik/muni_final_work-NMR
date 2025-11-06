#!/bin/bash -l

DATADIR=${dir}/process/preparations/tleap

echo "$PBS_JOBID is running on node $(hostname -f) in a scratch directory $SCRATCHDIR" >> "$DATADIR/jobs_info.txt"

module add amber-14

test -n "$SCRATCHDIR" || { echo >&2 "Variable SCRATCHDIR is not set!"; exit 1; }

cp $DATADIR/{tleap.in,${name}.frcmod,${name}_charges_fix.mol2}  $SCRATCHDIR || { echo >&2 "Error while copying input file(s)!"; exit 2; }

cd $SCRATCHDIR 

module add amber/22.1.3-gcc-10.2.1-man1

tleap -f tleap.in

echo "The files in the directory at the end" >> "$DATADIR/jobs_info.txt"
ls >> "$DATADIR/jobs_info.txt"

cp {${name}.parm7,${name}.rst7} $DATADIR/ || { echo >&2 "Result file(s) copying failed (with a code $?) !!"; exit 4; }

clean_scratch