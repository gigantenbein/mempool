#!/bin/bash

# run experiments
application="histogram"
architecture="mempool"
result_folder=benchmark_results/${application}_${architecture}_$(date +%Y%m%d_%H%M%S)
mkdir -p $result_folder

for lrsc_size in 1
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
            # only output the cycle numbers

            grep -E "(\[DUMP])\s+[0-9]+:\s+(0xc01)" ${result_folder}/make_hardware_output.txt\
                | grep -E -o "[0-9]+$" >\
                       ${result_folder}/${architecture}_lrwait_${application}_lrsc_${lrsc_size}_nbin_${nbin}_ndraws_${ndraw}_cycles.txt

            # grep for number of LR instructions
            grep -E "(\[DUMP])\s+[0-9]+:\s+(0x063)" ${result_folder}/make_hardware_output.txt\
                | grep -E -o "[0-9]+$" >\
                       ${result_folder}/${architecture}_lrwait_${application}_lrsc_${lrsc_size}_nbin_${nbin}_ndraws_${ndraw}_lr_occurrences.txt
            times
        done
    done
done

# for mutex in 1 2
# do
#     for ndraw in 1 2 4 8 16 32
#     do
#         for nbin in 1 2 4 8 16 32
#         do
#             make -C software/apps $application nbins=$nbin ndraws=$ndraw mutex=$mutex
#             make -C hardware verilate app=$application lrwait_queue_size=$lrsc_size
#             make -C hardware trace app=$application

#             # grep for cycles in benchmark section, which is section 1
#             # only output the cycle numbers
#             grep -A 1 -h "section 1" hardware/build/*.trace | grep -E "cycles\s+[0-9]+"| grep -E -o "[0-9]+" > benchmark_results/amo_${mutex}_${application}_nbin_${nbin}_ndraws_${ndraw}_cycles.txt
#         done
#     done
# done
