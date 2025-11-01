#!/usr/bin/env infinity-env

set -euo pipefail

module add pmemd-cuda.MPI

mkdir -p rest2

# Generate REST2 inputs (one-time). Adjust solute mask to your solute.
genremdinputs.py \
  --mode REST2 \
  --nreps "${NREPL}" \
  --tmin 300 --tmax 500 \
  --solutemask ':1' \
  --base_mdin "${file}" \
  --prmtop "parm/${name}.parm7" \
  --inpcrd "rst/${name}_opt_pres.rst7" \
  --outdir rest2

cd rest2
mpirun -np "${NREPL}" pmemd.cuda.MPI -ng "${NREPL}" -groupfile groupfile




module add pmemd-cuda

pmemd.cuda -O -i ${file} -p ${name}.parm7 -c ${name}_opt_pres.rst7 -o ${name}_md.out -r ${name}_md.rst7 -x ${name}_md.mdcrd -inf ${name}_md.mdinfo
