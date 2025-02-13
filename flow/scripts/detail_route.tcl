utl::set_metrics_stage "detailedroute__{}"
source $::env(SCRIPTS_DIR)/load.tcl
load_design 5_1_grt.odb 5_1_grt.sdc
if {![grt::have_routes]} {
  error "Global routing failed, run `make gui_grt` and load $::global_route_congestion_report \
        in DRC viewer to view congestion"
}
erase_non_stage_variables route
set_propagated_clock [all_clocks]

# Get absolute path to OpenROAD tools directory
set flow_dir [file normalize [file dirname [info script]]]
set root_dir [file normalize [file join $flow_dir ../]]
set scripts_dir [file normalize [file join $root_dir tools OpenROAD src drt src dr scripts]]
set weight_file ""

puts "=== Weight Generation Debug ==="
puts "Current directory: [pwd]"
puts "Flow directory: $flow_dir"
puts "Root directory: $root_dir"
puts "Scripts directory: $scripts_dir"
puts "Scripts directory exists: [file exists $scripts_dir]"
puts "Scripts directory readable: [file readable $scripts_dir]"

# Always generate new weights
set weights_file [file normalize [file join $flow_dir "weights.csv"]]
puts "Generating new weights..."

if {[catch {
    puts "Running weight generator script..."
    set python_output [exec python3 $scripts_dir/weight_generator.py $weights_file]
    puts "Python script output:"
    puts $python_output
    
    if {[file exists $weights_file]} {
        puts "Weight file generated successfully at: $weights_file"
        set weight_file $weights_file
    } else {
        error "Weight file was not created at $weights_file"
    }
} result]} {
    puts "Error: Failed to generate weights:"
    puts "Error message: $result"
    error "Weight generation failed. Cannot proceed with routing."
}

puts "Final weight file path: $weights_file"

append additional_args " -weight_file $weight_file"
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

# Process DETAILED_ROUTE_ARGS to handle -output_drc and -weight_file paths
set drc_report_path "$::env(REPORTS_DIR)/5_route_drc.rpt"
set maze_log_path "$::env(RESULTS_DIR)/maze.log"

if {[env_var_exists_and_non_empty DETAILED_ROUTE_ARGS]} {
    set args_list [split $::env(DETAILED_ROUTE_ARGS)]
    set new_args {}
    
    # Process each argument
    for {set i 0} {$i < [llength $args_list]} {incr i} {
        set arg [lindex $args_list $i]
        if {$arg eq "-output_drc"} {
            # Get the next argument (the filename)
            incr i
            set filename [lindex $args_list $i]
            # Update the DRC report path to be in reports directory
            set drc_report_path [file join $::env(REPORTS_DIR) $filename]
        } elseif {$arg eq "-weight_file"} {
            # Get the next argument (the filename)
            incr i
            set filename [lindex $args_list $i]
            # If it's a relative path, make it relative to flow directory
            if {[file pathtype $filename] eq "relative"} {
                lappend new_args $arg [file join $flow_dir $filename]
            } else {
                lappend new_args $arg $filename
            }
        } else {
            lappend new_args $arg
        }
    }
    set arguments [concat $additional_args $new_args]
} else {
    set arguments [concat $additional_args {-drc_report_iter_step 5}]
}

set all_args [concat [list \
  -output_drc $drc_report_path \
  -output_maze $maze_log_path] \
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
