#!/usr/bin/env infinity-env

module add amber

pmemd -O -i ${file} -p ${name}.parm7 -c ${name}_opt_temp.rst7 -ref ${name}_opt_pres.rst7 -o opt_pres.out -r ${name}_opt_pres.rst7 -x opt_pres.mdcrd -inf opt_pres.mdinfo
