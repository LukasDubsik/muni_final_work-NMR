#!/usr/bin/env infinity-env

module add amber

pmemd -O -i ${file} -p ${name}.parm7 -c ${name}.rst7 -ref ${name}.rst7 -o optim.out -r ${name}_opt_water.rst7