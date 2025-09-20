#!/usr/bin/env infinity-env

module add amber

pmemd -O -i opt_temp.in -p cys.parm7 -c cys_opt_all.rst7 -ref cys_opt_all.rst7 -o opt_temp.out -r cys_opt_temp.rst7 -x opt_temp.mdcoord -inf opt_temp.mdinfo
