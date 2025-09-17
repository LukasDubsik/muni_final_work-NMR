#!/usr/bin/env infinity-env

module add amber

pmemd -O -i md.in -p ${name}.parm7 -c ${name}_opt_pres.rst7 -o md.out -r ${name}_md.rst7 -x md.mdcrd -inf md.mdinfo
