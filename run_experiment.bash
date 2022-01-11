#!/bin/bash

set -e
set -o pipefail

# application to be tested
application="histogram"
architecture="mempool"
# lrwait, lrsc or colibri
type="lrwait"

result_folder=benchmark_results/${application}_${architecture}_$(date +%Y%m%d_%H%M%S)
mkdir -p $result_folder

# run experiments
for lrsc_size in 256
do
    # recompile for verilator with new lr queue size
    make -C hardware -B compile app=$application lrwait_queue_size=$lrsc_size config=$architecture
    for ndraw in 1
    do
        for nbin in 1 2 3 4 5 6 7 8 12 16 20 24 28 32 40 48 56 64 80 96 112 128
        do
            echo "arch: $architecture queue size: $lrsc_size nbins: $nbin ndraws: $ndraw"
            make -C software/apps $application nbins=$nbin ndraws=$ndraw mutex=0 config=$architecture
            make -C hardware -B simc app=$application lrwait_queue_size=$lrsc_size config=$architecture | tee ${result_folder}/make_hardware_output.txt

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
                  ${result_folder}/${architecture}_${type}${lrsc_size}_${application}_nbin_${nbin}_ndraws_${ndraw}_cycles.txt



            # grep for number of LR instructions
            grep -E "(\[DUMP])\s+[0-9]+:\s+(0x063)" ${result_folder}/make_hardware_output.txt\
                | grep -E -o "[0-9]+$" >\
                       ${result_folder}/temp2.txt

            # get core ids for LR instructions
            grep -E "(\[DUMP])\s+[0-9]+:\s+(0x063)" ${result_folder}/make_hardware_output.txt\
                | grep -E -o "\s+[0-9]+:" | grep -E -o "[0-9]+" >\
                                                 ${result_folder}/temp1.txt
            # add core id to same file
            paste -d ,, ${result_folder}/temp1.txt ${result_folder}/temp2.txt>\
                  ${result_folder}/${architecture}_${type}${lrsc_size}_${application}_nbin_${nbin}_ndraws_${ndraw}_lr_occurrences.txt

            times
        done
    done
done

# for mutex in 1 2 3
# do
#     for ndraw in 10
#     do
#         for nbin in 1 8 16 128 256
#         do
#             make -C software/apps $application nbins=$nbin ndraws=$ndraw mutex=$mutex config=$architecture
#             make -C hardware -B verilate app=$application lrwait_queue_size=1 config=$architecture | tee ${result_folder}/make_hardware_output.txt

#             # grep for cycles in output
#             grep -E "(\[DUMP])\s+[0-9]+:\s+(0xc01)" ${result_folder}/make_hardware_output.txt\
#                 | grep -E -o "[0-9]+$" >\
#                        ${result_folder}/temp2.txt

#             # get core ids for cycles
#             grep -E "(\[DUMP])\s+[0-9]+:\s+(0xc01)" ${result_folder}/make_hardware_output.txt\
#                 | grep -E -o "\s+[0-9]+:" | grep -E -o "[0-9]+" >\
#                                                  ${result_folder}/temp1.txt

#             # add core id to same file
#             paste -d ,, ${result_folder}/temp1.txt ${result_folder}/temp2.txt>\
#                   ${result_folder}/${architecture}_mutex${mutex}_${application}_nbin_${nbin}_ndraws_${ndraw}_cycles.txt

#             times
#         done
#     done
# done
