#!/bin/bash
# Direct approach for TritonRoute using direct command execution
# with proper error handling and exit on failures

# Custom error handling - NOT using set -e for better resilience
# We'll handle errors manually in critical sections instead

# Error handling function for critical failures only
handle_critical_error() {
  local exit_code=$?
  echo -e "\n❌ Critical error detected (code $exit_code). Exiting script." >&2
  exit $exit_code
}

# Only trap truly fatal errors, not every non-zero exit
trap 'handle_critical_error' SIGTERM SIGINT

# Default design name and run counter
DESIGN="ispd18_test1"
DESIGN_DIR=""
RUN_COUNTER=""
LOOPS=1  # Default to a single run
USE_FLOW=false  # Default to not using the full flow
DESIGN_CONFIG=""  # Default empty design config
USE_FLOW_FILES=false  # Flag for using flow-generated files

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --DESIGN=*)
      DESIGN_PATH="${1#*=}"
      # Check if it's a directory path or just a design name
      if [[ "$DESIGN_PATH" == ./* || "$DESIGN_PATH" == /* ]]; then
        # It's a path, extract the design name from the path
        DESIGN_DIR="$DESIGN_PATH"
        DESIGN=$(basename "$DESIGN_PATH")
      else
        # It's just a design name
        DESIGN="$DESIGN_PATH"
      fi
      shift
      ;;
    --run=*)
      # Allow specifying a specific run number to start from
      RUN_COUNTER="${1#*=}"
      # Ensure it's a valid number
      if ! [[ "$RUN_COUNTER" =~ ^[0-9]+$ ]]; then
        echo "Error: Run counter must be a positive number"
        exit 1
      fi
      shift
      ;;
    --loops=*)
      # Allow specifying how many times to run TritonRoute
      LOOPS="${1#*=}"
      # Ensure it's a valid number
      if ! [[ "$LOOPS" =~ ^[0-9]+$ ]] || [[ "$LOOPS" -lt 1 ]]; then
        echo "Error: Loops must be a positive number"
        exit 1
      fi
      shift
      ;;
    -flow|--flow)
      # Enable using the full flow
      USE_FLOW=true
      shift
      ;;
    --design-config=*)
      # Allow specifying the design config file for the full flow
      DESIGN_CONFIG="${1#*=}"
      shift
      ;;
    *)
      # If no flag is provided, treat it as the design name (backward compatibility)
      if [[ -z "$DESIGN_DIR" ]]; then
        # Check if it's a directory path or just a design name
        if [[ "$1" == ./* || "$1" == /* ]]; then
          # It's a path, extract the design name from the path
          DESIGN_DIR="$1"
          DESIGN=$(basename "$1")
        else
          # It's just a design name
          DESIGN="$1"
        fi
      fi
      shift
      ;;
  esac
done

# Set up paths
SCRIPT_DIR=$(dirname "$(realpath "$0")")
FLOW_DIR="$SCRIPT_DIR/flow"
DRT_SCRIPTS_DIR="$SCRIPT_DIR/tools/OpenROAD/src/drt/src/dr/scripts"

# If design is just a name, form the path using default conventions
if [[ -z "$DESIGN_DIR" ]]; then
  DESIGN_DIR="$FLOW_DIR/$DESIGN"
fi

# Check if input files exist (LEF, DEF, guide)
DESIGN_PATH="$DESIGN_DIR"

# Check for input files
MISSING_FILES=false

if [[ ! -f "$DESIGN_PATH/$DESIGN.input.lef" ]]; then
  echo "Warning: LEF file not found at $DESIGN_PATH/$DESIGN.input.lef"
  MISSING_FILES=true
fi

if [[ ! -f "$DESIGN_PATH/$DESIGN.input.def" ]]; then
  echo "Warning: DEF file not found at $DESIGN_PATH/$DESIGN.input.def"
  MISSING_FILES=true
fi

if [[ ! -f "$DESIGN_PATH/$DESIGN.input.guide" ]]; then
  echo "Warning: Guide file not found at $DESIGN_PATH/$DESIGN.input.guide"
  MISSING_FILES=true
fi

# If files are missing, check if we should use flow mode
if [[ "$MISSING_FILES" == "true" ]]; then
  if [[ "$USE_FLOW" == "true" ]]; then
    echo "Will attempt to use full flow to generate required files"
    
    # Get design config file if not specified
    if [[ -z "$DESIGN_CONFIG" ]]; then
      for PLATFORM in "nangate45" "sky130hd" "sky130hs" "asap7"; do
        CONFIG_PATH="$FLOW_DIR/designs/$PLATFORM/$DESIGN/config.mk"
        if [[ -f "$CONFIG_PATH" ]]; then
          DESIGN_CONFIG="./designs/$PLATFORM/$DESIGN/config.mk"
          echo "Found config file: $DESIGN_CONFIG"
          break
        fi
      done
    fi
    
    if [[ -z "$DESIGN_CONFIG" ]]; then
      echo "Error: Could not find design config file. Please specify with --design-config="
      exit 1
    fi
    
    # Get platform from design config
    PLATFORM=$(dirname "$DESIGN_CONFIG" | cut -d '/' -f 3)
    DESIGN_NAME=$DESIGN
    
    # Check for existing results
    RUN_RESULTS_DIR="$FLOW_DIR/results/$PLATFORM/$DESIGN_NAME"
    if [[ -d "$RUN_RESULTS_DIR" ]]; then
      LATEST_RUN=$(find "$RUN_RESULTS_DIR" -maxdepth 1 -type d -name "run_*" | sort -V | tail -1)
      
      if [[ -n "$LATEST_RUN" && -f "$LATEST_RUN/5_1_grt.def" && -f "$LATEST_RUN/route.guide" ]]; then
        echo "Using existing results from $LATEST_RUN"
        DESIGN_PATH="$LATEST_RUN"
        DEF_FILE="$LATEST_RUN/5_1_grt.def"
        GUIDE_FILE="$LATEST_RUN/route.guide"
        
        # Find the LEF files
        PLATFORM_DIR="$FLOW_DIR/platforms/$PLATFORM"
        if [[ -f "$PLATFORM_DIR/lef/NangateOpenCellLibrary.tech.lef" ]]; then
          LEF_FILE="$PLATFORM_DIR/lef/NangateOpenCellLibrary.tech.lef"
          MACRO_LEF="$PLATFORM_DIR/lef/NangateOpenCellLibrary.macro.lef"
        elif [[ -f "$PLATFORM_DIR/lef/$PLATFORM.tech.lef" ]]; then
          LEF_FILE="$PLATFORM_DIR/lef/$PLATFORM.tech.lef"
          MACRO_LEF="$PLATFORM_DIR/lef/$PLATFORM.macro.lef"
        else
          echo "Error: Could not find LEF files for platform $PLATFORM"
          exit 1
        fi
        
        # Set flag for using multiple LEF files
        USE_FLOW_FILES=true
      else
        echo "No suitable existing run found, will run full flow"
        (cd "$FLOW_DIR" && make DESIGN_CONFIG=$DESIGN_CONFIG run_loop LOOPS=1)
        
        # Increment the run counter after running the flow once
        # to avoid overwriting the flow results in the next run
        increment_counter
        get_next_run_number
        
        # Check if run was successful
        LATEST_RUN=$(find "$RUN_RESULTS_DIR" -maxdepth 1 -type d -name "run_*" | sort -V | tail -1)
        if [[ -n "$LATEST_RUN" && -f "$LATEST_RUN/5_1_grt.def" && -f "$LATEST_RUN/route.guide" ]]; then
          echo "Using generated files from $LATEST_RUN"
          DESIGN_PATH="$LATEST_RUN"
          DEF_FILE="$LATEST_RUN/5_1_grt.def"
          GUIDE_FILE="$LATEST_RUN/route.guide"
          
          # Find the LEF files
          PLATFORM_DIR="$FLOW_DIR/platforms/$PLATFORM"
          if [[ -f "$PLATFORM_DIR/lef/NangateOpenCellLibrary.tech.lef" ]]; then
            LEF_FILE="$PLATFORM_DIR/lef/NangateOpenCellLibrary.tech.lef"
            MACRO_LEF="$PLATFORM_DIR/lef/NangateOpenCellLibrary.macro.lef"
          elif [[ -f "$PLATFORM_DIR/lef/$PLATFORM.tech.lef" ]]; then
            LEF_FILE="$PLATFORM_DIR/lef/$PLATFORM.tech.lef"
            MACRO_LEF="$PLATFORM_DIR/lef/$PLATFORM.macro.lef"
          else
            echo "Error: Could not find LEF files for platform $PLATFORM"
            exit 1
          fi
          
          # Set flag for using multiple LEF files
          USE_FLOW_FILES=true
        else
          echo "Error: Failed to generate required files with flow"
          exit 1
        fi
      fi
    else
      echo "Will run full flow to generate required files"
      (cd "$FLOW_DIR" && make DESIGN_CONFIG=$DESIGN_CONFIG run_loop LOOPS=1)
      
      # Increment the run counter after running the flow once
      # to avoid overwriting the flow results in the next run
      increment_counter
      get_next_run_number
      
      # Check if run was successful
      LATEST_RUN=$(find "$RUN_RESULTS_DIR" -maxdepth 1 -type d -name "run_*" | sort -V | tail -1)
      if [[ -n "$LATEST_RUN" && -f "$LATEST_RUN/5_1_grt.def" && -f "$LATEST_RUN/route.guide" ]]; then
        echo "Using generated files from $LATEST_RUN"
        DESIGN_PATH="$LATEST_RUN"
        DEF_FILE="$LATEST_RUN/5_1_grt.def"
        GUIDE_FILE="$LATEST_RUN/route.guide"
        
        # Find the LEF files
        PLATFORM_DIR="$FLOW_DIR/platforms/$PLATFORM"
        if [[ -f "$PLATFORM_DIR/lef/NangateOpenCellLibrary.tech.lef" ]]; then
          LEF_FILE="$PLATFORM_DIR/lef/NangateOpenCellLibrary.tech.lef"
          MACRO_LEF="$PLATFORM_DIR/lef/NangateOpenCellLibrary.macro.lef"
        elif [[ -f "$PLATFORM_DIR/lef/$PLATFORM.tech.lef" ]]; then
          LEF_FILE="$PLATFORM_DIR/lef/$PLATFORM.tech.lef"
          MACRO_LEF="$PLATFORM_DIR/lef/$PLATFORM.macro.lef"
        else
          echo "Error: Could not find LEF files for platform $PLATFORM"
          exit 1
        fi
        
        # Set flag for using multiple LEF files
        USE_FLOW_FILES=true
      else
        echo "Error: Failed to generate required files with flow"
        exit 1
      fi
    fi
  else
    echo "Error: Required input files not found, and -flow flag not provided"
    echo "Use -flow flag to attempt to generate input files from design"
    exit 1
  fi
fi

# Setup directory structure for multiple runs
BASE_LOG_DIR="$FLOW_DIR/logs/$DESIGN"
BASE_REPORT_DIR="$FLOW_DIR/reports/$DESIGN"
BASE_RESULT_DIR="$FLOW_DIR/results/$DESIGN"

# Create top-level directories
mkdir -p "$BASE_LOG_DIR" "$BASE_REPORT_DIR" "$BASE_RESULT_DIR"

# Determine the next run number with better file locking to prevent race conditions
# Check for an existing run counter file
RUN_COUNTER_FILE="$BASE_LOG_DIR/run_counter.txt"
RUN_COUNTER_LOCK="$BASE_LOG_DIR/run_counter.lock"
NEXT_RUN=1

# Function to increment the counter by 1 after each successful run
increment_counter() {
  # Create a lock file
  while ! mkdir "$RUN_COUNTER_LOCK" 2>/dev/null; do
    sleep 1
  done
  
  # Read current value and increment by 1
  if [[ -f "$RUN_COUNTER_FILE" ]]; then
    CURRENT_VAL=$(<"$RUN_COUNTER_FILE")
    echo $((CURRENT_VAL + 1)) > "$RUN_COUNTER_FILE"
  fi
  
  # Release the lock
  rmdir "$RUN_COUNTER_LOCK"
}

# Function to get the next run number without incrementing yet
get_next_run_number() {
  # Create a lock file
  while ! mkdir "$RUN_COUNTER_LOCK" 2>/dev/null; do
    echo "Waiting for lock on run counter..."
    sleep 1
  done
  
  # Now we have the lock, read the counter
  if [[ -n "$RUN_COUNTER" ]]; then
    # User specified a run number directly
    NEXT_RUN=$RUN_COUNTER
    echo "$NEXT_RUN" > "$RUN_COUNTER_FILE"
  elif [[ -f "$RUN_COUNTER_FILE" ]]; then
    # Read from existing counter file
    NEXT_RUN=$(<"$RUN_COUNTER_FILE")
  else
    # Start with run 1
    NEXT_RUN=1
    echo "$NEXT_RUN" > "$RUN_COUNTER_FILE"
  fi
  
  # Release the lock
  rmdir "$RUN_COUNTER_LOCK"
}

# Get next run number with proper locking
get_next_run_number

# Keep track of runs in a single summary file
RUN_SUMMARY_FILE="$BASE_LOG_DIR/runs_summary.txt"
echo "\nStarting run set at $(date) - runs $NEXT_RUN to $((NEXT_RUN + LOOPS - 1))" >> "$RUN_SUMMARY_FILE"

echo "Starting with run number $NEXT_RUN for $DESIGN"
echo "Will perform $LOOPS iterations"

# Function to run a single TritonRoute iteration
run_single_iteration() {
  local RUN_NUM=$1
  local ITER_NUM=$2
  local TOTAL_ITERATIONS=$3
  
  # Create run directories
  LOG_DIR="$BASE_LOG_DIR/run_$RUN_NUM"
  REPORT_DIR="$BASE_REPORT_DIR/run_$RUN_NUM"
  RESULT_DIR="$BASE_RESULT_DIR/run_$RUN_NUM"
  
  if [[ ! -d "$LOG_DIR" || ! -d "$REPORT_DIR" || ! -d "$RESULT_DIR" ]]; then
    mkdir -p "$LOG_DIR" "$REPORT_DIR" "$RESULT_DIR"
    echo "Creating run directories for $DESIGN/run_$RUN_NUM"
  fi
  
  # Log file with proper naming
  LOG_FILE="$LOG_DIR/5_2_route.log"
  
  # Generate design-specific weights file
  DESIGN_WEIGHTS_DIR="$FLOW_DIR/weights"
  mkdir -p "$DESIGN_WEIGHTS_DIR"
  
  # Create design-specific weights file path
  WEIGHTS_FILE="$DESIGN_WEIGHTS_DIR/weights_${DESIGN}.csv"
  WEIGHTS_FILE_ABS="$(realpath "$WEIGHTS_FILE")"
  
  # Determine perturbation value based on run number
  WEIGHT_GEN_STATE_FILE="$TOOLS_DIR/OpenROAD/src/drt/src/dr/scripts/weight_generator_state_${DESIGN}.txt"
  if [[ -f "$WEIGHT_GEN_STATE_FILE" ]]; then
    # Update the perturbation factor to match the run number
    # Maintain the current mode but update the perturbation value
    CURRENT_MODE=$(head -1 "$WEIGHT_GEN_STATE_FILE")
    echo "$CURRENT_MODE" > "$WEIGHT_GEN_STATE_FILE"
    echo "$RUN_NUM.0" >> "$WEIGHT_GEN_STATE_FILE"
    echo "" >> "$WEIGHT_GEN_STATE_FILE"
    echo "Setting perturbation factor to $RUN_NUM.0 for run $RUN_NUM"
  else
    # Create the state file if it doesn't exist
    echo "auto" > "$WEIGHT_GEN_STATE_FILE"
    echo "$RUN_NUM.0" >> "$WEIGHT_GEN_STATE_FILE"
    echo "" >> "$WEIGHT_GEN_STATE_FILE"
    echo "Created new state file with perturbation factor $RUN_NUM.0 for run $RUN_NUM"
  fi
  
  echo "Generating design-specific routing weights for $DESIGN..."
  if python3.9 "$DRT_SCRIPTS_DIR/weight_generator.py" "$WEIGHTS_FILE" --design "$DESIGN" > "$LOG_DIR/weights_generator.log" 2>&1; then
    echo "✓ Design-specific weights file generated: $WEIGHTS_FILE"
    # Copy to result dir for reference
    cp "$WEIGHTS_FILE" "$RESULT_DIR/weights.csv"
  else
    echo "❌ Warning: Failed to generate weights file. Using default weights."
    WEIGHTS_FILE=""
    WEIGHTS_FILE_ABS=""
  fi
  
  # Create direct tcl script that uses OpenROAD commands directly
  DRT_WRAPPER="$RESULT_DIR/drt_run_$RUN_NUM.tcl"
  
  # Create Tcl script for detailed routing
  echo "# Direct detailed routing script for $DESIGN - Run $RUN_NUM" > "$DRT_WRAPPER"
  echo "puts \"Loading design files for $DESIGN...\"" >> "$DRT_WRAPPER"
  
  if [[ "$USE_FLOW_FILES" == true ]]; then
    # Use flow-generated files with tech LEF first, then macro LEF
    echo "read_lef \"$LEF_FILE\"" >> "$DRT_WRAPPER"
    if [[ -n "$MACRO_LEF" ]]; then
      echo "read_lef \"$MACRO_LEF\"" >> "$DRT_WRAPPER"
    fi
    echo "read_def \"$DEF_FILE\"" >> "$DRT_WRAPPER"
    echo "read_guides \"$GUIDE_FILE\"" >> "$DRT_WRAPPER"
  else
    # Use standard files from the ispd test directory
    echo "read_lef \"$DESIGN_PATH/$DESIGN.input.lef\"" >> "$DRT_WRAPPER"
    echo "read_def \"$DESIGN_PATH/$DESIGN.input.def\"" >> "$DRT_WRAPPER"
    echo "read_guides \"$DESIGN_PATH/$DESIGN.input.guide\"" >> "$DRT_WRAPPER"
  fi
  
  echo "" >> "$DRT_WRAPPER"
  echo "puts \"Running detailed routing with custom parameters...\"" >> "$DRT_WRAPPER"

  # Build detailed_route command
  if [[ -n "$WEIGHTS_FILE" ]]; then
    echo "puts \"Using weight file: $WEIGHTS_FILE_ABS\"" >> "$DRT_WRAPPER"
    echo "detailed_route \\" >> "$DRT_WRAPPER"
    echo "    -verbose 3 \\" >> "$DRT_WRAPPER"
    echo "    -drc_report_iter_step 1 \\" >> "$DRT_WRAPPER" 
    echo "    -output_maze \"$RESULT_DIR/maze.log\" \\" >> "$DRT_WRAPPER"
    echo "    -output_drc \"$REPORT_DIR/violations\" \\" >> "$DRT_WRAPPER"
    echo "    -droute_end_iter 16 \\" >> "$DRT_WRAPPER"
    echo "    -or_seed 42 \\" >> "$DRT_WRAPPER"
    echo "    -or_k 10 \\" >> "$DRT_WRAPPER"
    echo "    -weight_file \"$WEIGHTS_FILE_ABS\"" >> "$DRT_WRAPPER"
  else
    echo "puts \"Using default weights\"" >> "$DRT_WRAPPER"
    echo "detailed_route \\" >> "$DRT_WRAPPER"
    echo "    -verbose 3 \\" >> "$DRT_WRAPPER"
    echo "    -drc_report_iter_step 1 \\" >> "$DRT_WRAPPER"
    echo "    -output_maze \"$RESULT_DIR/maze.log\" \\" >> "$DRT_WRAPPER"
    echo "    -output_drc \"$REPORT_DIR/violations\" \\" >> "$DRT_WRAPPER"
    echo "    -droute_end_iter 16 \\" >> "$DRT_WRAPPER"
    echo "    -or_seed 42 \\" >> "$DRT_WRAPPER"
    echo "    -or_k 10" >> "$DRT_WRAPPER"
  fi
  
  # Add output DEF writing
  echo "" >> "$DRT_WRAPPER"
  echo "puts \"Writing output DEF to $RESULT_DIR/tritonroute_output.def\"" >> "$DRT_WRAPPER"
  echo "write_def \"$RESULT_DIR/tritonroute_output.def\"" >> "$DRT_WRAPPER"
  echo "puts \"Detailed routing complete.\"" >> "$DRT_WRAPPER"
  echo "exit 0" >> "$DRT_WRAPPER"
  
  # Add a header to the log file
  echo "TritonRoute Standalone Log for $DESIGN" > "$LOG_FILE"
  echo "Started at $(date)" >> "$LOG_FILE"
  echo "=========================================" >> "$LOG_FILE"
  echo "" >> "$LOG_FILE"
  
  # Set thread count for OpenROAD - use OMP_NUM_THREADS if set, otherwise use system core count
  NUM_CORES=${OMP_NUM_THREADS:-$(nproc)}
  echo "Using $NUM_CORES CPU threads for TritonRoute"
  
  # Run OpenROAD with direct commands
  echo -e "\nRunning TritonRoute on $DESIGN/run_$RUN_NUM..."
  echo "All output will be captured in: $LOG_FILE"
  
  # Run with timeout and ensure exit on error
  (
    # Use timeout to prevent indefinite hangs (7200 seconds = 2 hours)
    set -o pipefail  # Ensure pipeline errors are captured
    timeout 7200 ./tools/OpenROAD/build/src/openroad -no_init -threads $NUM_CORES -exit "$DRT_WRAPPER" |& tee -a "$LOG_FILE"
    # Store exit status
    RUN_STATUS=$?
    
    # CRITICAL FIX: Wait a moment to ensure file system operations complete
    # This helps with network file systems and prevents race conditions
    sleep 2
    
    # Always check for violations at the end of the log
    VIOLATION_CHECK=$(tail -100 "$LOG_FILE" | grep -i "Number of violations =" | tail -1)
    COMPLETED_CHECK=$(tail -100 "$LOG_FILE" | grep -i "Completing 100%" | tail -1)
    
    # Check if output DEF was created, which indicates successful routing
    # regardless of exit code (success with warnings is common in EDA tools)
    if [ -f "$RESULT_DIR/tritonroute_output.def" ] && [ -s "$RESULT_DIR/tritonroute_output.def" ]; then
      # DEF file exists and has content - routing completed
      if [ $RUN_STATUS -ne 0 ]; then
        echo -e "\n⚠️ OpenROAD exited with code $RUN_STATUS, but output DEF was created." | tee -a "$LOG_FILE"
        echo "Violation status: $VIOLATION_CHECK" | tee -a "$LOG_FILE"
        echo "Completion status: $COMPLETED_CHECK" | tee -a "$LOG_FILE"
        echo "Considering this run successful since routing completed." | tee -a "$LOG_FILE"
        # Override status since routing actually completed
        RUN_STATUS=0
      fi
    elif [ ! -z "$COMPLETED_CHECK" ] && [ ! -z "$VIOLATION_CHECK" ]; then
      # Log shows completion even if DEF wasn't created or found
      echo -e "\n⚠️ Log shows routing completed with: $VIOLATION_CHECK" | tee -a "$LOG_FILE"
      echo "Setting run as successful based on log completion" | tee -a "$LOG_FILE"
      RUN_STATUS=0
    elif [ $RUN_STATUS -eq 124 ]; then
      echo -e "\n❌ TritonRoute timed out after 2 hours. Process terminated." | tee -a "$LOG_FILE"
      exit $RUN_STATUS
    elif [ $RUN_STATUS -ne 0 ]; then
      echo -e "\n❌ OpenROAD execution failed with code $RUN_STATUS." | tee -a "$LOG_FILE"
      exit $RUN_STATUS
    fi
  )
  local RUN_STATUS=$?
  
  # Add footer to the log
  echo "" >> "$LOG_FILE"
  echo "Finished at $(date)" >> "$LOG_FILE"
  echo "=========================================" >> "$LOG_FILE"
  
  # Remove temporary wrapper script
  rm -f "$DRT_WRAPPER"
  
  # Check if the log file was created and has content
  if [ $RUN_STATUS -eq 0 ] && [ -f "$LOG_FILE" ] && [ -s "$LOG_FILE" ]; then
    echo ""
    echo "✓ Run $RUN_NUM completed successfully"
    echo "  Log file: $LOG_FILE ($(du -h "$LOG_FILE" | cut -f1))"
    
    # Create a simple summary file
    SUMMARY_FILE="$BASE_LOG_DIR/runs_summary.txt"
    echo "Run $RUN_NUM - $(date) - $DESIGN" >> "$SUMMARY_FILE"
    
    # Extract final DRC counts
    DRC_COUNTS=$(grep -i "violation" "$LOG_FILE" | tail -5)
    if [[ -n "$DRC_COUNTS" ]]; then
      echo "  DRC Violations:" 
      echo "$DRC_COUNTS" | sed 's/^/    /'
      echo "$DRC_COUNTS" | sed 's/^/    /' >> "$SUMMARY_FILE"
    fi
    
    # Return success
    return 0
  else
    # Check if the log contains error messages
    if [ -f "$LOG_FILE" ]; then
      echo "❌ Run $RUN_NUM failed - checking for errors in log"
      ERROR_LINES=$(grep -i "error\|fatal\|\[ERROR" "$LOG_FILE" | head -10)
      if [[ -n "$ERROR_LINES" ]]; then
        echo "Found errors:"
        echo "$ERROR_LINES" | sed 's/^/    /'
      fi
    else
      echo "❌ Run $RUN_NUM failed - no log file was created"
    fi
    return 1
  fi
}

# Main loop control code
# Setup directory structure for multiple runs
BASE_LOG_DIR="$FLOW_DIR/logs/$DESIGN"
BASE_REPORT_DIR="$FLOW_DIR/reports/$DESIGN"
BASE_RESULT_DIR="$FLOW_DIR/results/$DESIGN"

# Initialize counter for successful/failed runs
success_count=0
failure_count=0

# Print the header
echo "============================================================"
echo "Running TritonRoute for $DESIGN"
echo "Performing $LOOPS iterations, starting with run $NEXT_RUN"
echo "============================================================"

# Run the specified number of iterations with better logging and error handling
for ((i=0; i<$LOOPS; i++)); do
  current_run=$((NEXT_RUN + i))
  
  # Run a single TritonRoute iteration
  if run_single_iteration "$current_run" $((i+1)) "$LOOPS"; then
    ((success_count++))
    echo "Run $current_run - $(date) - $DESIGN" >> "$RUN_SUMMARY_FILE"
    
    # Increment counter after successful run
    if [[ -z "$RUN_COUNTER" ]]; then
      increment_counter
    fi
  else
    status=$?
    ((failure_count++))
    echo -e "\n❌ Run $current_run failed with status code: $status"
    echo "Run $current_run - $(date) - $DESIGN - FAILED with status: $status" >> "$RUN_SUMMARY_FILE"
    
    # Prevent excessive cascading failures by adding a short cooling period
    if [[ $failure_count -gt 3 && $((failure_count % 3)) -eq 0 ]]; then
      echo "Multiple failures detected. Pausing for 30 seconds to cool off..." | tee -a "$RUN_SUMMARY_FILE"
      sleep 30
    fi
  fi
  
  # Add a separator between runs if we have more to go
  if [[ $((i+1)) -lt $LOOPS ]]; then
    echo -e "\n-------------------------------------------------------"
    # Sleep briefly to ensure proper timing between runs
    sleep 1
  fi
done

# Print summary if we ran multiple loops
if [[ $LOOPS -gt 1 ]]; then
  echo ""
  echo "============================================================"
  echo "TritonRoute Execution Summary"
  echo "Design: $DESIGN"
  echo "Total runs: $LOOPS"
  echo "Successful: $success_count"
  echo "Failed: $failure_count"
  echo "============================================================"
fi

# Exit with appropriate status code
if [[ $failure_count -gt 0 ]]; then
  exit 1
else
  exit 0
fi
