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
save_as:=cys1

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
The code itself is written fully in bash, some scripts afre called as awk or gnuplot (more on this later). There are additionally two versions: *NMR.sh* and *m_NMR.sh*. The first one is for running on cluster WOLF, the second one on metacentrum (tested on **sokar**). Both are currently functional and working. 
To run the script (and I will use *NMR.sh* as example from now on) do

```bash
bash NMR.sh
```

No root priviliges or similar is required.

### Simulation run
During the execution of the code, the user is informed of the progress with the terminal. If checkmark is present, the part passed. If cross is present the program terminates with message of what went wrong and where. There can also be present less intense *?*, which means error that can be skipped for now but user should investigate it further afterwards.

[✔] md.in file correctly loaded.

### Simulation end
Once the program's execution ends, all the files and extensions specified to be kept are copied to the **data_results/** directory where they are stored for further analysis. The outputs from running the simulations are stored in the **logs/** subdirectory. Along with this subdirectory, alongside them are other subdirecties, each for a part of the simulation pipeline where the saved files from that part are stored. There is also the final image of the spectrum under the name *(name)_nmr.png* in **spectrum** directory. 

The full save is present under the the *save_as* name for replication. Pure data for visualization are zipped based on the save files and extensions given above in *sim.txt*.

The example nor the data_results folder is present due to size limits for files on github.

## Simulation: step by step
Here I will briefly describe the individual parts of the simulation itself. Some of the examples of what the parts are doing are voluntary, as the .in files can be modified for each input into the system, but the order of their running is always the same.

### Checking integrity of the input
Before the simulation itself can even start, the presence and validity of the input files is controlled. This si to prevent possibility of incorrect or missing input down the line. 

```bash
Checking the presence of necessary files:
		[✔] Input file inputs/sim.txt found.
		[✔] Name of the files is set to 'cys'.
		[✔] All necessary files found for input_type 'mol2'.
		 Checking if .in files present!
			[✔] Input file tleap.in found in inputs/simulation/.
			[✔] Input file opt_water.in found in inputs/simulation/.
			[✔] Input file opt_all.in found in inputs/simulation/.
			[✔] Input file opt_temp.in found in inputs/simulation/.
			[✔] Input file opt_pres.in found in inputs/simulation/.
			[✔] Input file md.in found in inputs/simulation/.
		 Checking if necessary .sh files present for input_type 'mol2'!
			[✔] antechamber specified and will be run as
				 antechamber -i cys.mol2 -fi mol2 -o cys_charges.mol2 -fo mol2 -c bcc -nc 0 -at gaff
			[✔] parmchk2 specified and will be run as
				 parmchk2 -i cys_charges.mol2 -f mol2 -o cys.frcmod
		[✔] Extensions to be saved are set to 'nc;mol2;rst7;parm7;frcmod;mdcrd;xyz;gjf;log'.
		[✔] Files to be saved are set to ''.
```

As can be seen, all .in files required by our parametrs have been found, .sh file specification given correctly, so were the names of extensions and files to be saved.

### Structure conversion
If *mol2* option was specified, the starting structural file is firstly converted to rst7/parm7 files for use by `pmemd` program.

```bash
Starting with structure conversion from .mol2 to .rst7/.parm7 format.
		 Running antechamber...
			[✔] Starting enviroment created succesfully
			[✔] Job 18130 submitted succesfully, waiting for it to finish.
			[✔] antechamber.sh finished successfully, cys_charges.mol2 found.
			[✔] Antechamber finished successfully.
		 Running parmchk2...
			[✔] Starting enviroment created succesfully
			[✔] Job 18131 submitted succesfully, waiting for it to finish.
			[✔] parmchk2.sh finished successfully, cys.frcmod found.
			[✔] Parmchk2 finished successfully.
		 Fixing using nemesis(obabel)...
			[✔] Nemesis fix succesfull!
		 Running tleap...
			[✔] tleap.in file correctly loaded.
			[✔] Starting enviroment created succesfully
			[✔] Job 18132 submitted succesfully, waiting for it to finish.
			[✔] tleap.sh finished successfully, cys.rst7 found.
			[✔] Tleap finished successfully.
		[✔] Structure conversion finished successfully, proceeding to optimizations and MD simulations.
```

This means running antechamber to get charges, parmchk2 to get necessary additional data, nemesis fix to correct the possibily incorrect format of *mol2* from running antechmaber and lastly tleap to add the water enviroment, combine the files, and present the much need rst7/parm7 format.

### Equilibration

When the initial enviroment is fully generated, we can start the process of equilibration to achieve stable start before the md simulation itself.
```bash
Starting with optimizations...
		 Running water optimization...
			[✔] opt_water.in file correctly loaded.
			[✔] Starting enviroment created succesfully
			[✔] Job 18133 submitted succesfully, waiting for it to finish.
			[✔] opt_water.sh finished successfully, cys_opt_water.rst7 found.
			[✔] Optimization of water finished successfully.
		 Running full optimization...
			[✔] opt_all.in file correctly loaded.
			[✔] Starting enviroment created succesfully
			[✔] Job 18134 submitted succesfully, waiting for it to finish.
			[✔] opt_all.sh finished successfully, cys_opt_all.rst7 found.
			[✔] Full optimization finished successfully.
		 Running temperature equilibration...
			[✔] opt_temp.in file correctly loaded.
			[✔] Starting enviroment created succesfully
			[✔] Job 18135 submitted succesfully, waiting for it to finish.
			[✔] opt_temp.sh finished successfully, cys_opt_temp.rst7 found.
			[✔] Temperature equilibration finished successfully.
		 Running pressure equilibration...
			[✔] opt_pres.in file correctly loaded.
			[✔] Starting enviroment created succesfully
			[✔] Job 18136 submitted succesfully, waiting for it to finish.
			[✔] opt_pres.sh finished successfully, cys_opt_pres.rst7 found.
			[✔] Pressure equilibration finished successfully.
```
The steps themselve are self explanatory.

### Md simulation
Continues where the pressure equilibration ended up and runs the md simulation

```bash
Starting with the final MD simulation...
			[✔] md.in file correctly loaded.
			[✔] Starting enviroment created succesfully
			[✔] Job 18137 submitted succesfully, waiting for it to finish.
			[✔] md.sh finished successfully, cys_md.rst7 found.
			[✔] MD simulation finished successfully.
```

### Spectrum generation
Is split into multiple steps. The first one is running cpptraj to extract the closest water molecules and extracts 100 frames of the run for running the NMR simulation.

```bash
Running cpptraj to sample the MD simulation...
			[✔] cpptraj.in file correctly loaded.
			[✔] Starting enviroment created succesfully
			[✔] Job 18138 submitted succesfully, waiting for it to finish.
			[✔] cpptraj.sh finished successfully, cys_frame.xyz found.
			[✔] cpptraj finished successfully.
```

Since cpptraj outputs singular, large .xyz file, it is necessary to separate it into separate .xyz files, which are then converted to *.gjf* format to be run by gaussian.

```bash
Splitting the frames and converting to .gjf format...
			[✔] Frames split successfully.
			[✔] Conversion to .gjf format successful.
```

Then we can finally run the gaussian itself on each file. This is done paralelly to save time and 100 jobs are run at once.

```bash
Running Gaussian NMR calculations...
			[✔] Gaussian NMR calculations finished successfully
```

Lastly, the necessary data is extract from the resulting *logs*, averaged, and plotted by *gnuplot* into a resulting NMR spectrum

```bash
Plotting the final NMR spectrum...
			[✔] Number of atoms in the molecule set to 15, sigma for TMS set to 32.2.
			[✔] All necessary files copied to plotting directory.
			[✔] Log file converted to plot data.
			[✔] Plotting the NMR spectrum successful.
```

As mentioned previosuly, the results are then posted to **data_results/(name)**.

## TODO
   - [ ] Ability that when programs terminates prematurely we can start from the place of termination instead of rerunning the whole ciode from teh start
   - [ ] Rework the metacentrum file *m_NMR.sh* to be inputted as single job and be run as such
   - [ ] Extend the .sh file extensions inside *sim.txt*
   - [ ] Give ability to modify gaussian file generation
