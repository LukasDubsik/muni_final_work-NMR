#!/usr/bin/env infinity-env

module add amber

antechamber -i ${name}.mol2 -fi mol2 -o ${name}_charges.mol2 -fo mol2 
