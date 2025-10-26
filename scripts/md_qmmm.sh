#!/usr/bin/env infinity-env

module add amber
module add gaussian

# Use node-local fast scratch for Gaussian
export GAUSS_SCRDIR="/scratch/$USER/${PBS_JOBID:-$$}/gauss"
mkdir -p "$GAUSS_SCRDIR"

/software/ncbr/softrepo/lcc/amber/24.0/m64-ub22/serial/bin/sander -O -i ${file} -p ${name}.parm7 -c ${name}_opt_pres.rst7 -o ${name}_md.out -r ${name}_md.rst7 -x ${name}_md.mdcrd -inf ${name}_md.mdinfo
