#!/usr/bin/env infinity-env

module add amber

pmemd -O -i ${file} -p ${name}.parm7 -c ${name}_opt_water.rst7 -o opt_all.out -r ${name}_opt_all.rst7