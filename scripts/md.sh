#!/usr/bin/env infinity-env

module add pmemd-cuda

pmemd.cuda -O -i ${file} -p ${name}.parm7 -c ${name}_opt_pres.rst7 -o ${name}_md.out -r ${name}_md.rst7 -x ${name}_md.mdcrd -inf ${name}_md.mdinfo
