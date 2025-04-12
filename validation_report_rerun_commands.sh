#!/bin/bash

# Commands to rerun problematic designs

# incomplete: nangate45/aes run_282
rm -rf flow/logs/nangate45/aes/base/run_282 flow/results/nangate45/aes/base/run_282 flow/reports/nangate45/aes/base/run_282
nohup ./dr_flow.sh --DESIGN_CONFIG=designs/nangate45/aes/config.mk --flow --run=282 --mode=completely_random

# incomplete: nangate45/bp_be run_381
rm -rf flow/logs/nangate45/bp_be/base/run_381 flow/results/nangate45/bp_be/base/run_381 flow/reports/nangate45/bp_be/base/run_381
nohup ./dr_flow.sh --DESIGN_CONFIG=designs/nangate45/bp_be_top/config.mk --flow --run=381 --mode=completely_random

# incomplete: nangate45/bp_multi run_667
rm -rf flow/logs/nangate45/bp_multi/base/run_667 flow/results/nangate45/bp_multi/base/run_667 flow/reports/nangate45/bp_multi/base/run_667
nohup ./dr_flow.sh --DESIGN_CONFIG=designs/nangate45/bp_multi_top/config.mk --flow --run=667 --mode=completely_random

# nonzero_drv_954: nangate45/bp_multi run_667
rm -rf flow/logs/nangate45/bp_multi/base/run_667 flow/results/nangate45/bp_multi/base/run_667 flow/reports/nangate45/bp_multi/base/run_667
nohup ./dr_flow.sh --DESIGN_CONFIG=designs/nangate45/bp_multi_top/config.mk --flow --run=667 --mode=completely_random

