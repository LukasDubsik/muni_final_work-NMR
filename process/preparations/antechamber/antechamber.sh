#!/usr/bin/env infinity-env

module add amber

antechamber -i cys.mol2 -fi mol2 -o cys_charges.mol2 -fo mol2 
-c bcc -nc 0 -at gaff
