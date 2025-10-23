#!/usr/bin/env infinity-env

module add pmemd-cuda

pmemd.cuda -O -i opt_temp.in -p ${name}.parm7 -c ${name}_opt_all.rst7 -ref ${name}_opt_all.rst7 -o opt_temp.out -r ${name}_opt_temp.rst7 -x opt_temp.mdcoord -inf opt_temp.mdinfo
