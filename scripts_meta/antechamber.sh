#!/bin/bash -l

module add amber-14

antechamber -i ${name}.mol2 -fi mol2 -o ${name}_charges.mol2 -fo mol2 
