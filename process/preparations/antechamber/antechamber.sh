#!/usr/bin/env infinity-env

if [[ -z "$1" ]]; then
  echo -e "\t\t\t[$CROSS] ${RED} No name given to the script to run with!${NC}"
  exit 1
fi

module add amber

antechamber -i ${1}.mol2 -fi mol2 -o ${1}_charges.mol2 -fo mol2