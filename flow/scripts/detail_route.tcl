utl::set_metrics_stage "detailedroute__{}"
source $::env(SCRIPTS_DIR)/load.tcl
load_design 5_1_grt.odb 5_1_grt.sdc
if {![grt::have_routes]} {
  error "Global routing failed, run `make gui_grt` and load $::global_route_congestion_report \
        in DRC viewer to view congestion"
}
erase_non_stage_variables route
set_propagated_clock [all_clocks]

# Generate custom weights for this design run
set weight_file ""
set additional_args ""

# Get absolute path to OpenROAD tools directory
set flow_dir [file normalize [file dirname [info script]]]
set root_dir [file normalize [file join $flow_dir ../]]
set scripts_dir [file normalize [file join $root_dir tools OpenROAD src drt src dr scripts]]

puts "=== Weight Generation Debug ==="
puts "Current directory: [pwd]"
puts "Flow directory: $flow_dir"
puts "Root directory: $root_dir"
puts "Scripts directory: $scripts_dir"
puts "Scripts directory exists: [file exists $scripts_dir]"
puts "Scripts directory readable: [file readable $scripts_dir]"

# Ensure scripts directory exists and is readable
if {[file exists $scripts_dir] && [file readable $scripts_dir]} {
    # Generate weights in OpenROAD scripts directory
    set weight_path [file normalize [file join $scripts_dir "strategy_costweights.csv"]]
    
    puts "Scripts directory: $scripts_dir"
    puts "Weight path: $weight_path"
    puts "Python script exists: [file exists [file join $scripts_dir weight_generator.py]]"
    
    if {[catch {
        puts "Attempting to run Python script..."
        set python_output [exec python3 $scripts_dir/weight_generator.py $weight_path]
        puts "Python script output:"
        puts $python_output
        
        # Check if file exists and has content
        if {[file exists $weight_path]} {
            puts "Weight file exists, size: [file size $weight_path]"
            set weight_file $weight_path
            puts "Generated custom routing weights at $weight_file"
        } else {
            puts "Error: Weight file was not created at $weight_path"
        }
    } result]} {
        puts "Warning: Failed to generate custom weights:"
        puts "Error message: $result"
        if {[file exists $weight_path] && [file readable $weight_path]} {
            set weight_file $weight_path
            puts "Using existing weights from $weight_file"
        }
    }
}

if {$weight_file ne ""} {
    puts "Final weight file path: $weight_file"
    append additional_args " -weight_file $weight_file"
} else {
    puts "Warning: No weight file was set"
}

append_env_var additional_args dbProcessNode -db_process_node 1
append_env_var additional_args OR_SEED -or_seed 1
append_env_var additional_args OR_K -or_k 1
append_env_var additional_args MIN_ROUTING_LAYER -bottom_routing_layer 1
append_env_var additional_args MAX_ROUTING_LAYER -top_routing_layer 1
append_env_var additional_args VIA_IN_PIN_MIN_LAYER -via_in_pin_bottom_layer 1
append_env_var additional_args VIA_IN_PIN_MAX_LAYER -via_in_pin_top_layer 1
append_env_var additional_args DISABLE_VIA_GEN -disable_via_gen 0
append_env_var additional_args REPAIR_PDN_VIA_LAYER -repair_pdn_vias 1
append_env_var additional_args DETAILED_ROUTE_END_ITERATION -droute_end_iter 1

append additional_args " -verbose 1"

# DETAILED_ROUTE_ARGS is used when debugging detailed, route, e.g. append
# "-droute_end_iter 5" to look at routing violations after only 5 iterations,
# speeding up iterations on a problem where detailed routing doesn't converge
# or converges slower than expected.
#
# If DETAILED_ROUTE_ARGS is not specified, save out progress report a
# few iterations after the first two iterations. The first couple of
# iterations would produce very large .drc reports without interesting
# information for the user.
#
# The idea is to have a policy that gives progress information soon without
# having to go spelunking in Tcl or modify configuration scripts, while
# not having to wait too long or generating large useless reports.

set arguments [expr {[env_var_exists_and_non_empty DETAILED_ROUTE_ARGS] ? $::env(DETAILED_ROUTE_ARGS) : \
 [concat $additional_args {-drc_report_iter_step 5}]}]

set all_args [concat [list \
  -output_drc $::env(REPORTS_DIR)/5_route_drc.rpt \
  -output_maze $::env(RESULTS_DIR)/maze.log] \
  $arguments]

log_cmd detailed_route {*}$all_args

fast_route

if {![env_var_equals SKIP_ANTENNA_REPAIR_POST_DRT 1]} {
  set repair_antennas_iters 1
  if {[repair_antennas]} {
    detailed_route {*}$all_args
  }
  while {[check_antennas] && $repair_antennas_iters < 5} {
    repair_antennas
    detailed_route {*}$all_args
    incr repair_antennas_iters
  }
}

if { [env_var_exists_and_non_empty POST_DETAIL_ROUTE_TCL] } {
  source $::env(POST_DETAIL_ROUTE_TCL)
}

check_antennas -report_file $env(REPORTS_DIR)/drt_antennas.log

if {![design_is_routed]} {
  error "Design has unrouted nets."
}

write_db $::env(RESULTS_DIR)/5_2_route.odb
