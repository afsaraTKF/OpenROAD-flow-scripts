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
DESIGN=""  # Will be set either via command line or from design config
DESIGN_DIR=""
RUN_COUNTER=""
LOOPS=1  # Default to a single run
USE_FLOW=false  # Default to not using the full flow
DESIGN_CONFIG=""  # Default empty design config
USE_FLOW_FILES=false  # Flag for using flow-generated files
USING_CONFIG_DESIGN=false  # Flag to track if we're using a design from config

# Forward declare functions so they can be called before their definitions
increment_counter() { true; } # Will be overridden later
get_next_run_number() { true; } # Will be overridden later

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
        
        # For ispd18_test* designs, immediately set up the directory paths
        # to avoid issues with the locking mechanism
        if [[ "$DESIGN_PATH" == ispd18* ]]; then
          # Set directories right away for ISPD test cases
          SCRIPT_DIR=$(dirname "$(realpath "$0")")
          FLOW_DIR="$SCRIPT_DIR/flow"
          
          # ISPD test cases don't use platform in path structure
          BASE_LOG_DIR="$FLOW_DIR/logs/$DESIGN"
          BASE_REPORT_DIR="$FLOW_DIR/reports/$DESIGN"
          BASE_RESULT_DIR="$FLOW_DIR/results/$DESIGN"
          
          # Create directories if they don't exist
          mkdir -p "$BASE_LOG_DIR" "$BASE_REPORT_DIR" "$BASE_RESULT_DIR"
          
          # Set up counter file paths immediately
          RUN_COUNTER_FILE="$BASE_LOG_DIR/run_counter.txt"
          RUN_COUNTER_LOCK="$BASE_LOG_DIR/run_counter.lock"
          
          echo "Set up ispd18 directory paths early:"
          echo "  Log dir: $BASE_LOG_DIR"
          echo "  Counter file: $RUN_COUNTER_FILE"
        fi
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
    --run2=*)
      # Allow specifying the end run number for a range
      END_RUN="${1#*=}"
      # Ensure it's a valid number
      if ! [[ "$END_RUN" =~ ^[0-9]+$ ]]; then
        echo "Error: End run number must be a positive number"
        exit 1
      fi
      shift
      ;;
    -flow|--flow)
      # Enable using the full flow
      USE_FLOW=true
      shift
      ;;
    --design-config=*|--design_config=*|--DESIGN_CONFIG=*)
      # Allow specifying the design config file for the full flow
      DESIGN_CONFIG="${1#*=}"
      USE_FLOW=true
      USING_CONFIG_DESIGN=true
      shift
      ;;
    --mode=*)
      # Allow specifying weight generator mode (default, auto, completely_random, manual)
      WEIGHT_GEN_MODE="${1#*=}"
      echo "Using weight generator mode: $WEIGHT_GEN_MODE"
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
TOOLS_DIR="$SCRIPT_DIR/tools"
DRT_SCRIPTS_DIR="$SCRIPT_DIR/tools/OpenROAD/src/drt/src/dr/scripts"

# Extract design name from config file if specified
if [[ -n "$DESIGN_CONFIG" && "$USING_CONFIG_DESIGN" == "true" ]]; then
  # Normalize the config path to avoid duplication
  if [[ "$DESIGN_CONFIG" == flow/* ]]; then
    # Remove the 'flow/' prefix from user-provided path
    NORMALIZED_CONFIG="${DESIGN_CONFIG#flow/}"
  else
    # If it doesn't start with flow/, treat as-is
    NORMALIZED_CONFIG="$DESIGN_CONFIG"
  fi
  
  # Construct proper config file path
  CONFIG_FILE_PATH="$FLOW_DIR/$NORMALIZED_CONFIG"
  echo "Extracting DESIGN name from config file: $CONFIG_FILE_PATH"
  
  if [[ -f "$CONFIG_FILE_PATH" ]]; then
    # Try first with DESIGN (if exists)
    CONFIG_DESIGN=$(grep -E "^\s*DESIGN\s*=" "$CONFIG_FILE_PATH" | cut -d '=' -f 2 | tr -d ' \t')
    
    # Extract both DESIGN_NAME and DESIGN_NICKNAME to handle inconsistencies
    # Support both formats with and without the 'export' keyword
    DESIGN_NAME=$(grep -E "^\s*(export\s+)?DESIGN_NAME\s*=" "$CONFIG_FILE_PATH" | cut -d '=' -f 2 | tr -d ' \t')
    DESIGN_NICKNAME=$(grep -E "^\s*(export\s+)?DESIGN_NICKNAME\s*=" "$CONFIG_FILE_PATH" | cut -d '=' -f 2 | tr -d ' \t')
    
    echo "Found in config: DESIGN_NAME=$DESIGN_NAME, DESIGN_NICKNAME=$DESIGN_NICKNAME"
    
    # If DESIGN not set explicitly, prefer NICKNAME over NAME for compatibility with existing logs
    if [[ -z "$CONFIG_DESIGN" ]]; then
      if [[ -n "$DESIGN_NICKNAME" ]]; then
        CONFIG_DESIGN=$DESIGN_NICKNAME
        echo "Using DESIGN_NICKNAME for consistency with existing logs"
      elif [[ -n "$DESIGN_NAME" ]]; then
        CONFIG_DESIGN=$DESIGN_NAME
      fi
    fi
    
    if [[ -n "$CONFIG_DESIGN" ]]; then
      echo "Extracted from config: DESIGN=$CONFIG_DESIGN"
      DESIGN=$CONFIG_DESIGN
      # Store both name and nickname for later checks
      if [[ -n "$DESIGN_NAME" && "$DESIGN_NAME" != "$DESIGN" ]]; then
        ALTERNATE_DESIGN_NAME=$DESIGN_NAME
      fi
      if [[ -n "$DESIGN_NICKNAME" && "$DESIGN_NICKNAME" != "$DESIGN" ]]; then
        ALTERNATE_DESIGN_NAME=$DESIGN_NICKNAME
      fi
    else
      echo "Warning: Could not extract DESIGN from config file"
    fi
  else
    echo "Warning: Config file not found: $CONFIG_FILE_PATH"
    echo "Attempted path: $CONFIG_FILE_PATH"
    echo "Original config path: $DESIGN_CONFIG"
  fi
fi

# Set default design only if still empty
if [[ -z "$DESIGN" ]]; then
  echo "Warning: No design specified, using default design 'ispd18_test1'"
  DESIGN="ispd18_test1"
fi

# If design is just a name, form the path using default conventions
if [[ -z "$DESIGN_DIR" ]]; then
  DESIGN_DIR="$FLOW_DIR/$DESIGN"
  
  # Also check for alternate path if we have both name and nickname
  if [[ -n "$ALTERNATE_DESIGN_NAME" ]]; then
    ALT_DESIGN_DIR="$FLOW_DIR/$ALTERNATE_DESIGN_NAME"
    
    # If the primary directory doesn't exist but alternate does, use alternate
    if [[ ! -d "$DESIGN_DIR" && -d "$ALT_DESIGN_DIR" ]]; then
      echo "Primary design directory not found: $DESIGN_DIR"
      echo "Using alternate design directory: $ALT_DESIGN_DIR"
      DESIGN_DIR="$ALT_DESIGN_DIR"
    fi
  fi
fi

# Check if input files exist (LEF, DEF, guide)
DESIGN_PATH="$DESIGN_DIR"

# Check for input files - only if we're NOT using design config (flow mode)
MISSING_FILES=false

# In direct mode (no design-config), we look for input.lef, input.def, etc.
if [[ "$USING_CONFIG_DESIGN" != "true" ]]; then
  # Check with primary design name first
  if [[ -f "$DESIGN_PATH/$DESIGN.input.lef" ]] || \
     [[ -f "$DESIGN_PATH/$DESIGN.input.def" ]] || \
     [[ -f "$DESIGN_PATH/$DESIGN.input.guide" ]]; then
    echo "Found input files with design name: $DESIGN"
  # Try alternate name if available
  elif [[ -n "$ALTERNATE_DESIGN_NAME" ]] && \
       ([[ -f "$DESIGN_PATH/$ALTERNATE_DESIGN_NAME.input.lef" ]] || \
        [[ -f "$DESIGN_PATH/$ALTERNATE_DESIGN_NAME.input.def" ]] || \
        [[ -f "$DESIGN_PATH/$ALTERNATE_DESIGN_NAME.input.guide" ]]); then
    echo "Using alternate design name for input files: $ALTERNATE_DESIGN_NAME"
    DESIGN=$ALTERNATE_DESIGN_NAME
  fi

  # Check which files exist
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
else
  # In flow mode (with design-config), we don't check for input.* files at all
  # Because we'll check for grt.def, route.guide, etc. in the results directory later
  echo "Using design config - will check for flow-generated files instead of input.* files"
  MISSING_FILES=true  # Force flow file mode
  USE_FLOW=true       # Ensure flow mode is active
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
    
    # Design name should already be extracted, but verify to be safe
    # Normalize the config path again to be consistent with earlier logic
    if [[ "$DESIGN_CONFIG" == flow/* ]]; then
      NORMALIZED_CONFIG="${DESIGN_CONFIG#flow/}"
    else
      NORMALIZED_CONFIG="$DESIGN_CONFIG"
    fi
    
    CONFIG_FILE_PATH="$FLOW_DIR/$NORMALIZED_CONFIG"
    if [[ -f "$CONFIG_FILE_PATH" ]]; then
      echo "Verifying DESIGN name from config file: $CONFIG_FILE_PATH"
      
      # Try first with DESIGN (if exists)
      CONFIG_DESIGN=$(grep -E "^\s*DESIGN\s*=" "$CONFIG_FILE_PATH" | cut -d '=' -f 2 | tr -d ' 	')
      
      # If not found, try with DESIGN_NAME
      if [[ -z "$CONFIG_DESIGN" ]]; then
        CONFIG_DESIGN=$(grep -E "^\s*export\s+DESIGN_NAME\s*=" "$CONFIG_FILE_PATH" | cut -d '=' -f 2 | tr -d ' 	')
      fi
      
      # If still not found, try with DESIGN_NICKNAME
      if [[ -z "$CONFIG_DESIGN" ]]; then
        CONFIG_DESIGN=$(grep -E "^\s*export\s+DESIGN_NICKNAME\s*=" "$CONFIG_FILE_PATH" | cut -d '=' -f 2 | tr -d ' 	')
      fi
      
      if [[ -n "$CONFIG_DESIGN" ]]; then
        echo "Verified from config path: DESIGN=$CONFIG_DESIGN, PLATFORM=$PLATFORM"
        # Don't override DESIGN in verification - we want to keep using nickname
        # This preserves the 'aes' name instead of switching to 'aes_cipher_top'
        echo "IMPORTANT: Keeping current design name: $DESIGN for consistency with existing logs"
        # Store the design name as alternate if it's different from current design
        if [[ "$CONFIG_DESIGN" != "$DESIGN" ]]; then
          ALTERNATE_DESIGN_NAME="$CONFIG_DESIGN"
        fi
      fi
    else
      echo "Warning: Config file not found at verification stage: $CONFIG_FILE_PATH"
    fi
    
    # DON'T override DESIGN with DESIGN_NAME to avoid losing nickname
    # Just ensure we have both primary and alternate names for directory checks
    echo "Final design name for directory paths: $DESIGN"
    if [[ -n "$ALTERNATE_DESIGN_NAME" ]]; then
      echo "Will also check alternate name: $ALTERNATE_DESIGN_NAME"
    fi
    
    # Store the original design name before checking directories
    ORIGINAL_DESIGN=$DESIGN
    
    # Set up all directory structures early
    # Setup base directories for logs, reports and results
    BASE_LOG_DIR="$FLOW_DIR/logs/$PLATFORM/$DESIGN"
    BASE_REPORT_DIR="$FLOW_DIR/reports/$PLATFORM/$DESIGN"
    BASE_RESULT_DIR="$FLOW_DIR/results/$PLATFORM/$DESIGN"
    
    # Create top-level directories if they don't exist
    mkdir -p "$BASE_LOG_DIR" "$BASE_REPORT_DIR" "$BASE_RESULT_DIR"
    
    # Setup run counter file and lock file paths
    RUN_COUNTER_FILE="$BASE_LOG_DIR/run_counter.txt"
    RUN_COUNTER_LOCK="$BASE_LOG_DIR/run_counter.lock"
    
    echo "Log directory: $BASE_LOG_DIR"
    echo "Counter file: $RUN_COUNTER_FILE"
    
    # Check for existing results - try both DESIGN_NAME and DESIGN_NICKNAME directories
    RUN_RESULTS_DIR="$FLOW_DIR/results/$PLATFORM/$DESIGN"
    echo "Checking for results in primary directory: $RUN_RESULTS_DIR"
    
    # Flag to track if we've found any previous runs
    FOUND_PREVIOUS_RUNS=false
    
    # If we have an alternate name and primary directory doesn't exist, try the alternate
    if [[ ! -d "$RUN_RESULTS_DIR" && -n "$ALTERNATE_DESIGN_NAME" ]]; then
      ALT_RESULTS_DIR="$FLOW_DIR/results/$PLATFORM/$ALTERNATE_DESIGN_NAME"
      echo "Primary results directory not found. Checking alternate: $ALT_RESULTS_DIR"
      
      if [[ -d "$ALT_RESULTS_DIR" ]]; then
        echo "Found results in alternate directory - using $ALTERNATE_DESIGN_NAME for consistency"
        DESIGN=$ALTERNATE_DESIGN_NAME
        RUN_RESULTS_DIR="$ALT_RESULTS_DIR"
        
        # Update all base directories to match the new design name
        BASE_LOG_DIR="$FLOW_DIR/logs/$PLATFORM/$DESIGN"
        BASE_REPORT_DIR="$FLOW_DIR/reports/$PLATFORM/$DESIGN"
        BASE_RESULT_DIR="$FLOW_DIR/results/$PLATFORM/$DESIGN"
        
        # Update counter file paths to match the new design name
        RUN_COUNTER_FILE="$BASE_LOG_DIR/run_counter.txt"
        RUN_COUNTER_LOCK="$BASE_LOG_DIR/run_counter.lock"
        echo "Updated all directory paths to use design: $DESIGN"
      fi
    fi
    
    # Check for intermediate directories like 'base' between design and run directories
    if [[ -d "$RUN_RESULTS_DIR/base" ]]; then
      echo "Found intermediate 'base' directory in results"
      RUN_RESULTS_DIR="$RUN_RESULTS_DIR/base"
      
      # Update all base directories to include the intermediate 'base' directory
      BASE_LOG_DIR="$BASE_LOG_DIR/base"
      BASE_REPORT_DIR="$BASE_REPORT_DIR/base"
      BASE_RESULT_DIR="$BASE_RESULT_DIR/base"
      
      # Update counter file paths to include the intermediate 'base' directory
      RUN_COUNTER_FILE="$BASE_LOG_DIR/run_counter.txt"
      RUN_COUNTER_LOCK="$BASE_LOG_DIR/run_counter.lock"
      echo "Updated all directory paths to include 'base' directory"
    fi
    
    # Check if any run directories exist
    if [[ -d "$RUN_RESULTS_DIR" ]]; then
      # Count how many run directories exist
      RUN_COUNT=$(find "$RUN_RESULTS_DIR" -maxdepth 1 -type d -name "run_*" | wc -l)
      if [[ "$RUN_COUNT" -gt 0 ]]; then
        echo "Found $RUN_COUNT existing run(s) for this design"
        FOUND_PREVIOUS_RUNS=true
      else
        echo "Results directory exists but no run_* subdirectories found"
      fi
    else
      echo "No results directory found for this design, may need to run flow first"
    fi
    
    echo "Checking for files in platform directory: $FLOW_DIR/platforms/$PLATFORM"
    echo "Using results directory: $RUN_RESULTS_DIR"
    
    # First check specifically for the run_1 directory (most reliable results)
    RUN1_DIR="$RUN_RESULTS_DIR/run_1"
    if [[ -d "$RUN1_DIR" ]]; then
      echo "Found 'base/run_1' directory - using standard OpenROAD flow structure"
      
      # Check for DEF file or extract from ODB if available
      if [[ -f "$RUN1_DIR/5_1_grt.def" && -f "$RUN1_DIR/route.guide" ]]; then
        echo "Using existing DEF and guide files from run_1"
        DESIGN_PATH="$RUN1_DIR"
        DEF_FILE="$RUN1_DIR/5_1_grt.def"
        GUIDE_FILE="$RUN1_DIR/route.guide"
        USING_EXISTING_RESULTS=true
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
          OPENROAD_BIN=$(which openroad)
        fi
        
        if [[ -n "$OPENROAD_BIN" ]]; then
          echo "Extracting DEF from ODB using OpenROAD at: $OPENROAD_BIN"
          "$OPENROAD_BIN" "$TMP_SCRIPT"
          
          if [[ -f "$RUN1_DIR/5_1_grt.def" ]]; then
            echo "Successfully extracted DEF file from ODB"
            DESIGN_PATH="$RUN1_DIR"
            DEF_FILE="$RUN1_DIR/5_1_grt.def"
            GUIDE_FILE="$RUN1_DIR/route.guide"
            USING_EXISTING_RESULTS=true
            USE_FLOW_FILES=true
            
            # Find the LEF files immediately after extracting DEF
            PLATFORM_DIR="$FLOW_DIR/platforms/$PLATFORM"
            echo "Looking for LEF files in platform directory: $PLATFORM_DIR"
            
            if [[ "$PLATFORM" == "nangate45" && -f "$PLATFORM_DIR/lef/NangateOpenCellLibrary.tech.lef" ]]; then
              echo "Using Nangate LEF files from platform directory"
              LEF_FILE="$PLATFORM_DIR/lef/NangateOpenCellLibrary.tech.lef"
              MACRO_LEF="$PLATFORM_DIR/lef/NangateOpenCellLibrary.macro.lef"
            elif [[ -f "$PLATFORM_DIR/lef/$PLATFORM.tech.lef" ]]; then
              echo "Using $PLATFORM LEF files from platform directory"
              LEF_FILE="$PLATFORM_DIR/lef/$PLATFORM.tech.lef"
              MACRO_LEF="$PLATFORM_DIR/lef/$PLATFORM.macro.lef"
            elif [[ -d "$PLATFORM_DIR/lef" ]]; then
              # Try to find any tech and macro LEF files in the platform directory
              echo "Searching for LEF files in $PLATFORM_DIR/lef directory..."
              TECH_LEF=$(find "$PLATFORM_DIR/lef" -name "*.tech.lef" | head -1)
              MACRO_LEF_FILES=$(find "$PLATFORM_DIR/lef" -name "*.macro.lef" -o -name "*.cells.lef" | tr '\n' ' ')
              
              if [[ -n "$TECH_LEF" && -n "$MACRO_LEF_FILES" ]]; then
                echo "Found LEF files:"
                echo "  Tech LEF: $TECH_LEF"
                echo "  Macro LEF files: $MACRO_LEF_FILES"
                LEF_FILE="$TECH_LEF"
                MACRO_LEF="$MACRO_LEF_FILES"
              fi
            fi
          else
            echo "Failed to extract DEF file from ODB"
          fi
        else
          echo "Could not find OpenROAD binary to extract DEF file"
        fi
      fi
    fi
    
    # If we didn't find what we need in run_1, look for other run directories
    if [[ "$USING_EXISTING_RESULTS" != "true" && -d "$RUN_RESULTS_DIR" ]]; then 
      LATEST_RUN=$(find "$RUN_RESULTS_DIR" -maxdepth 2 -type d -name "run_*" | sort -V | tail -1)
      
      if [[ -n "$LATEST_RUN" && -f "$LATEST_RUN/5_1_grt.def" && -f "$LATEST_RUN/route.guide" ]]; then
        echo "Using existing results from $LATEST_RUN"
        DESIGN_PATH="$LATEST_RUN"
        DEF_FILE="$LATEST_RUN/5_1_grt.def"
        GUIDE_FILE="$LATEST_RUN/route.guide"
        
        # Find the LEF files
        PLATFORM_DIR="$FLOW_DIR/platforms/$PLATFORM"
        echo "Looking for LEF files in platform directory: $PLATFORM_DIR"
      
      if [[ "$PLATFORM" == "nangate45" && -f "$PLATFORM_DIR/lef/NangateOpenCellLibrary.tech.lef" ]]; then
        echo "Using Nangate LEF files from platform directory"
        LEF_FILE="$PLATFORM_DIR/lef/NangateOpenCellLibrary.tech.lef"
        
        # Use the modified macro LEF file that contains TAPCELL_X1 definition
        MACRO_LEF="$PLATFORM_DIR/lef/NangateOpenCellLibrary.macro.mod.lef"
        
        # Include all fakeram LEF files for completeness
        FAKERAM_LEFS=$(find "$PLATFORM_DIR/lef" -name "fakeram*.lef" | tr '\n' ' ')
        if [[ -n "$FAKERAM_LEFS" ]]; then
          echo "Found additional fakeram LEF files that will be included"
          MACRO_LEF="$MACRO_LEF $FAKERAM_LEFS"
        fi
      elif [[ -f "$PLATFORM_DIR/lef/$PLATFORM.tech.lef" ]]; then
        echo "Using $PLATFORM LEF files from platform directory"
        LEF_FILE="$PLATFORM_DIR/lef/$PLATFORM.tech.lef"
        MACRO_LEF="$PLATFORM_DIR/lef/$PLATFORM.macro.lef"
      elif [[ -d "$PLATFORM_DIR/lef" ]]; then
        # Try to find any tech and macro LEF files in the platform directory
        echo "Searching for LEF files in $PLATFORM_DIR/lef directory..."
        TECH_LEF=$(find "$PLATFORM_DIR/lef" -name "*.tech.lef" | head -1)
        MACRO_LEF_FILES=$(find "$PLATFORM_DIR/lef" -name "*.macro.lef" -o -name "*.cells.lef" | tr '\n' ' ')
        
        if [[ -n "$TECH_LEF" && -n "$MACRO_LEF_FILES" ]]; then
          echo "Found LEF files:"
          echo "  Tech LEF: $TECH_LEF"
          echo "  Macro LEF files: $MACRO_LEF_FILES"
          LEF_FILE="$TECH_LEF"
          MACRO_LEF="$MACRO_LEF_FILES"
        else
          echo "Error: Could not find LEF files for platform $PLATFORM"
          exit 1
        fi
      else
        echo "Error: Could not find LEF files for platform $PLATFORM"
        exit 1
      fi
      
      # Validate that the files actually exist
      echo "Verifying LEF file paths:"
      echo "  LEF_FILE: $LEF_FILE (exists: $([[ -f "$LEF_FILE" ]] && echo "yes" || echo "no"))"
      echo "  MACRO_LEF: $MACRO_LEF"
      
      # Set flag for using multiple LEF files
      USE_FLOW_FILES=true
      else
        # Only run the flow if USING_EXISTING_RESULTS is not true AND we haven't found any files
        if [[ "$USING_EXISTING_RESULTS" != "true" && "$FOUND_PREVIOUS_RUNS" != "true" ]]; then
          echo "No previous runs found for this design - will run full flow once to generate files"
          # Make sure to use proper config path format for make command
          if [[ "$DESIGN_CONFIG" == flow/* ]]; then
            # Remove flow/ prefix for make command
            MAKE_CONFIG="${DESIGN_CONFIG#flow/}"
          else
            MAKE_CONFIG="$DESIGN_CONFIG"
          fi
          echo "Running make with config: DESIGN_CONFIG=$MAKE_CONFIG"
          (cd "$FLOW_DIR" && make DESIGN_CONFIG=$MAKE_CONFIG run_loop LOOPS=1)
          
          # Only increment counter if we actually ran the flow
          increment_counter
          get_next_run_number
        else
          echo "ERROR: Found existing runs but couldn't locate necessary files in any of them."
          echo "Check results directory: $RUN_RESULTS_DIR"
          echo "You may need to fix or recreate these runs to provide the necessary files."
          exit 1
        fi
        
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
      echo "Checking if we already have extracted results..."
      if [[ "$USING_EXISTING_RESULTS" == "true" ]]; then
        echo "Using previously extracted results - no need to run flow"
        # Still need to get the next run number for detailed routing results
        # even when not running the full flow
        echo "Getting next run number for detailed routing results"
        
        # Just verify the counter file path is correct
        echo "Using counter file at: $RUN_COUNTER_FILE"
        
        # Check if counter file exists, if not create it
        if [[ ! -f "$RUN_COUNTER_FILE" ]]; then
          echo "Note: Creating new counter file (not found: $RUN_COUNTER_FILE)"
          echo "1" > "$RUN_COUNTER_FILE"
        else
          echo "Found existing counter file with value: $(cat "$RUN_COUNTER_FILE")"
        fi
        
        # Get the next run number from the counter file
        get_next_run_number
      else
        echo "Will run full flow to generate required files"
        # Make sure to use proper config path format for make command
        if [[ "$DESIGN_CONFIG" == flow/* ]]; then
          # Remove flow/ prefix for make command
          MAKE_CONFIG="${DESIGN_CONFIG#flow/}"
        else
          MAKE_CONFIG="$DESIGN_CONFIG"
        fi
        echo "Running make with config: DESIGN_CONFIG=$MAKE_CONFIG"
        (cd "$FLOW_DIR" && make DESIGN_CONFIG=$MAKE_CONFIG run_loop LOOPS=1)
        
        # Increment the run counter after running the flow once
        # to avoid overwriting the flow results in the next run
        increment_counter
        get_next_run_number
      fi
      
      # When using existing results, we already have DEF_FILE and GUIDE_FILE set
      # Only need to check for new runs if we actually ran the flow
      if [[ "$USING_EXISTING_RESULTS" != "true" ]]; then
        # Check if the flow run was successful
        LATEST_RUN=$(find "$RUN_RESULTS_DIR" -maxdepth 1 -type d -name "run_*" | sort -V | tail -1)
        if [[ -n "$LATEST_RUN" && -f "$LATEST_RUN/5_1_grt.def" && -f "$LATEST_RUN/route.guide" ]]; then
          echo "Using generated files from $LATEST_RUN"
          DESIGN_PATH="$LATEST_RUN"
          DEF_FILE="$LATEST_RUN/5_1_grt.def"
          GUIDE_FILE="$LATEST_RUN/route.guide"
        else
          echo "Error: Failed to generate required files with flow"
          exit 1
        fi
      fi
      
      # At this point, we should have valid DEF_FILE and GUIDE_FILE
      # from either existing results or a new flow run
      if [[ -z "$DEF_FILE" || -z "$GUIDE_FILE" || ! -f "$DEF_FILE" || ! -f "$GUIDE_FILE" ]]; then
        echo "Error: Missing required DEF or guide file for detailed routing"
        echo "DEF_FILE: $DEF_FILE (exists: $([[ -f "$DEF_FILE" ]] && echo "yes" || echo "no"))"
        echo "GUIDE_FILE: $GUIDE_FILE (exists: $([[ -f "$GUIDE_FILE" ]] && echo "yes" || echo "no"))"
        exit 1
      fi
      
      # Find the LEF files
      PLATFORM_DIR="$FLOW_DIR/platforms/$PLATFORM"
      echo "Looking for LEF files in platform directory: $PLATFORM_DIR"
      
      if [[ "$PLATFORM" == "nangate45" && -f "$PLATFORM_DIR/lef/NangateOpenCellLibrary.tech.lef" ]]; then
        echo "Using Nangate LEF files from platform directory"
        LEF_FILE="$PLATFORM_DIR/lef/NangateOpenCellLibrary.tech.lef"
        
        # Use the modified macro LEF file that contains TAPCELL_X1 definition
        MACRO_LEF="$PLATFORM_DIR/lef/NangateOpenCellLibrary.macro.mod.lef"
        
        # Include all fakeram LEF files for completeness
        FAKERAM_LEFS=$(find "$PLATFORM_DIR/lef" -name "fakeram*.lef" | tr '\n' ' ')
        if [[ -n "$FAKERAM_LEFS" ]]; then
          echo "Found additional fakeram LEF files that will be included"
          MACRO_LEF="$MACRO_LEF $FAKERAM_LEFS"
        fi
      elif [[ -f "$PLATFORM_DIR/lef/$PLATFORM.tech.lef" ]]; then
        echo "Using $PLATFORM LEF files from platform directory"
        LEF_FILE="$PLATFORM_DIR/lef/$PLATFORM.tech.lef"
        MACRO_LEF="$PLATFORM_DIR/lef/$PLATFORM.macro.lef"
      elif [[ -d "$PLATFORM_DIR/lef" ]]; then
        # Try to find any tech and macro LEF files in the platform directory
        echo "Searching for LEF files in $PLATFORM_DIR/lef directory..."
        TECH_LEF=$(find "$PLATFORM_DIR/lef" -name "*.tech.lef" | head -1)
        MACRO_LEF_FILES=$(find "$PLATFORM_DIR/lef" -name "*.macro.lef" -o -name "*.cells.lef" | tr '\n' ' ')
        
        if [[ -n "$TECH_LEF" && -n "$MACRO_LEF_FILES" ]]; then
          echo "Found LEF files:"
          echo "  Tech LEF: $TECH_LEF"
          echo "  Macro LEF files: $MACRO_LEF_FILES"
          LEF_FILE="$TECH_LEF"
          MACRO_LEF="$MACRO_LEF_FILES"
        else
          echo "Error: Could not find LEF files for platform $PLATFORM"
          exit 1
        fi
      else
        echo "Error: Could not find LEF files for platform $PLATFORM"
        exit 1
      fi
      
      # Validate that the files actually exist
      echo "Verifying LEF file paths:"
      echo "  LEF_FILE: $LEF_FILE (exists: $([[ -f "$LEF_FILE" ]] && echo "yes" || echo "no"))"
      echo "  MACRO_LEF: $MACRO_LEF"
      
      # Set flag for using multiple LEF files
      USE_FLOW_FILES=true
    fi
  else
    echo "Error: Required input files not found, and -flow flag not provided"
    echo "Use -flow flag to attempt to generate input files from design"
    exit 1
  fi
fi

# Note: Directory structure was already set up earlier with platform name and base dir
# Keep using the paths that already include platform and 'base' directory
# DO NOT reset these variables - preserving current values
# BASE_LOG_DIR="$FLOW_DIR/logs/$DESIGN"
# BASE_REPORT_DIR="$FLOW_DIR/reports/$DESIGN"
# BASE_RESULT_DIR="$FLOW_DIR/results/$DESIGN"

# Create top-level directories
mkdir -p "$BASE_LOG_DIR" "$BASE_REPORT_DIR" "$BASE_RESULT_DIR"

# Check for intermediate directories like 'base' that exist between the design name directory and run folders
# (common pattern in OpenROAD-flow-scripts)
if [[ -d "$BASE_LOG_DIR/base" ]]; then
  echo "Found intermediate 'base' directory structure"
  BASE_LOG_DIR="$BASE_LOG_DIR/base"
  BASE_REPORT_DIR="$BASE_REPORT_DIR/base"
  BASE_RESULT_DIR="$BASE_RESULT_DIR/base"
  mkdir -p "$BASE_LOG_DIR" "$BASE_REPORT_DIR" "$BASE_RESULT_DIR"
fi

# Determine the next run number with better file locking to prevent race conditions
# Check for an existing run counter file
RUN_COUNTER_FILE="$BASE_LOG_DIR/run_counter.txt"
RUN_COUNTER_LOCK="$BASE_LOG_DIR/run_counter.lock"

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
  
  # Release the lock only if it exists
  [[ -d "$RUN_COUNTER_LOCK" ]] && rmdir "$RUN_COUNTER_LOCK" 2>/dev/null
}

# Function to get the next run number without incrementing yet
get_next_run_number() {
  # Ensure counter file path is properly set and valid
  if [[ -z "$RUN_COUNTER_FILE" || "$(dirname "$RUN_COUNTER_FILE")" == "/" ]]; then
    echo "ERROR: RUN_COUNTER_FILE path is invalid: '$RUN_COUNTER_FILE'"
    echo "Setting a default run number 1 and continuing"
    NEXT_RUN=1
    return
  fi

  echo "Debug: Looking for counter file at: $RUN_COUNTER_FILE"
  
  # Create parent directory if it doesn't exist
  if [[ ! -d "$(dirname "$RUN_COUNTER_LOCK")" ]]; then
    mkdir -p "$(dirname "$RUN_COUNTER_LOCK")" 2>/dev/null || { echo "Cannot create directory for lock file - using no locking"; NEXT_RUN=1; return; }
  fi
  
  # Try to create lock with timeout to avoid infinite wait
  local TIMEOUT=10
  local COUNT=0
  while ! mkdir "$RUN_COUNTER_LOCK" 2>/dev/null; do
    echo "Waiting for lock on run counter..."
    sleep 1
    COUNT=$((COUNT+1))
    if [[ $COUNT -gt $TIMEOUT ]]; then
      echo "Lock wait timeout - continuing without lock"
      break
    fi
  done
  
  # If user specified a run number, use that directly
  if [[ -n "$RUN_COUNTER" ]]; then
    NEXT_RUN=$RUN_COUNTER
    echo "User specified run number: $NEXT_RUN"
    echo "$NEXT_RUN" > "$RUN_COUNTER_FILE"
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
  
  echo "Using run number: $NEXT_RUN"
  
  # Release the lock only if it exists
  [[ -d "$RUN_COUNTER_LOCK" ]] && rmdir "$RUN_COUNTER_LOCK" 2>/dev/null
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
    # Use sed to update only the perturbation factor line, preserving all other content
    if grep -q "PERTURBATION_FACTOR=" "$WEIGHT_GEN_STATE_FILE"; then
      # Update the existing PERTURBATION_FACTOR line
      TMP_STATE_FILE="${WEIGHT_GEN_STATE_FILE}.tmp"
      cat "$WEIGHT_GEN_STATE_FILE" | sed "s/PERTURBATION_FACTOR=.*/PERTURBATION_FACTOR=$RUN_NUM.0/" > "$TMP_STATE_FILE"
      mv "$TMP_STATE_FILE" "$WEIGHT_GEN_STATE_FILE"
      echo "Updated perturbation factor to $RUN_NUM.0 for run $RUN_NUM"
    else
      # Old format - handle gracefully by converting
      MODE_LINE=$(head -1 "$WEIGHT_GEN_STATE_FILE" || echo "MODE=auto")
      echo "MODE=$MODE_LINE" > "$WEIGHT_GEN_STATE_FILE"
      echo "PERTURBATION_FACTOR=$RUN_NUM.0" >> "$WEIGHT_GEN_STATE_FILE"
      echo "USE_COMPLETELY_RANDOM=False" >> "$WEIGHT_GEN_STATE_FILE"
      echo "RANDOM_SEED=1" >> "$WEIGHT_GEN_STATE_FILE"
      echo "Converted old state file format and set perturbation factor to $RUN_NUM.0"
    fi
  else
    # Create the state file if it doesn't exist
    echo "MODE=auto" > "$WEIGHT_GEN_STATE_FILE"
    echo "PERTURBATION_FACTOR=$RUN_NUM.0" >> "$WEIGHT_GEN_STATE_FILE"
    echo "USE_COMPLETELY_RANDOM=False" >> "$WEIGHT_GEN_STATE_FILE"
    echo "RANDOM_SEED=1" >> "$WEIGHT_GEN_STATE_FILE"
    echo "Created new state file with perturbation factor $RUN_NUM.0 for run $RUN_NUM"
  fi
  
  echo "Generating design-specific routing weights for $DESIGN..."
  # Directly modify the state file to ensure perturbation factor matches run number
  # This is a critical step that must happen before calling weight_generator.py
  if grep -q "PERTURBATION_FACTOR=" "$WEIGHT_GEN_STATE_FILE"; then
    # Update the existing PERTURBATION_FACTOR line
    TMP_STATE_FILE="${WEIGHT_GEN_STATE_FILE}.tmp"
    cat "$WEIGHT_GEN_STATE_FILE" | sed "s/PERTURBATION_FACTOR=.*/PERTURBATION_FACTOR=$RUN_NUM.0/" > "$TMP_STATE_FILE"
    mv "$TMP_STATE_FILE" "$WEIGHT_GEN_STATE_FILE"
    echo "Pre-set perturbation factor to $RUN_NUM.0 for run $RUN_NUM"
  fi
  
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
      # Copy to result dir for reference
      cp "$WEIGHTS_FILE" "$RESULT_DIR/weights.csv"
    else
      echo "⚠️ Failed to generate weights file. Using default weights."
      WEIGHTS_FILE=""
      WEIGHTS_FILE_ABS=""
    fi
  fi
  
  # Create direct tcl script that uses OpenROAD commands directly
  DRT_WRAPPER="$RESULT_DIR/drt_run_$RUN_NUM.tcl"
  
  # Create Tcl script for detailed routing
  echo "# Direct detailed routing script for $DESIGN - Run $RUN_NUM" > "$DRT_WRAPPER"
  echo "puts \"Loading design files for $DESIGN...\"" >> "$DRT_WRAPPER"
  
  # Print debug information for the files being used
  echo "\n===== DEBUG INFORMATION ====="
  echo "Design: $DESIGN"
  echo "Run Number: $RUN_NUM"
  echo "Using flow files: $USE_FLOW_FILES"
  echo "LEF file: $LEF_FILE (exists: $([[ -f "$LEF_FILE" ]] && echo "yes" || echo "no"))"
  echo "MACRO_LEF: $MACRO_LEF"
  echo "DEF file: $DEF_FILE (exists: $([[ -f "$DEF_FILE" ]] && echo "yes" || echo "no"))"
  echo "Guide file: $GUIDE_FILE (exists: $([[ -f "$GUIDE_FILE" ]] && echo "yes" || echo "no"))"
  echo "===========================\n"
  
  if [[ "$USE_FLOW_FILES" == true ]]; then
    # Use flow-generated files with tech LEF first, then macro LEF
    echo "# Using flow-generated files with absolute paths" >> "$DRT_WRAPPER"
    echo "read_lef \"$LEF_FILE\"" >> "$DRT_WRAPPER"
    
    # Handle multiple macro LEF files if needed
    if [[ "$MACRO_LEF" == *" "* ]]; then
      # Multiple LEF files were found (space-separated)
      echo "# Multiple macro LEF files detected" >> "$DRT_WRAPPER"
      for macro_lef in $MACRO_LEF; do
        if [[ -f "$macro_lef" ]]; then
          echo "read_lef \"$macro_lef\"" >> "$DRT_WRAPPER"
          echo "Including macro LEF: $macro_lef"
        fi
      done
    elif [[ -n "$MACRO_LEF" ]]; then
      # Single macro LEF file
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
    # Set up signal traps to catch unexpected terminations
    trap 'echo "[$(date)] Process received SIGTERM signal - terminating" >> "$LOG_FILE"' TERM
    trap 'echo "[$(date)] Process received SIGINT signal - terminating" >> "$LOG_FILE"' INT
    trap 'echo "[$(date)] Process received SIGKILL signal - terminating" >> "$LOG_FILE" 2>/dev/null' KILL
    trap 'echo "[$(date)] Process received other signal - terminating" >> "$LOG_FILE"' HUP QUIT ABRT
    
    # Add a memory monitor in the background
    (
      PID="$$"  # Parent PID
      while kill -0 $PID 2>/dev/null; do
        CHILD_PID=$(pgrep -P $PID openroad 2>/dev/null)
        if [ ! -z "$CHILD_PID" ]; then
          MEM_USAGE=$(ps -o rss= -p $CHILD_PID 2>/dev/null || echo "N/A")
          echo "[$(date)] OpenROAD Memory Usage: ${MEM_USAGE:-N/A} KB" >> "${LOG_FILE}.memlog"
          # If memory is extremely high, log a warning
          if [ ! -z "$MEM_USAGE" ] && [ $MEM_USAGE -gt 25000000 ]; then
            echo "[$(date)] WARNING: Very high memory usage detected: $MEM_USAGE KB" >> "$LOG_FILE"
          fi
        fi
        sleep 10
      done
    ) &
    MONITOR_PID=$!
    
    # Use timeout to prevent indefinite hangs (7200 seconds = 2 hours)
    set -o pipefail  # Ensure pipeline errors are captured
    timeout 7200 ./tools/OpenROAD/build/src/openroad -no_init -threads $NUM_CORES -exit "$DRT_WRAPPER" |& tee -a "$LOG_FILE"
    ROUTE_EXIT_CODE=$?
    
    # Kill the memory monitor
    kill $MONITOR_PID 2>/dev/null || true
    
    # Log the exit code explicitly
    echo "[$(date)] OpenROAD process exited with code: $ROUTE_EXIT_CODE" >> "$LOG_FILE"
    return $ROUTE_EXIT_CODE
    # Note: The following line is commented out because we already capture and return the exit code
    # RUN_STATUS=$?
    
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
# Confirm we're still using the correct design name before proceeding
echo "Final confirmation - using design: $DESIGN"
if [[ -z "$DESIGN" ]]; then
  echo "Error: Design name is empty! Cannot proceed with routing."
  exit 1
fi

# Explain the choice between DESIGN_NAME and DESIGN_NICKNAME if applicable
if [[ -n "$DESIGN_NAME" && -n "$DESIGN_NICKNAME" && "$DESIGN_NAME" != "$DESIGN_NICKNAME" ]]; then
  echo "Note: This design has both DESIGN_NAME ($DESIGN_NAME) and DESIGN_NICKNAME ($DESIGN_NICKNAME)"
  echo "Using '$DESIGN' for directories and files for consistency with existing structure"  
fi

# Note: Directory structure was already set up earlier with platform name and base dir
# Keep using the paths that already include platform and 'base' directory
# DO NOT reset these variables - preserving current values
# BASE_LOG_DIR="$FLOW_DIR/logs/$DESIGN"
# BASE_REPORT_DIR="$FLOW_DIR/reports/$DESIGN"
# BASE_RESULT_DIR="$FLOW_DIR/results/$DESIGN"

# Initialize counter for successful/failed runs
success_count=0
failure_count=0

# Handle run range if specified
if [[ -n "$END_RUN" ]]; then
  # If both run and run2 are specified, use them as a range
  if [[ -n "$RUN_COUNTER" ]]; then
    START_RUN=$RUN_COUNTER
    # Calculate loops based on the range
    LOOPS=$((END_RUN - START_RUN + 1))
    if [[ $LOOPS -lt 1 ]]; then
      echo "Error: End run number must be greater than or equal to start run number"
      exit 1
    fi
    echo "Range mode: Will execute runs $START_RUN through $END_RUN (total: $LOOPS runs)"
  else
    # If only run2 is specified but not run, use NEXT_RUN as start
    START_RUN=$NEXT_RUN
    LOOPS=$((END_RUN - START_RUN + 1))
    if [[ $LOOPS -lt 1 ]]; then
      echo "Error: End run number must be greater than or equal to next available run number ($NEXT_RUN)"
      exit 1
    fi
    echo "Range mode: Will execute runs $START_RUN through $END_RUN (total: $LOOPS runs)"
  fi
else
  # If no range is specified, use the original behavior with NEXT_RUN and LOOPS
  START_RUN=$NEXT_RUN
  echo "Loop mode: Will execute $LOOPS iterations starting with run $START_RUN"
fi

# Print the header
echo "============================================================"
echo "Running TritonRoute for $DESIGN"
if [[ -n "$END_RUN" ]]; then
  echo "Performing runs $START_RUN through $END_RUN (total: $LOOPS runs)"
else
  echo "Performing $LOOPS iterations, starting with run $START_RUN"
fi
echo "============================================================"

# Run the specified number of iterations with better logging and error handling
for ((i=0; i<$LOOPS; i++)); do
  current_run=$((START_RUN + i))
  
  # Run a single TritonRoute iteration
  if run_single_iteration "$current_run" $((i+1)) "$LOOPS"; then
    ((success_count++))
    echo "Run $current_run - $(date) - $DESIGN" >> "$RUN_SUMMARY_FILE"
    
    # Increment counter after successful run
    if [[ -z "$RUN_COUNTER" ]]; then
      # Check if increment_counter function is defined before calling it
      if type increment_counter &>/dev/null; then
        increment_counter
      else
        echo "Warning: Could not increment run counter \(function not defined in this context\)"
      fi
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
