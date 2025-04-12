#!/bin/bash
# Detailed Router Flow Script (dr_flow.sh)
# This script runs TritonRoute with proper directory handling and run counting

# --- Process tracking and cleanup ---
DECLARE_ARRAY_IF_NEEDED="declare -a OPENROAD_PIDS 2>/dev/null || true"
eval "$DECLARE_ARRAY_IF_NEEDED"

# --- Error and signal handling ---
cleanup_processes() {
  local signal=$1
  local exit_code=${2:-1}
  echo -e "\n🛑 Received signal $signal. Cleaning up processes..."
  
  # Terminate any running OpenROAD processes gracefully
  for pid in "${OPENROAD_PIDS[@]}"; do
    if ps -p "$pid" >/dev/null 2>&1; then
      echo "Sending SIGTERM to OpenROAD process $pid"
      kill -TERM "$pid" 2>/dev/null || true
      # Give it a moment to terminate gracefully
      sleep 2
      # Force kill if still running
      if ps -p "$pid" >/dev/null 2>&1; then
        echo "Process $pid still running, sending SIGKILL"
        kill -9 "$pid" 2>/dev/null || true
      fi
    fi
  done
  
  # Clean up any NFS temporary files
  find "$FLOW_DIR/logs" -name ".nfs*" -delete 2>/dev/null || true
  
  echo "Cleanup complete."
  exit "$exit_code"
}

handle_error() {
  local exit_code=$?
  echo -e "\n❌ Critical error detected (code $exit_code). Exiting script." >&2
  cleanup_processes "ERROR" "$exit_code"
}

# Handle various signals to ensure clean termination
trap 'cleanup_processes SIGTERM 1' SIGTERM
trap 'cleanup_processes SIGINT 2' SIGINT
trap 'cleanup_processes SIGHUP 1' SIGHUP

# --- Default values ---
DESIGN=""
PLATFORM=""
DESIGN_CONFIG=""
USE_FLOW=false
LOOPS=1
RUN_COUNTER=""
ALTERNATE_DESIGN_NAME=""

# --- Parse command line arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --DESIGN=*)
      DESIGN_PATH="${1#*=}"
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
      RUN_COUNTER="${1#*=}"
      if ! [[ "$RUN_COUNTER" =~ ^[0-9]+$ ]]; then
        echo "Error: Run counter must be a positive number"
        exit 1
      fi
      shift
      ;;
    --loops=*)
      LOOPS="${1#*=}"
      if ! [[ "$LOOPS" =~ ^[0-9]+$ ]] || [[ "$LOOPS" -lt 1 ]]; then
        echo "Error: Loops must be a positive number"
        exit 1
      fi
      shift
      ;;
    -flow|--flow)
      USE_FLOW=true
      shift
      ;;
    --design-config=*|--design_config=*|--DESIGN_CONFIG=*)
      DESIGN_CONFIG="${1#*=}"
      USE_FLOW=true
      shift
      ;;
    --mode=*)
      WEIGHT_GEN_MODE="${1#*=}"
      echo "Using weight generator mode: $WEIGHT_GEN_MODE"
      shift
      ;;
    *)
      # If no flag is provided, treat it as the design name
      if [[ -z "$DESIGN" ]]; then
        if [[ "$1" == ./* || "$1" == /* ]]; then
          DESIGN_DIR="$1"
          DESIGN=$(basename "$1")
        else
          DESIGN="$1"
        fi
      fi
      shift
      ;;
  esac
done

# --- Set up paths ---
SCRIPT_DIR=$(dirname "$(realpath "$0")")
FLOW_DIR="$SCRIPT_DIR/flow"
TOOLS_DIR="$SCRIPT_DIR/tools"
DRT_SCRIPTS_DIR="$SCRIPT_DIR/tools/OpenROAD/src/drt/src/dr/scripts"

# --- Extract design and platform from config file if specified ---
if [[ -n "$DESIGN_CONFIG" ]]; then
  # Normalize the config path
  if [[ "$DESIGN_CONFIG" == flow/* ]]; then
    NORMALIZED_CONFIG="${DESIGN_CONFIG#flow/}"
  else
    NORMALIZED_CONFIG="$DESIGN_CONFIG"
  fi
  
  CONFIG_FILE_PATH="$FLOW_DIR/$NORMALIZED_CONFIG"
  echo "Extracting information from config file: $CONFIG_FILE_PATH"
  
  if [[ -f "$CONFIG_FILE_PATH" ]]; then
    # Extract platform from config path
    if [[ "$DESIGN_CONFIG" =~ designs/([^/]+)/ ]]; then
      PLATFORM="${BASH_REMATCH[1]}"
      echo "Extracted platform from config path: $PLATFORM"
    else
      # Try to extract platform from config file
      PLATFORM=$(grep -E "^\s*(export\s+)?PLATFORM\s*=" "$CONFIG_FILE_PATH" | cut -d '=' -f 2 | tr -d ' \t')
      if [[ -n "$PLATFORM" ]]; then
        echo "Extracted platform from config file: $PLATFORM"
      fi
    fi
    
    # Extract DESIGN variables - try multiple formats
    DESIGN_NAME=$(grep -E "^\s*(export\s+)?DESIGN_NAME\s*=" "$CONFIG_FILE_PATH" | cut -d '=' -f 2 | tr -d ' \t')
    DESIGN_NICKNAME=$(grep -E "^\s*(export\s+)?DESIGN_NICKNAME\s*=" "$CONFIG_FILE_PATH" | cut -d '=' -f 2 | tr -d ' \t')
    CONFIG_DESIGN=$(grep -E "^\s*DESIGN\s*=" "$CONFIG_FILE_PATH" | cut -d '=' -f 2 | tr -d ' \t')
    
    echo "Found in config: DESIGN_NAME=$DESIGN_NAME, DESIGN_NICKNAME=$DESIGN_NICKNAME, DESIGN=$CONFIG_DESIGN"
    
    # Prioritize values for consistency with existing logs
    if [[ -n "$CONFIG_DESIGN" ]]; then
      DESIGN=$CONFIG_DESIGN
    elif [[ -n "$DESIGN_NICKNAME" ]]; then
      DESIGN=$DESIGN_NICKNAME
    elif [[ -n "$DESIGN_NAME" ]]; then
      DESIGN=$DESIGN_NAME
    fi
    
    # Store alternate names for directory checks
    if [[ -n "$DESIGN_NAME" && "$DESIGN_NAME" != "$DESIGN" ]]; then
      ALTERNATE_DESIGN_NAME=$DESIGN_NAME
    fi
    if [[ -n "$DESIGN_NICKNAME" && "$DESIGN_NICKNAME" != "$DESIGN" && "$DESIGN_NICKNAME" != "$ALTERNATE_DESIGN_NAME" ]]; then
      ALTERNATE_DESIGN_NAME=$DESIGN_NICKNAME
    fi
    
    echo "Using design name: $DESIGN"
    if [[ -n "$ALTERNATE_DESIGN_NAME" ]]; then
      echo "Will also check alternate name: $ALTERNATE_DESIGN_NAME"
    fi
  else
    echo "Error: Config file not found: $CONFIG_FILE_PATH"
    exit 1
  fi
fi

# --- Set default design if still empty ---
if [[ -z "$DESIGN" ]]; then
  echo "Warning: No design specified, using default design 'ispd18_test1'"
  DESIGN="ispd18_test1"
fi

# --- Ensure PLATFORM is set for directory structure ---
if [[ -z "$PLATFORM" ]]; then
  echo "Warning: No platform specified, checking common platforms"
  for PLATFORM_CHECK in "sky130hd" "sky130hs" "asap7" "nangate45"; do
    if [[ -d "$FLOW_DIR/platforms/$PLATFORM_CHECK" ]]; then
      PLATFORM="$PLATFORM_CHECK"
      echo "Using detected platform: $PLATFORM"
      break
    fi
  done
  
  # Last resort fallback
  if [[ -z "$PLATFORM" ]]; then
    echo "Warning: Could not detect platform, using 'nangate45' as default"
    PLATFORM="nangate45"
  fi
fi

# --- Set up directory structure with platform ---
BASE_LOG_DIR="$FLOW_DIR/logs/$PLATFORM/$DESIGN"
BASE_REPORT_DIR="$FLOW_DIR/reports/$PLATFORM/$DESIGN"
BASE_RESULT_DIR="$FLOW_DIR/results/$PLATFORM/$DESIGN"

# --- Check for alternate name directories ---
if [[ -n "$ALTERNATE_DESIGN_NAME" ]]; then
  ALT_LOG_DIR="$FLOW_DIR/logs/$PLATFORM/$ALTERNATE_DESIGN_NAME"
  ALT_RESULT_DIR="$FLOW_DIR/results/$PLATFORM/$ALTERNATE_DESIGN_NAME"
  
  # Check if main directories don't exist but alternate do
  if [[ ! -d "$BASE_RESULT_DIR" && -d "$ALT_RESULT_DIR" ]]; then
    echo "Using alternate directories for $ALTERNATE_DESIGN_NAME"
    DESIGN=$ALTERNATE_DESIGN_NAME
    BASE_LOG_DIR="$FLOW_DIR/logs/$PLATFORM/$DESIGN"
    BASE_REPORT_DIR="$FLOW_DIR/reports/$PLATFORM/$DESIGN"
    BASE_RESULT_DIR="$FLOW_DIR/results/$PLATFORM/$DESIGN"
  fi
fi

# --- Check for 'base' directories ---
if [[ -d "$BASE_RESULT_DIR/base" ]]; then
  echo "Found 'base' subdirectory structure"
  BASE_LOG_DIR="$BASE_LOG_DIR/base"
  BASE_REPORT_DIR="$BASE_REPORT_DIR/base"
  BASE_RESULT_DIR="$BASE_RESULT_DIR/base"
fi

# --- Create directories ---
mkdir -p "$BASE_LOG_DIR" "$BASE_REPORT_DIR" "$BASE_RESULT_DIR"

# --- Set up counter file paths ---
echo "DEBUG: Setting up counter file paths"
echo "DEBUG: PLATFORM=$PLATFORM, DESIGN=$DESIGN"
echo "DEBUG: FLOW_DIR=$FLOW_DIR"

# Create the platform/design structure first
PLATFORM_LOG_DIR="$FLOW_DIR/logs/$PLATFORM/$DESIGN"
echo "DEBUG: Platform log dir: $PLATFORM_LOG_DIR"

# Create this directory regardless
mkdir -p "$PLATFORM_LOG_DIR"
echo "DEBUG: Created platform log dir: $(ls -la "$PLATFORM_LOG_DIR")"

# Check if base directory exists and use it if it does
if [[ -d "$PLATFORM_LOG_DIR/base" ]]; then
  COUNTER_DIR="$PLATFORM_LOG_DIR/base"
  echo "DEBUG: Using base subdirectory: $COUNTER_DIR"
else
  # No base directory, create it
  COUNTER_DIR="$PLATFORM_LOG_DIR/base"
  mkdir -p "$COUNTER_DIR"
  echo "DEBUG: Created base directory: $COUNTER_DIR"
fi

# Now set the counter file path in this directory
RUN_COUNTER_FILE="$COUNTER_DIR/run_counter.txt"
RUN_COUNTER_LOCK="$COUNTER_DIR/run_counter.lock"

echo "DEBUG: Counter file will be at: $RUN_COUNTER_FILE"
echo "DEBUG: Counter lock will be at: $RUN_COUNTER_LOCK"

# Create an empty counter file if it doesn't exist
if [[ ! -f "$RUN_COUNTER_FILE" ]]; then
  echo "DEBUG: Counter file doesn't exist, creating it with value 1"
  echo "1" > "$RUN_COUNTER_FILE"
  echo "DEBUG: Counter file created: $(cat "$RUN_COUNTER_FILE" 2>/dev/null || echo 'FAILED')"
fi

# --- Check if we need to run flow ---
MISSING_FILES=true
DEF_FILE=""
GUIDE_FILE=""
LEF_FILE=""
MACRO_LEF=""
USE_FLOW_FILES=false

# --- Check for existing results ---
RUN_RESULTS_DIR="$BASE_RESULT_DIR"
echo "Checking for results in: $RUN_RESULTS_DIR"

# --- Look for run_1 directory first (most reliable) ---
RUN1_DIR="$RUN_RESULTS_DIR/run_1"
if [[ -d "$RUN1_DIR" ]]; then
  echo "Found run_1 directory - checking for required files"
  
  # First, check for the specific files we prefer
  if [[ -f "$RUN1_DIR/5_1_grt.def" && -f "$RUN1_DIR/route.guide" ]]; then
    echo "Found primary required files in run_1 directory"
    DEF_FILE="$RUN1_DIR/5_1_grt.def"
    GUIDE_FILE="$RUN1_DIR/route.guide"
    MISSING_FILES=false
    USE_FLOW_FILES=true
  # Check for ODB file and extract DEF if available
  elif [[ -f "$RUN1_DIR/5_1_grt.odb" && -f "$RUN1_DIR/route.guide" ]]; then
    echo "Found ODB file in run_1, extracting DEF file..."
    
    # Create a simple TCL script to extract DEF from ODB
    TMP_SCRIPT="$RUN1_DIR/extract_def.tcl"
    echo "read_db $RUN1_DIR/5_1_grt.odb" > "$TMP_SCRIPT"
    echo "write_def $RUN1_DIR/5_1_grt.def" >> "$TMP_SCRIPT"
    echo "exit" >> "$TMP_SCRIPT"
    
    # Try to find OpenROAD binary
    OPENROAD_BIN="$FLOW_DIR/../tools/install/OpenROAD/bin/openroad"
    if [[ ! -f "$OPENROAD_BIN" ]]; then
      echo "OpenROAD binary not found at expected location, trying system path..."
      OPENROAD_BIN=$(which openroad 2>/dev/null)
    fi
    
    if [[ -n "$OPENROAD_BIN" ]]; then
      echo "Extracting DEF from ODB using OpenROAD at: $OPENROAD_BIN"
      "$OPENROAD_BIN" "$TMP_SCRIPT"
      
      if [[ -f "$RUN1_DIR/5_1_grt.def" ]]; then
        echo "Successfully extracted DEF file from ODB"
        DEF_FILE="$RUN1_DIR/5_1_grt.def"
        GUIDE_FILE="$RUN1_DIR/route.guide"
        MISSING_FILES=false
        USE_FLOW_FILES=true
      else
        echo "Failed to extract DEF file from ODB"
      fi
    else
      echo "OpenROAD binary not found, cannot extract DEF from ODB"
    fi
  # Try alternative DEF files if the primary ones are missing
  elif [[ -f "$RUN1_DIR/route.guide" ]]; then
    # Guide file exists, try alternative DEF files
    GUIDE_FILE="$RUN1_DIR/route.guide"
    
    # Try these DEF files in order of preference
    for def_candidate in "$RUN1_DIR/5_route.def" "$RUN1_DIR/5_grt.def" "$RUN1_DIR/4_cts.def"; do
      if [[ -f "$def_candidate" ]]; then
        echo "Found alternate DEF file: $def_candidate"
        DEF_FILE="$def_candidate"
        MISSING_FILES=false
        USE_FLOW_FILES=true
        break
      fi
    done
    
    # Output what was found
    if [[ -n "$DEF_FILE" ]]; then
      echo "Using alternate DEF file with route.guide"
    else
      echo "Could not find a suitable DEF file despite having route.guide"
    fi
  fi
  
  # If we still don't have files, list what's there to help debug
  if [[ "$MISSING_FILES" == "true" ]]; then
    echo "Required files not found in standard locations. Directory contents:"
    ls -la "$RUN1_DIR" | grep -E "\.def$|\.guide$|\.odb$"
  fi
fi

# --- If not found in run_1, check for any run directory ---
if [[ "$MISSING_FILES" == "true" ]]; then
  LATEST_RUN=$(find "$RUN_RESULTS_DIR" -maxdepth 1 -type d -name "run_*" | sort -V | tail -1)
  if [[ -n "$LATEST_RUN" && -f "$LATEST_RUN/5_1_grt.def" && -f "$LATEST_RUN/route.guide" ]]; then
    echo "Using files from $LATEST_RUN"
    DEF_FILE="$LATEST_RUN/5_1_grt.def"
    GUIDE_FILE="$LATEST_RUN/route.guide"
    MISSING_FILES=false
    USE_FLOW_FILES=true
  fi
fi

# --- Check for LEF files when using flow files ---
if [[ "$USE_FLOW_FILES" == "true" ]]; then
  PLATFORM_DIR="$FLOW_DIR/platforms/$PLATFORM"
  if [[ -f "$PLATFORM_DIR/lef/$PLATFORM.tech.lef" ]]; then
    LEF_FILE="$PLATFORM_DIR/lef/$PLATFORM.tech.lef"
    MACRO_LEF="$PLATFORM_DIR/lef/$PLATFORM.macro.lef"
  elif [[ -d "$PLATFORM_DIR/lef" ]]; then
    TECH_LEF=$(find "$PLATFORM_DIR/lef" -name "*.tech.lef" | head -1)
    MACRO_LEF_FILES=$(find "$PLATFORM_DIR/lef" -name "*.macro.lef" -o -name "*.cells.lef" | tr '\n' ' ')
    
    if [[ -n "$TECH_LEF" && -n "$MACRO_LEF_FILES" ]]; then
      LEF_FILE="$TECH_LEF"
      MACRO_LEF="$MACRO_LEF_FILES"
    fi
  fi
  
  if [[ -z "$LEF_FILE" ]]; then
    echo "Error: Could not find LEF files for platform $PLATFORM"
    exit 1
  fi
  
  echo "Using LEF files: $LEF_FILE and $MACRO_LEF"
fi

# --- Run flow if needed to generate input files ---
if [[ "$MISSING_FILES" == "true" && "$USE_FLOW" == "true" ]]; then
  echo "Required input files not found, running flow to generate them"
  
  # Normalize config path for make
  if [[ "$DESIGN_CONFIG" == flow/* ]]; then
    MAKE_CONFIG="${DESIGN_CONFIG#flow/}"
  else
    MAKE_CONFIG="$DESIGN_CONFIG"
  fi
  
  echo "Running make with config: DESIGN_CONFIG=$MAKE_CONFIG"
  (cd "$FLOW_DIR" && make DESIGN_CONFIG=$MAKE_CONFIG run_loop LOOPS=1)

  # Add a pause to allow filesystem to sync after make completes
      echo "Pausing for 5 seconds to allow filesystem sync..."
      sleep 5

  # Check make exit code *after* the pause
  if [[ $MAKE_EXIT_CODE -ne 0 ]]; then
      echo "Error: Initial make flow failed with exit code $MAKE_EXIT_CODE"
      exit 1
  fi
  
  # Increment counter immediately after flow completes, but more robustly
  if [[ -f "$RUN_COUNTER_FILE" ]]; then
    echo "DEBUG: Counter file exists at $RUN_COUNTER_FILE"
    CURRENT_VAL=$(<"$RUN_COUNTER_FILE")
    echo "DEBUG: Current counter value is $CURRENT_VAL"
    
    # Make an atomic counter increment to avoid race conditions
    echo $((CURRENT_VAL + 1)) > "${RUN_COUNTER_FILE}.new"
    mv "${RUN_COUNTER_FILE}.new" "$RUN_COUNTER_FILE"
    
    # Verify counter was actually updated
    if [[ -f "$RUN_COUNTER_FILE" ]]; then
      NEW_VAL=$(<"$RUN_COUNTER_FILE")
      echo "DEBUG: Counter incremented to $NEW_VAL after flow completion"
      # Update NEXT_RUN with new counter value
      NEXT_RUN=$NEW_VAL
    else
      echo "ERROR: Failed to update counter file!"
    fi
  else
    echo "DEBUG: Counter file does not exist at $RUN_COUNTER_FILE"
    mkdir -p "$(dirname "$RUN_COUNTER_FILE")"
    echo "2" > "$RUN_COUNTER_FILE"
    echo "DEBUG: Created new counter file with value 2"
    NEXT_RUN=2
  fi
  
  # Check if flow generated the required files
  LATEST_RUN=$(find "$RUN_RESULTS_DIR" -maxdepth 1 -type d -name "run_*" | sort -V | tail -1)
  echo "DEBUG: Checking for files in $LATEST_RUN"
  
  # First check for DEF file
  if [[ -n "$LATEST_RUN" && -f "$LATEST_RUN/5_1_grt.def" && -f "$LATEST_RUN/route.guide" ]]; then
    echo "Flow successfully generated required files (DEF found)"
    DEF_FILE="$LATEST_RUN/5_1_grt.def"
    GUIDE_FILE="$LATEST_RUN/route.guide"
    MISSING_FILES=false
    USE_FLOW_FILES=true
  # Then check for ODB file and extract DEF if needed
  elif [[ -n "$LATEST_RUN" && -f "$LATEST_RUN/5_1_grt.odb" && -f "$LATEST_RUN/route.guide" ]]; then
    echo "Found ODB file in $LATEST_RUN, extracting DEF file..."
    
    # Create a simple TCL script to extract DEF from ODB
    TMP_SCRIPT="$LATEST_RUN/extract_def.tcl"
    echo "read_db $LATEST_RUN/5_1_grt.odb" > "$TMP_SCRIPT"
    echo "write_def $LATEST_RUN/5_1_grt.def" >> "$TMP_SCRIPT"
    echo "exit" >> "$TMP_SCRIPT"
    
    # Try to find OpenROAD binary
    OPENROAD_BIN="$FLOW_DIR/../tools/install/OpenROAD/bin/openroad"
    if [[ ! -f "$OPENROAD_BIN" ]]; then
      echo "OpenROAD binary not found at expected location, trying system path..."
      OPENROAD_BIN=$(which openroad 2>/dev/null)
    fi
    
    if [[ -n "$OPENROAD_BIN" ]]; then
      echo "Extracting DEF from ODB using OpenROAD at: $OPENROAD_BIN"
      "$OPENROAD_BIN" "$TMP_SCRIPT"
      
      if [[ -f "$LATEST_RUN/5_1_grt.def" ]]; then
        echo "Successfully extracted DEF file from ODB"
        DEF_FILE="$LATEST_RUN/5_1_grt.def"
        GUIDE_FILE="$LATEST_RUN/route.guide"
        MISSING_FILES=false
        USE_FLOW_FILES=true
      else
        echo "Failed to extract DEF file from ODB"
      fi
    else
      echo "OpenROAD binary not found, cannot extract DEF from ODB"
    fi
    
    # Find LEF files for the platform
    PLATFORM_DIR="$FLOW_DIR/platforms/$PLATFORM"
    if [[ -f "$PLATFORM_DIR/lef/$PLATFORM.tech.lef" ]]; then
      LEF_FILE="$PLATFORM_DIR/lef/$PLATFORM.tech.lef"
      MACRO_LEF="$PLATFORM_DIR/lef/$PLATFORM.macro.lef"
    elif [[ -d "$PLATFORM_DIR/lef" ]]; then
      TECH_LEF=$(find "$PLATFORM_DIR/lef" -name "*.tech.lef" | head -1)
      MACRO_LEF_FILES=$(find "$PLATFORM_DIR/lef" -name "*.macro.lef" -o -name "*.cells.lef" | tr '\n' ' ')
      
      if [[ -n "$TECH_LEF" && -n "$MACRO_LEF_FILES" ]]; then
        LEF_FILE="$TECH_LEF"
        MACRO_LEF="$MACRO_LEF_FILES"
      fi
    fi
    
    # Increment counter after successful flow to avoid overwriting run_1 in subsequent runs
    increment_counter
    # Update NEXT_RUN to reflect the incremented counter
    if [[ -f "$RUN_COUNTER_FILE" ]]; then
      NEXT_RUN=$(<"$RUN_COUNTER_FILE")
      echo "Counter incremented to: $NEXT_RUN for next run"
    fi
  else
    echo "Error: Flow failed to generate required files"
    exit 1
  fi
elif [[ "$MISSING_FILES" == "true" && "$USE_FLOW" != "true" ]]; then
  echo "Error: Required input files not found, and -flow flag not provided"
  echo "Use --design_config=<config> --flow to generate input files"
  exit 1
fi

# --- Functions for run counter management ---
increment_counter() {
  echo "DEBUG: increment_counter called"
  
  # Make sure the directory for the counter exists
  mkdir -p "$(dirname "$RUN_COUNTER_FILE")"
  
  # Try to create a lock, but don't get stuck if it fails
  if mkdir "$RUN_COUNTER_LOCK" 2>/dev/null; then
    echo "DEBUG: Got lock for counter increment"
    
    # Read current value and increment by 1
    if [[ -f "$RUN_COUNTER_FILE" ]]; then
      CURRENT_VAL=$(<"$RUN_COUNTER_FILE")
      echo "DEBUG: Current counter value is $CURRENT_VAL"
      
      # Write to a new file then move atomically
      echo $((CURRENT_VAL + 1)) > "${RUN_COUNTER_FILE}.new"
      mv "${RUN_COUNTER_FILE}.new" "$RUN_COUNTER_FILE"
      
      echo "DEBUG: Counter incremented to $((CURRENT_VAL + 1))"
    else
      echo "DEBUG: Counter file not found, creating with value 2"
      echo "2" > "$RUN_COUNTER_FILE"
    fi
    
    # Release the lock
    rmdir "$RUN_COUNTER_LOCK" 2>/dev/null || echo "DEBUG: Could not remove lock"
  else
    echo "DEBUG: Could not get lock, using direct increment"
    
    # Fallback if locking fails - use atomic operation
    if [[ -f "$RUN_COUNTER_FILE" ]]; then
      CURRENT_VAL=$(<"$RUN_COUNTER_FILE")
      echo $((CURRENT_VAL + 1)) > "${RUN_COUNTER_FILE}.new"
      mv "${RUN_COUNTER_FILE}.new" "$RUN_COUNTER_FILE"
      echo "DEBUG: Counter directly incremented to $((CURRENT_VAL + 1))"
    else
      echo "2" > "$RUN_COUNTER_FILE"
      echo "DEBUG: Created new counter file with value 2"
    fi
  fi
}

get_next_run_number() {
  # Ensure the directory for the counter file exists
  mkdir -p "$(dirname "$RUN_COUNTER_FILE")"
  
  # Create the lock file directory if it doesn't exist
  mkdir -p "$(dirname "$RUN_COUNTER_LOCK")"
  
  echo "Ensuring counter file path: $RUN_COUNTER_FILE"
  
  # Try to create the lock
  while ! mkdir "$RUN_COUNTER_LOCK" 2>/dev/null; do
    echo "Waiting for lock..."
    sleep 1
  done
  
  # If user specified a run number, use that directly
  if [[ -n "$RUN_COUNTER" ]]; then
    NEXT_RUN=$RUN_COUNTER
    echo "User specified run number: $NEXT_RUN"
  else
    # Find highest run number by scanning the results directory
    HIGHEST_RUN=0
    
    # Look for run_* directories in the results directory
    if [[ -d "$BASE_RESULT_DIR" ]]; then
      echo "Scanning $BASE_RESULT_DIR for existing runs..."
      for dir in "$BASE_RESULT_DIR"/run_*; do
        if [[ -d "$dir" ]]; then
          # Extract run number from directory name
          dir_name=$(basename "$dir")
          run_num=${dir_name#run_}
          
          # Check if it's a valid number
          if [[ "$run_num" =~ ^[0-9]+$ ]]; then
            # Update highest run if this one is higher
            if (( run_num > HIGHEST_RUN )); then
              HIGHEST_RUN=$run_num
              echo "Found higher run number: $HIGHEST_RUN"
            fi
          fi
        fi
      done
    fi
    
    # If no directories found, check if counter file exists
    if (( HIGHEST_RUN == 0 )) && [[ -f "$RUN_COUNTER_FILE" ]]; then
      # Read from existing counter file as fallback
      FILE_COUNTER=$(<"$RUN_COUNTER_FILE")
      if [[ "$FILE_COUNTER" =~ ^[0-9]+$ ]] && (( FILE_COUNTER > HIGHEST_RUN )); then
        HIGHEST_RUN=$FILE_COUNTER
        echo "Using counter file value: $HIGHEST_RUN"
      fi
    fi
    
    # Next run is highest found + 1
    NEXT_RUN=$((HIGHEST_RUN + 1))
    echo "Determined next run number: $NEXT_RUN (based on highest found: $HIGHEST_RUN)"
    
    # Update counter file with the next run number
    echo "$NEXT_RUN" > "$RUN_COUNTER_FILE"
    echo "Updated counter file to: $NEXT_RUN"
  fi
  
  # Release the lock
  rmdir "$RUN_COUNTER_LOCK"
  
  echo "Using run number: $NEXT_RUN"
}

# --- Get next run number ---
get_next_run_number

# --- Track runs in summary file ---
RUN_SUMMARY_FILE="$BASE_LOG_DIR/runs_summary.txt"
echo "Starting run set at $(date) - runs $NEXT_RUN to $((NEXT_RUN + LOOPS - 1))" >> "$RUN_SUMMARY_FILE"

echo "Starting with run number $NEXT_RUN for $DESIGN"
echo "Will perform $LOOPS iterations"

# --- Function to run a single TritonRoute iteration ---
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
    # Check if file is using the new format with labeled parameters
    if grep -q "PERTURBATION_FACTOR=" "$WEIGHT_GEN_STATE_FILE"; then
      # New format - update only the perturbation factor while preserving other settings
      # Using a different approach that works on NFS filesystems
      TMP_STATE_FILE="${WEIGHT_GEN_STATE_FILE}.tmp"
      cat "$WEIGHT_GEN_STATE_FILE" | sed "s/PERTURBATION_FACTOR=.*/PERTURBATION_FACTOR=$RUN_NUM.0/" > "$TMP_STATE_FILE"
      mv "$TMP_STATE_FILE" "$WEIGHT_GEN_STATE_FILE"
    else
      # Old format - update using the old method
      CURRENT_MODE=$(head -1 "$WEIGHT_GEN_STATE_FILE")
      echo "$CURRENT_MODE" > "$WEIGHT_GEN_STATE_FILE"
      echo "$RUN_NUM.0" >> "$WEIGHT_GEN_STATE_FILE"
      echo "" >> "$WEIGHT_GEN_STATE_FILE"
    fi
  else
    # Create the state file if it doesn't exist (using new format)
    echo "MODE=auto" > "$WEIGHT_GEN_STATE_FILE"
    echo "PERTURBATION_FACTOR=$RUN_NUM.0" >> "$WEIGHT_GEN_STATE_FILE"
    echo "USE_COMPLETELY_RANDOM=False" >> "$WEIGHT_GEN_STATE_FILE"
    echo "RANDOM_SEED=42" >> "$WEIGHT_GEN_STATE_FILE"
    echo "" >> "$WEIGHT_GEN_STATE_FILE"
  fi
  
  echo "Generating routing weights for $DESIGN..."
  # Pass mode parameter if specified
  if [[ -n "$WEIGHT_GEN_MODE" ]]; then
    if python3.9 "$DRT_SCRIPTS_DIR/weight_generator.py" "$WEIGHTS_FILE" --design "$DESIGN" --mode "$WEIGHT_GEN_MODE" > "$LOG_DIR/weights_generator.log" 2>&1; then
      echo "✓ Design-specific weights file generated with $WEIGHT_GEN_MODE mode: $WEIGHTS_FILE"
      cp "$WEIGHTS_FILE" "$RESULT_DIR/weights.csv"
    else
      echo "⚠️ Failed to generate weights file. Using default weights."
      WEIGHTS_FILE=""
      WEIGHTS_FILE_ABS=""
    fi
  else
    if python3.9 "$DRT_SCRIPTS_DIR/weight_generator.py" "$WEIGHTS_FILE" --design "$DESIGN" > "$LOG_DIR/weights_generator.log" 2>&1; then
    echo "✓ Design-specific weights file generated: $WEIGHTS_FILE"
    cp "$WEIGHTS_FILE" "$RESULT_DIR/weights.csv"
  else
    echo "⚠️ Failed to generate weights file. Using default weights."
    WEIGHTS_FILE=""
    WEIGHTS_FILE_ABS=""
  fi
  fi
  
  # Create Tcl script for detailed routing
  DRT_WRAPPER="$RESULT_DIR/drt_run_$RUN_NUM.tcl"
  echo "# Detailed routing script for $DESIGN - Run $RUN_NUM" > "$DRT_WRAPPER"
  echo "puts \"Loading design files for $DESIGN...\"" >> "$DRT_WRAPPER"
  
  if [[ "$USE_FLOW_FILES" == "true" ]]; then
    # Include all relevant LEF files from the platform to ensure all cells are defined
    PLATFORM_DIR="$FLOW_DIR/platforms/$PLATFORM"
    echo "# Including comprehensive LEF files for all cell definitions including special cells" >> "$DRT_WRAPPER"
    
    # First include the main technology LEF
    echo "read_lef \"$LEF_FILE\"" >> "$DRT_WRAPPER"
    
    # Then include variant LEF files that might contain special cells like TAPCELL_X1
    ALL_VARIANTS=("macro.lef" "macro.mod.lef" "macro.rect.lef")
    for variant in "${ALL_VARIANTS[@]}"; do
      variant_file="$PLATFORM_DIR/lef/NangateOpenCellLibrary.$variant"
      if [[ -f "$variant_file" ]]; then
        echo "read_lef \"$variant_file\"" >> "$DRT_WRAPPER"
      fi
    done
    
    # Include all fakeram LEF files for memory components
    # These are critical for designs with memory elements like bp_be, bp_fe, bp_multi, and tinyRocket
    echo "# Including memory LEF files" >> "$DRT_WRAPPER"
    for fakeram_lef in $PLATFORM_DIR/lef/fakeram45_*.lef; do
      if [[ -f "$fakeram_lef" ]]; then
        echo "read_lef \"$fakeram_lef\"" >> "$DRT_WRAPPER"
      fi
    done
    
    # Handle any additional macro LEF files
    if [[ "$MACRO_LEF" == *" "* ]]; then
      for macro_lef in $MACRO_LEF; do
        if [[ -f "$macro_lef" ]]; then
          echo "read_lef \"$macro_lef\"" >> "$DRT_WRAPPER"
        fi
      done
    elif [[ -n "$MACRO_LEF" ]]; then
      echo "read_lef \"$MACRO_LEF\"" >> "$DRT_WRAPPER"
    fi
    
    echo "read_def \"$DEF_FILE\"" >> "$DRT_WRAPPER"
    echo "read_guides \"$GUIDE_FILE\"" >> "$DRT_WRAPPER"
  else
    # Use standard files from design directory
    echo "read_lef \"$DESIGN_PATH/$DESIGN.input.lef\"" >> "$DRT_WRAPPER"
    echo "read_def \"$DESIGN_PATH/$DESIGN.input.def\"" >> "$DRT_WRAPPER"
    echo "read_guides \"$DESIGN_PATH/$DESIGN.input.guide\"" >> "$DRT_WRAPPER"
  fi
  
  # Build detailed_route command
  if [[ -n "$WEIGHTS_FILE" ]]; then
    echo "puts \"Using weight file: $WEIGHTS_FILE_ABS\"" >> "$DRT_WRAPPER"
    echo "detailed_route \\" >> "$DRT_WRAPPER"
    echo "    -verbose 3 \\" >> "$DRT_WRAPPER"
    echo "    -drc_report_iter_step 1 \\" >> "$DRT_WRAPPER" 
    echo "    -output_maze \"$RESULT_DIR/maze.log\" \\" >> "$DRT_WRAPPER"
    echo "    -output_drc \"$REPORT_DIR/violations\" \\" >> "$DRT_WRAPPER"
    echo "    -droute_end_iter 64 \\" >> "$DRT_WRAPPER"
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
    echo "    -droute_end_iter 64 \\" >> "$DRT_WRAPPER"
    echo "    -or_seed 42 \\" >> "$DRT_WRAPPER"
    echo "    -or_k 10" >> "$DRT_WRAPPER"
  fi
  
  # Add output DEF writing
  echo "" >> "$DRT_WRAPPER"
  echo "puts \"Writing output DEF to $RESULT_DIR/tritonroute_output.def\"" >> "$DRT_WRAPPER"
  echo "write_def \"$RESULT_DIR/tritonroute_output.def\"" >> "$DRT_WRAPPER"
  echo "puts \"Detailed routing complete.\"" >> "$DRT_WRAPPER"
  echo "exit 0" >> "$DRT_WRAPPER"
  

  
  # Add header to log file
  echo "TritonRoute Standalone Log for $DESIGN" > "$LOG_FILE"
  echo "Started at $(date)" >> "$LOG_FILE"
  echo "=========================================" >> "$LOG_FILE"
  
  # Set thread count for OpenROAD
  NUM_CORES=${OMP_NUM_THREADS:-$(nproc)}
  echo "Using $NUM_CORES CPU threads for TritonRoute"
  
  # Run OpenROAD with direct commands
  echo -e "\nRunning TritonRoute on $DESIGN/run_$RUN_NUM..."
  echo "All output will be captured in: $LOG_FILE"
  
  # Run with timeout and ensure exit on error
  (
    set -o pipefail
    
    # Run the process and store its PID for tracking
    timeout 7200 ./tools/OpenROAD/build/src/openroad -no_init -threads $NUM_CORES -exit "$DRT_WRAPPER" |& tee -a "$LOG_FILE" &
    OPENROAD_PID=$!
    OPENROAD_PIDS+=("$OPENROAD_PID")
    
    # Wait for the process to complete
    wait $OPENROAD_PID
    RUN_STATUS=$?
    
    # Check for violations and completion
    VIOLATION_CHECK=$(tail -100 "$LOG_FILE" | grep -i "Number of violations =" | tail -1)
    COMPLETED_CHECK=$(tail -100 "$LOG_FILE" | grep -i "Completing 100%" | tail -1)
    
    # Check if output DEF was created
    if [ -f "$RESULT_DIR/tritonroute_output.def" ] && [ -s "$RESULT_DIR/tritonroute_output.def" ]; then
      if [ $RUN_STATUS -ne 0 ]; then
        echo -e "\n⚠️ OpenROAD exited with code $RUN_STATUS, but output DEF was created." | tee -a "$LOG_FILE"
        echo "Considering this run successful since routing completed." | tee -a "$LOG_FILE"
        RUN_STATUS=0
      fi
    elif [ ! -z "$COMPLETED_CHECK" ] && [ ! -z "$VIOLATION_CHECK" ]; then
      echo -e "\n⚠️ Log shows routing completed with: $VIOLATION_CHECK" | tee -a "$LOG_FILE"
      RUN_STATUS=0
    elif [ $RUN_STATUS -eq 124 ]; then
      echo -e "\n❌ TritonRoute timed out after 2 hours." | tee -a "$LOG_FILE"
      exit $RUN_STATUS
    elif [ $RUN_STATUS -ne 0 ]; then
      echo -e "\n❌ OpenROAD execution failed with code $RUN_STATUS." | tee -a "$LOG_FILE"
      exit $RUN_STATUS
    fi
  )
  local RUN_STATUS=$?
  
  # Add footer to log
  echo "" >> "$LOG_FILE"
  echo "Finished at $(date)" >> "$LOG_FILE"
  echo "=========================================" >> "$LOG_FILE"
  
  # Remove temporary wrapper script and cleanup
  rm -f "$DRT_WRAPPER"
  
  # Remove the PID from our tracking array
  for i in "${!OPENROAD_PIDS[@]}"; do
    if [[ ${OPENROAD_PIDS[i]} == $OPENROAD_PID ]]; then
      unset 'OPENROAD_PIDS[i]'
      break
    fi
  done
  
  # Clean up any NFS temp files that might have been created
  if [[ -d "$LOG_DIR" ]]; then
    find "$LOG_DIR" -name ".nfs*" -delete 2>/dev/null || true
  fi
  
  # Check if the log file was created and has content
  if [ $RUN_STATUS -eq 0 ] && [ -f "$LOG_FILE" ] && [ -s "$LOG_FILE" ]; then
    echo ""
    echo "✓ Run $RUN_NUM completed successfully"
    echo "  Log file: $LOG_FILE ($(du -h "$LOG_FILE" | cut -f1))"
    
    # Extract final DRC counts
    DRC_COUNTS=$(grep -i "violation" "$LOG_FILE" | tail -5)
    if [[ -n "$DRC_COUNTS" ]]; then
      echo "  DRC Violations:" 
      echo "$DRC_COUNTS" | sed 's/^/    /'
      echo "$DRC_COUNTS" >> "$RUN_SUMMARY_FILE"
    fi
    
    return 0
  else
    echo ""
    echo "❌ Run $RUN_NUM failed - check log file for details"
    echo "  Log file: $LOG_FILE"
    return 1
  fi
}

# Main execution loop
echo "Running in nohup-compatible mode - script will continue if terminal is closed"

success_count=0
failure_count=0

for ((i=0; i<LOOPS; i++)); do
  CURRENT_RUN=$((NEXT_RUN + i))
  
  echo ""
  echo "===== Running iteration $((i+1)) of $LOOPS (run_$CURRENT_RUN) ====="
  
  if run_single_iteration $CURRENT_RUN $((i+1)) $LOOPS; then
    success_count=$((success_count + 1))
    increment_counter
  else
    failure_count=$((failure_count + 1))
  fi
done

# --- Final status report ---
if [[ $failure_count -gt 0 ]]; then
  echo ""
  echo "*********************************************************"
  echo "❌ FAILURE: $failure_count out of $LOOPS runs failed!"
  echo "Check the logs for details on the failed runs."
  echo "*********************************************************"
  exit 1
else
  START_RUN=$((NEXT_RUN))
  END_RUN=$((NEXT_RUN + LOOPS - 1))
  echo ""
  echo "*********************************************************"
  echo "✅ SUCCESS: Completed $LOOPS runs successfully!"
  echo "Design: $DESIGN"
  echo "Runs completed: run_$START_RUN to run_$END_RUN"
  echo "*********************************************************"
  exit 0
fi
