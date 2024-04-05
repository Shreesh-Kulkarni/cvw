#!/usr/bin/python 
##################################################
## coremark_sweep.py

## Written: Shreesh Kulkarni, kshreesh5@gmail.com
## Created: 20 March 2024
## Modified: 5 April 2024
## Purpose: Wally  Coremark sweep Script for both 32 and 64 bit configs with csv file extraction. 
 
## Documentation: 

# A component of the CORE-V-WALLY configurable RISC-V project.
# https://github.com/openhwgroup/cvw
 
# Copyright (C) 2021-23 Harvey Mudd College & Oklahoma State University
#
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Licensed under the Solderpad Hardware License v 2.1 (the “License”); you may not use this file 
# except in compliance with the License, or, at your option, the Apache License version 2.0. You 
# may obtain a copy of the License at

# https://solderpad.org/licenses/SHL-2.1/

# Unless required by applicable law or agreed to in writing, any work distributed under the 
# License is distributed on an “AS IS” BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, 
# either express or implied. See the License for the specific language governing permissions 
# and limitations under the License.
###########################################################################################


import os
import re
import csv
# list of architectures to run. 
arch32_list = [
    "rv32gc_zba_zbb_zbc",
    "rv32im_zicsr_zba_zbb_zbc",
    "rv32gc",
    "rv32imc_zicsr",
    "rv32im_zicsr",
    "rv32i_zicsr"
]
#uncomment this array for 64bit configurations
#arch64_list = [                               
#    "rv64gc_zba_zbb_zbc",
#    "rv64im_zicsr_zba_zbb_zbc",
#    "rv64gc",
#    "rv64imc_zicsr",
#    "rv64im_zicsr",
#    "rv64i_zicsr"
#]

xlen_value = '32'
#xlen_value = '64' #uncomment this for 64 bit. 
# Define regular expressions to match the desired fields
mt_regex = r"Elapsed MTIME: (\d+).*?Elapsed MINSTRET: (\d+).*?COREMARK/MHz Score: [\d,]+ / [\d,]+ = (\d+\.\d+).*?CPI: \d+ / \d+ = (\d+\.\d+).*?Load Stalls (\d+).*?Store Stalls (\d+).*?D-Cache Accesses (\d+).*?D-Cache Misses (\d+).*?I-Cache Accesses (\d+).*?I-Cache Misses (\d+).*?Branches (\d+).*?Branches Miss Predictions (\d+).*?BTB Misses (\d+).*?Jump and JR (\d+).*?RAS Wrong (\d+).*?Returns (\d+).*?BP Class Wrong (\d+)"
#cpi_regex = r"CPI: \d+ / \d+ = (\d+\.\d+)"
#cmhz_regex = r"COREMARK/MHz Score: [\d,]+ / [\d,]+ = (\d+\.\d+)"
# Open a CSV file to write the results
with open('coremark_results.csv', mode='w', newline='') as csvfile:
    fieldnames = ['Architecture', 'MTIME','MINSTRET','CM / MHz','CPI','Load Stalls','Store Stalls','D$ Accesses',
                    'D$ Misses','I$ Accesses','I$ Misses','Branches','Branch Mispredicts','BTB Misses',
                    'Jump/JR','RAS Wrong','Returns','BP Class Pred Wrong']
    writer = csv.DictWriter(csvfile, fieldnames=fieldnames)

    writer.writeheader()

    # Loop through each architecture and run the make commands
    for arch in arch32_list:
        os.system("make clean")
        make_all = f"make all XLEN={xlen_value} ARCH={arch}"
        os.system(make_all)

        make_run = f"make run XLEN={xlen_value} ARCH={arch}"
        output = os.popen(make_run).read()  # Capture the output of the command

        # Extract the Coremark values using regular expressions
        mt_match = re.search(mt_regex, output,re.DOTALL)
        #cpi_match = re.search(cpi_regex,output,re.DOTALL)
        #cmhz_match = re.search(cmhz_regex,output,re.DOTALL)
        #minstret_match = re.search(minstret_regex,output)

        # Write the architecture and extracted values to the CSV file
    
        mtime = mt_match.group(1)
        minstret= mt_match.group(2)
        cmhz= mt_match.group(3)
        cpi= mt_match.group(4)
        lstalls= mt_match.group(5)
        swtalls= mt_match.group(6)
        dacc= mt_match.group(7)
        dmiss= mt_match.group(8)
        iacc= mt_match.group(9)
        imiss= mt_match.group(10)
        br= mt_match.group(11)
        brm= mt_match.group(12)
        btb= mt_match.group(13)
        jmp= mt_match.group(14)
        ras= mt_match.group(15)
        ret= mt_match.group(16)
        bpc= mt_match.group(17)
        #minstret = mt_instret_match.group(2)
        writer.writerow({'Architecture': arch, 'MTIME': mtime,'MINSTRET':minstret,'CM / MHz':cmhz,'CPI':cpi,
                            'Load Stalls':lstalls,
                            'Store Stalls':swtalls,'D$ Accesses':dacc,'D$ Misses':dmiss,'I$ Accesses':iacc,'I$ Misses':imiss,
                            'Branches':br,'Branch Mispredicts':brm,'BTB Misses':btb,'Jump/JR':jmp,'RAS Wrong':ras,'Returns':ret,'BP Class Pred Wrong':bpc})
