#!/bin/bash

# crash script when a command has a non zero return value
set -e
set -o pipefail

# run experiments
application="load_test"
architecture="mempool"
result_folder=benchmark_results/${application}_${architecture}_$(date +%Y%m%d_%H%M%S)
mkdir -p $result_folder

for lrsc_size in 1 2 4 8 16 128 256
do
    # recompile for verilator with new lr queue size
    make -C hardware -B compile app=$application lrwait_queue_size=$lrsc_size config=$architecture
    for other_core_idle in 0
    do
        for matrixcores in 8 16 32 64 128
        do
            for nbin in 128
            do
                echo "arch: $architecture queue size: $lrsc_size nbins: $nbin ndraws: $ndraw"
                make -B -C software/apps $application nbins=$nbin mutex=0 config=$architecture matrixcores=$matrixcores other_core_idle=$other_core_idle
                make -C hardware -B verilate app=$application lrwait_queue_size=$lrsc_size config=$architecture | tee ${result_folder}/make_hardware_output.txt

                # grep for cycles in output
                grep -E "(\[DUMP])\s+[0-9]+:\s+(0xc01)" ${result_folder}/make_hardware_output.txt\
                    | grep -E -o "[0-9]+$" >\
                           ${result_folder}/temp2.txt

                # get core ids for cycles
                grep -E "(\[DUMP])\s+[0-9]+:\s+(0xc01)" ${result_folder}/make_hardware_output.txt\
                    | grep -E -o "\s+[0-9]+:" | grep -E -o "[0-9]+" >\
                                                     ${result_folder}/temp1.txt
            
                # add core id to same file
                paste -d ,, ${result_folder}/temp1.txt ${result_folder}/temp2.txt>\
                      ${result_folder}/${architecture}_lrwait${lrsc_size}_${application}_nbin_${nbin}_matrixcores_${matrixcores}_other_core_idle_${other_core_idle}_cycles.txt
                
                times
            done
        done
    done
done


# other core is idle
for lrsc_size in 256
do
    # recompile for verilator with new lr queue size
    make -C hardware -B compile app=$application lrwait_queue_size=$lrsc_size config=$architecture
    for other_core_idle in 1
    do
        for matrixcores in 8 16 32 64 128
        do
            for nbin in 128
            do
                echo "arch: $architecture queue size: 0 nbins: $nbin ndraws: $ndraw"
                make -B -C software/apps $application nbins=$nbin mutex=0 config=$architecture matrixcores=$matrixcores other_core_idle=$other_core_idle
                make -C hardware -B verilate app=$application lrwait_queue_size=lrsc_size config=$architecture | tee ${result_folder}/make_hardware_output.txt

                # grep for cycles in output
                grep -E "(\[DUMP])\s+[0-9]+:\s+(0xc01)" ${result_folder}/make_hardware_output.txt\
                    | grep -E -o "[0-9]+$" >\
                           ${result_folder}/temp2.txt

                # get core ids for cycles
                grep -E "(\[DUMP])\s+[0-9]+:\s+(0xc01)" ${result_folder}/make_hardware_output.txt\
                    | grep -E -o "\s+[0-9]+:" | grep -E -o "[0-9]+" >\
                                                     ${result_folder}/temp1.txt
            
                # add core id to same file
                paste -d ,, ${result_folder}/temp1.txt ${result_folder}/temp2.txt>\
                      ${result_folder}/${architecture}_lrwait0_${application}_nbin_${nbin}_matrixcores_${matrixcores}_other_core_idle_${other_core_idle}_cycles.txt
                
                times
            done
        done
    done
done

