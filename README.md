# NMR simulation pipeline
This is a very simple package of scripts capable of running NMR simulation pipeline from initial .mol2 file of the molecule to the final NMr graph. User only needs to specify the structure of the molecule, the .in files for the simulation (enviroment, conditions, methods of calculations etc.) and then run the script NMR.sh to get the resulting spectrum in .png format. 
> [!CAUTION]
> The current version of the program is in its testing phase. While evrything works correctly many things may be change if needed to (more files save) and more freatures may be added when more complex simulation will become necessary.
>If there is anything that you wish to be added, please write it in the **TODO** section at the bottom. More informations about how will be given there.

## Instalation
There is no necessary installation involved. Just download the directory through zip format, or create local repository and run command 

```bash
git remote add origin https://github.com/LukasDubsik/muni_final_work-NMR.git
```

Then the repository should be present in that git directory. 

## Script execution
### Before running the scripts
The files the program requires to run need to be located in the **inputs/** directory. THis directory additionaly contains two subdirectories and one file. This file is naped *sim.txt* and tells the program how to execute, what to save, where to find its files and more. Below is an example of this file for simulation of cysteine in water, which I will use throught this documentation as an example for a simulatin run and can be found in **data_inputs/cys/** directory, when examples of inputs will be present.

```bash
###Script describing the NMr simulation for the cysteone zwitterion in water enviroment (ph ~7.2-7.4)
##No spaces are expected between ':='

##The name of the starting mol2/rst7-parm7 files, will also be used to name other files during the simulation
name:=cys

##Type of input -> mol2 means that charges should be computed, 7 means parm7/rst7 already provided
input_type:=mol2

##Names for the expected *.in files for individual optimizations
tleap:=tleap.in
opt_water:=opt_water.in
opt_all:=opt_all.in
opt_temp:=opt_temp.in
opt_pres:=opt_pres.in
md:=md.in

##Additional parameters to be added when running specific programs (Some can be left if not run, otherwise error, eg. no antechamber when 7 specified in 'input_type')
##The parameters must be enclosed in "..." brackets
#Standart values :- antechamber -i $NAME.mol2 -fi mol2 -o $NAME.mol2 -fo mol2 ($NAME refers to general file naming dependent on the pipeline's progress)
antechamber:="-c bcc -nc 0 -at gaff" 
#Standart values :- parmchk2 -i $NAME.mol2 -f mol2 -o $NAME.frcmod
parmchk2:=""

##What file extensions, names should be saved and not deleted (any file and extensions bearing this name will be moved to the data_results)
#Files/extensions should be separated by ';'
extensions:=nc;mol2;rst7;parm7;frcmod;mdcrd;xyz;gjf;log
files:=
```

Any lines starting with *#* are ignored, the number is just arbitrary for cleaner text division. The rest of the parameters is described in the above code.

The .in files should be included in the **inputs/simulations/** directory, the files describing structure (be they of mol2 or rst/parm7 kind) should be in **inputs/structures/**. Please bear in mind that they must include the name given in the *sim.txt* file, so in this case we will have *cys.mol2*.

### Starting the simulation
The code itself is written fully in bash, some scripts afre called as awk or gnuplot (more on this later). There are additionally two versions: *NMR.sh* and *m_NMR.sh*. The first one is for running on cluster WOLF, the second one on metacentrum (tested on **sokar**). While both are functional, only the first one is optimized. Due to the number of jobs in metacentrum, the process of submitting the parts of the pipeline job by job is inefficient and the whole code itself should be submitted as one job to run. This requires some code changes that will be done later but it still can be run without issue (but is slower that WOLF version).

To run the script (and I will use *NMR.sh* as example from now on) do

```bash
bash NMR.sh
```

No root priviliges or nothing similar is required.

### Simulation run
During the execution of the code, the user is informed of the progress with the terminal. If checkmark is present, the part passed. If cross is present the program terminates with message of what went wrong and where. There can also be present less intense *?*, which means error that can be skipped for now but user should investigate it further afterwards.

[✔] md.in file correctly loaded.

### Simulation end
Once the program's execution ends, all the files and extensions specified to be kept are copied to the **data_results/** directory where they are stored for further analysis. The outputs from running the simulations are stored in the **logs/** subdirectory. Along with this subdirectory, alongside them are other subdirecties, each for a part of the simulation pipeline where the saved files from that part are stored. There is also the final image of the spectrum under the name *(name)_nmr.png*. 

Once again, the exmaple for cysteine is given in the results folder.

## Simulation: step by step

## TODO
   - [x] Smth
