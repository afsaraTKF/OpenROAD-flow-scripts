import os
import re
import math
import pandas as pd
import json
from collections import defaultdict
import datetime

# Define the columns for our CSV output
columns = ["uniqueID", "designID", "iteration", "pin_count", "net_count", "drv", "wireLength",
           "drc_weight", "marker_weight", "fixed_weight", "decay_weight"]
iteration_data = []  # Will store per-iteration data for CSV output

# Dictionary to store box violations and coordinates: {uniqueID: {box_index: {'coords': [], 'drv': []}}}
box_violations = {}

# Dictionary to store boxes for each iteration: {uniqueID: {iteration: [(coords, box_coords, drv_count)]}}
iteration_boxes = {}

# Track max iterations per uniqueID
max_iterations = {}

# Counter for unique IDs
current_uniqueID = 1

def parse_violations_file(log_dir, iteration, run_id=None):
    """Parse violations from the violations report file"""
    # Try multiple possible locations for the violations file
    possible_paths = []
    
    # 1. If run_id is provided, try in the run directory
    if run_id:
        possible_paths.append(os.path.join(log_dir, run_id, f"violations-{iteration}.rpt"))
    
    # 2. Try directly in the log directory
    possible_paths.append(os.path.join(log_dir, f"violations-{iteration}.rpt"))
    
    # 3. Try in a 'violations' subdirectory
    possible_paths.append(os.path.join(log_dir, "violations", f"violations-{iteration}.rpt"))
    
    # Try each path
    violations_file = None
    for path in possible_paths:
        if os.path.exists(path):
            violations_file = path
            break
    
    if not violations_file:
        print(f"Warning: Violations file not found in any location for iteration {iteration}")
        return []
    
    violations = []
    with open(violations_file, 'r') as f:
        for line in f:
            if "bbox" in line:
                coords = parse_violation_coordinates(line)
                if coords:
                    violations.append(coords)
    
    if len(violations) > 0:  # Only print if violations found
        print(f"Found {len(violations)} violations in iteration {iteration}")
    return violations

def parse_violation_coordinates(line):
    """Parse coordinates from format: bbox = (32.9300, 88.9700) - (32.9900, 89.1450) on Layer metal2"""
    match = re.search(r'bbox = \(([\d.]+),\s*([\d.]+)\)\s*-\s*\(([\d.]+),\s*([\d.]+)\)\s*on Layer', line)
    if match:
        return tuple(float(x) for x in match.groups())
    return None

def parse_box_coordinates(box_str):
    """Parse box coordinates from string like '( 0.0 0.0 ) ( 14.7 14.7 )'"""
    pattern = r'\(\s*([\d.]+)[\s,]+([\d.]+)\s*\)\s*\(\s*([\d.]+)[\s,]+([\d.]+)\s*\)'
    match = re.match(pattern, box_str)
    if match:
        return tuple(float(x) for x in match.groups())
    return None

def is_violation_in_box(violation_coords, box_coords, tolerance=0.001):
    """Check if a violation falls within or on the edge of a box's boundaries.
    Also returns whether the violation is on an edge."""
    v_x1, v_y1, v_x2, v_y2 = violation_coords
    b_x1, b_y1, b_x2, b_y2 = box_coords
    
    # Helper function to check if a point is on an edge
    def is_on_edge(point, edge_coord):
        return abs(point - edge_coord) <= tolerance
    
    # Check if violation touches or is within box boundaries
    x_overlap = (b_x1 - tolerance <= v_x2) and (b_x2 + tolerance >= v_x1)
    y_overlap = (b_y1 - tolerance <= v_y2) and (b_y2 + tolerance >= v_y1)
    
    if not (x_overlap and y_overlap):
        return False, None
    
    # Check if violation is on an edge
    on_left = is_on_edge(v_x1, b_x1) or is_on_edge(v_x2, b_x1)
    on_right = is_on_edge(v_x1, b_x2) or is_on_edge(v_x2, b_x2)
    
    edge = None
    if on_left:
        edge = 'left'
    elif on_right:
        edge = 'right'
    
    return True, edge

def find_box_neighbors(boxes):
    """Find left and right neighbors for each box"""
    # Sort boxes by x-coordinate, then y-coordinate
    sorted_boxes = sorted(boxes, key=lambda b: (b['coords'][0], b['coords'][1]))
    
    # Reset all neighbor relationships
    for box in sorted_boxes:
        box['left_neighbor'] = None
        box['right_neighbor'] = None
    
    # For each box, find its neighbors
    for i, box in enumerate(sorted_boxes):
        x1, y1, x2, y2 = box['coords']
        
        # Look for right neighbor
        for j in range(i + 1, len(sorted_boxes)):
            next_box = sorted_boxes[j]
            nx1, ny1, nx2, ny2 = next_box['coords']
            
            # Check if boxes share an edge (x2 of current = x1 of next)
            if abs(x2 - nx1) < 0.001:
                # Check for y-overlap
                if max(y1, ny1) < min(y2, ny2):
                    box['right_neighbor'] = next_box
                    next_box['left_neighbor'] = box
                    break

def get_violations_for_box(box_coords, violations):
    """Count violations in a single box"""
    return [v for v in violations if is_violation_in_box(v, box_coords)[0]]

def process_log_file(log_file, reports_dir=None):
    """Process a single detailed routing log file and corresponding violations"""
    if not os.path.exists(log_file):
        raise FileNotFoundError(f"Route log not found: {log_file}")
    
    # Use reports_dir if provided, otherwise use log file directory
    violations_dir = reports_dir if reports_dir else os.path.dirname(log_file)
    
    # Extract run_id from the log file path
    run_id = os.path.basename(os.path.dirname(log_file))
    
    box_tracker = BoxTracker(run_id)
    current_iteration = -1
    max_iteration = -1
    boxes_for_iteration = []
    
    # Pattern to match iteration lines
    iter_pattern = r'\[INFO DRT-0195\] Start (\d+)(?:st|nd|rd|th) optimization iteration(?: with cost weights \[([^\]]+)\])?'
    box_pattern = r'start DR worker \(BOX\)\s*\(\s*([\d.-]+)\s+([\d.-]+)\s*\)\s*\(\s*([\d.-]+)\s+([\d.-]+)\s*\)'
    
    print("\nProcessing route log...")
    box_count = 0
    with open(log_file, 'r') as f:
        for i, line in enumerate(f):
            # Print first 20 lines to see format
            if i < 20:
                print(f"Line {i}: {line.strip()}")
            
            iter_match = re.search(iter_pattern, line)
            if iter_match:
                # If we have boxes from previous iteration, add them now
                if boxes_for_iteration and current_iteration > 0:
                    for box_coords in boxes_for_iteration:
                        box_tracker.add_box(box_coords)
                        box_count += 1
                    
                    # Now parse and add violations for previous iteration
                    violations = parse_violations_file(violations_dir, current_iteration, run_id)
                    if violations:
                        box_tracker.add_violations(violations)
                
                # Start new iteration
                current_iteration = int(iter_match.group(1))
                max_iteration = max(max_iteration, current_iteration)
                boxes_for_iteration = []
                
                # Skip 0th iteration since it has no violations file
                if current_iteration > 0:
                    box_tracker.start_iteration(current_iteration)
                    print(f"\nStarting iteration {current_iteration}")
            
            # Look for box coordinates
            if "start DR worker (BOX)" in line:
                # print(f"\nFound box line: {line.strip()}")
                box_match = re.search(box_pattern, line)
                if box_match:
                    x1, y1, x2, y2 = map(float, box_match.groups())
                    box_coords = (x1, y1, x2, y2)
                    boxes_for_iteration.append(box_coords)
                    # print(f"Added box with coords: {box_coords}")
                else:
                    print(f"Failed to match box pattern in line: {line.strip()}")
    
    # Handle last iteration
    if boxes_for_iteration and current_iteration > 0:
        for box_coords in boxes_for_iteration:
            box_tracker.add_box(box_coords)
            box_count += 1
        
        violations = parse_violations_file(violations_dir, current_iteration, run_id)
        if violations:
            box_tracker.add_violations(violations)
    
    print(f"Processed {box_count} boxes across {max_iteration} iterations")
    return box_tracker

def process_single_file_new(log_file_path, output_dir=None, reports_dir=None):
    """Process a single log file and return the extracted data"""
    # Process the log file
    box_tracker = process_log_file(log_file_path, reports_dir)
    
    # If output directory is specified, save the results
    if output_dir:
        os.makedirs(output_dir, exist_ok=True)
        output_file = os.path.join(output_dir, f"box_violations_{box_tracker.run_id}.txt")
        write_box_report(box_tracker, output_file)
        
    return box_tracker

def print_statistics(box_tracker):
    """Print statistics about violations and boxes"""
    total_boxes = 0
    total_violations = 0
    boxes_with_violations = 0
    
    for iteration in sorted(box_tracker.iterations.keys()):
        iteration_boxes = len(box_tracker.iterations[iteration]['boxes'])
        iteration_violations = len(box_tracker.iterations[iteration].get('violations', []))
        boxes_with_drv = sum(1 for box in box_tracker.iterations[iteration]['boxes'] if box['drv_count'] > 0)
        
        print(f"\nIteration {iteration}:")
        print(f"  Total boxes: {iteration_boxes}")
        print(f"  Total violations: {iteration_violations}")
        print(f"  Total violations in boxes: {box_tracker.iterations[iteration]['total_drv']}")
        print(f"  Boxes with violations: {boxes_with_drv}")
        
        total_boxes += iteration_boxes
        total_violations += iteration_violations
        boxes_with_violations += boxes_with_drv
    
    print("\nOverall Statistics:")
    print(f"Total boxes processed: {total_boxes}")
    print(f"Total violations found: {total_violations}")
    print(f"Total boxes with violations: {boxes_with_violations}")

def write_box_report(box_tracker, output_file):
    """Write box analysis report to file"""
    with open(output_file, 'w') as f:
        f.write("Box Analysis Report\n")
        f.write("==================\n\n")
        
        for iteration in sorted(box_tracker.iterations.keys()):
            # Skip iteration 0 as we don't have violation data for it
            if iteration == 0:
                continue
                
            f.write(f"Iteration {iteration}:\n")
            f.write("-" * 50 + "\n\n")
            
            boxes = box_tracker.iterations[iteration]['boxes']
            for box in boxes:
                f.write(f"Box ID: {box['id']}\n")
                f.write(f"Coordinates: {box['coords']}\n")
                f.write(f"Size: dx={box['dx']:.4f}, dy={box['dy']:.4f}, area={box['area']:.4f}\n")
                f.write(f"DRV Count: {box['drv_count']}\n")
                
                # Get neighbor IDs and their DRV counts
                left = box['left_neighbor']
                right = box['right_neighbor']
                f.write(f"Left Neighbor: {left['id'] if left else 'None'}\n")
                f.write(f"L_N_DRV: {box['left_neighbor_drv']}\n")
                f.write(f"Right Neighbor: {right['id'] if right else 'None'}\n")
                f.write(f"R_N_DRV: {box['right_neighbor_drv']}\n")
                f.write("\n")

class BoxTracker:
    def __init__(self, run_id=None):
        self.iterations = {}
        self.current_iteration = -1
        # Generate a unique run ID if none provided
        self.run_id = run_id if run_id else self._generate_run_id()
        
    def _generate_run_id(self):
        """Generate a unique run ID using timestamp"""
        import time
        return f"run_{int(time.time())}"
            
    def start_iteration(self, iteration):
        """Start tracking a new iteration"""
        self.current_iteration = iteration
        if iteration not in self.iterations:
            self.iterations[iteration] = {
                'boxes': [],
                'violations': [],
                'total_drv': 0  # Add counter for total violations
            }
            
    def add_box(self, box_coords):
        """Add a box to the current iteration"""
        if self.current_iteration not in self.iterations:
            return
            
        # Create box ID including run ID
        box_id = f"{self.run_id}_iter{self.current_iteration}_x{box_coords[0]}_y{box_coords[1]}"
        
        # Store box data with all coordinates
        box_data = {
            'id': box_id,
            'run_id': self.run_id,
            'coords': tuple(map(float, box_coords)),  # Ensure all coords are float
            'drv_count': 0,
            'violations': [],  # Store the actual violations
            'left_neighbor': None,
            'left_neighbor_drv': 0,
            'right_neighbor': None,
            'right_neighbor_drv': 0,
            'dx': box_coords[2] - box_coords[0],  # Width of the box
            'dy': box_coords[3] - box_coords[1],  # Height of the box
            'area': (box_coords[2] - box_coords[0]) * (box_coords[3] - box_coords[1])  # Area of the box
        }
        
        self.iterations[self.current_iteration]['boxes'].append(box_data)
        
        # Update neighbor relationships
        find_box_neighbors(self.iterations[self.current_iteration]['boxes'])
        
    def add_violations(self, violations):
        """Add violations to the current iteration"""
        if not violations:
            print("No violations to process")
            return

        print(f"\nProcessing {len(violations)} violations for iteration {self.current_iteration}")
        
        # Store total violations count in iteration data
        self.iterations[self.current_iteration]['violations'] = len(violations)
        
        # Reset violation counts for this iteration
        self.iterations[self.current_iteration]['total_drv'] = 0
        for box in self.iterations[self.current_iteration]['boxes']:
            box['drv_count'] = 0
            box['left_neighbor_drv'] = 0
            box['right_neighbor_drv'] = 0
        
        # Create spatial index for boxes
        box_ranges = []
        for i, box in enumerate(self.iterations[self.current_iteration]['boxes']):
            x1, y1, x2, y2 = box['coords']
            box_ranges.append((x1, x2, y1, y2, i))  # Store box index for lookup
        
        # Sort boxes by x1 coordinate for faster lookup
        box_ranges.sort(key=lambda x: x[0])
        
        violation_count = 0
        # Process violations in batches to reduce memory usage
        batch_size = 1000
        for i in range(0, len(violations), batch_size):
            batch = violations[i:i+batch_size]
            
            # Process each violation
            for violation in batch:
                v_x1, v_y1, v_x2, v_y2 = violation
                
                # Find potential boxes that could contain this violation
                potential_boxes = []
                for box_x1, box_x2, box_y1, box_y2, box_idx in box_ranges:
                    if box_x1 > v_x2 + 0.001:  # Since boxes are sorted by x1, we can break early
                        break
                    if box_x2 + 0.001 >= v_x1:  # Box's x-range overlaps with violation
                        potential_boxes.append(box_idx)
                
                # Check all potential boxes - don't break after first match
                affected_boxes = []
                for box_idx in potential_boxes:
                    box = self.iterations[self.current_iteration]['boxes'][box_idx]
                    is_in_box, edge = is_violation_in_box(violation, box['coords'])
                    if is_in_box:
                        box['drv_count'] += 1
                        self.iterations[self.current_iteration]['total_drv'] += 1
                        violation_count += 1
                        affected_boxes.append((box, edge))
            
                # Update neighbor DRV counts for affected boxes
                for box, edge in affected_boxes:
                    if edge == 'left' and box['left_neighbor']:
                        box['left_neighbor']['drv_count'] += 1
                        self.iterations[self.current_iteration]['total_drv'] += 1
                    elif edge == 'right' and box['right_neighbor']:
                        box['right_neighbor']['drv_count'] += 1
                        self.iterations[self.current_iteration]['total_drv'] += 1
        
        # Print progress every 10000 violations
        if (i + batch_size) % 10000 == 0:
            print(f"Processed {i + batch_size}/{len(violations)} violations. Found {violation_count} violations in boxes.")
    
        # Update neighbor DRV counts after all violations are processed
        for box in self.iterations[self.current_iteration]['boxes']:
            if box['left_neighbor']:
                box['left_neighbor_drv'] = box['left_neighbor']['drv_count']
            if box['right_neighbor']:
                box['right_neighbor_drv'] = box['right_neighbor']['drv_count']
    
        print(f"Total violations for iteration {self.current_iteration}: {self.iterations[self.current_iteration]['total_drv']}\n")

    def write_results(self, output_file):
        """Write results to output file"""
        with open(output_file, 'w') as f:
            total_boxes = 0
            total_violations = 0
            total_boxes_with_violations = 0

            for iteration in sorted(self.iterations.keys()):
                # Write iteration header
                f.write(f"\nIteration {iteration}:\n")
                
                # Count boxes and violations for this iteration
                boxes = self.iterations[iteration]['boxes']
                num_boxes = len(boxes)
                total_boxes += num_boxes
                
                # Count violations in this iteration
                iter_violations = self.iterations[iteration]['total_drv']
                boxes_with_violations = sum(1 for box in boxes if box['drv_count'] > 0)
                
                total_violations += iter_violations
                total_boxes_with_violations += boxes_with_violations
                
                # Write iteration statistics
                f.write(f"  Total boxes: {num_boxes}\n")
                f.write(f"  Total violations: {iter_violations}\n")
                f.write(f"  Boxes with violations: {boxes_with_violations}\n")

            # Write overall statistics
            f.write("\nOverall Statistics:\n")
            f.write(f"Total boxes processed: {total_boxes}\n")
            f.write(f"Total violations found: {total_violations}\n")
            f.write(f"Total boxes with violations: {total_boxes_with_violations}\n")

def generate_box_id(coords):
    """Generate a unique ID for a box based on its coordinates"""
    if len(coords) >= 4:
        return f"iter{coords[0]}_{coords[1]}"
    return f"{coords[0]}_{coords[1]}"

def convert_windows_path_to_wsl(path):
    """Convert Windows WSL path to proper WSL path format"""
    # Remove any quotes
    path = path.strip('"')
    
    # Handle WSL paths
    if path.startswith("//wsl.localhost/"):
        # Remove the //wsl.localhost/ prefix and convert to absolute path
        path = "/" + "/".join(path.split("/")[3:])
    
    # Convert backslashes to forward slashes
    path = path.replace("\\", "/")
    
    # Keep spaces in path as they are
    print(f"Converted path: {path}")  # Debug print
    return path

def write_summary_txt(all_runs_data, output_file):
    """Write a human-readable summary to a text file"""
    with open(output_file, 'w') as f:
        f.write("=================================\n")
        f.write("   Routing Analysis Summary\n")
        f.write("=================================\n\n")
        
        # Overall summary with percentages
        f.write("Overall Statistics:\n")
        f.write("-----------------\n")
        total_runs = all_runs_data['summary']['total_runs']
        total_violations = all_runs_data['summary']['total_violations']
        total_boxes = all_runs_data['summary']['total_boxes']
        boxes_with_violations = all_runs_data['summary']['boxes_with_violations']
        
        f.write(f"Total runs processed: {total_runs}\n")
        f.write(f"Total violations found: {total_violations}\n")
        f.write(f"Total boxes processed: {total_boxes}\n")
        f.write(f"Total boxes with violations: {boxes_with_violations}\n")
        
        if total_boxes > 0:
            violation_rate = (boxes_with_violations / total_boxes) * 100
            violations_per_box = total_violations / total_boxes
            f.write(f"Percentage of boxes with violations: {violation_rate:.1f}%\n")
            f.write(f"Average violations per box: {violations_per_box:.2f}\n")
        f.write("\n")
        
        # Individual run details
        f.write("Details for Each Run:\n")
        f.write("-------------------\n")
        for run in sorted(all_runs_data['runs'], key=lambda x: x['run_name']):
            f.write(f"\nRun: {run['run_name']}\n")
            f.write("  " + "-" * 30 + "\n")
            f.write(f"  Log file: {os.path.basename(run['log_file'])}\n")
            f.write(f"  Total iterations: {run['total_iterations']}\n")
            f.write(f"  Total violations: {run['total_violations']}\n")
            f.write(f"  Total boxes: {run['total_boxes']}\n")
            f.write(f"  Boxes with violations: {run['boxes_with_violations']}\n")
            
            # Calculate percentages for this run
            if run['total_boxes'] > 0:
                run_violation_rate = (run['boxes_with_violations'] / run['total_boxes']) * 100
                run_violations_per_box = run['total_violations'] / run['total_boxes']
                f.write(f"  Percentage of boxes with violations: {run_violation_rate:.1f}%\n")
                f.write(f"  Average violations per box: {run_violations_per_box:.2f}\n")
        
        # Footer
        f.write("\n" + "=" * 50 + "\n")
        f.write("Note: A box may have multiple violations\n")
        f.write("Generated at: " + datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"))

def process_all_runs(logs_dir, reports_dir, output_dir=None):
    """Process all routing runs in the given directory structure."""
    import glob
    import json
    import re
    import os
    import pandas as pd  # Add pandas import
    
    # Reset the global iteration data list
    global iteration_data
    iteration_data = []
    
    # Convert paths to proper WSL format
    logs_dir = convert_windows_path_to_wsl(logs_dir)
    reports_dir = convert_windows_path_to_wsl(reports_dir)
    if output_dir:
        output_dir = convert_windows_path_to_wsl(output_dir)
    
    print(f"Looking for runs in: {logs_dir}")
    
    # Debug: Check if directory exists and list contents
    try:
        if os.path.exists(logs_dir):
            print(f"Directory exists: {logs_dir}")
            contents = os.listdir(logs_dir)
            print(f"Directory contents: {contents}")
        else:
            print(f"Directory does not exist: {logs_dir}")
            # Try listing parent directory
            parent_dir = os.path.dirname(logs_dir)
            if os.path.exists(parent_dir):
                print(f"Parent directory exists: {parent_dir}")
                print(f"Parent directory contents: {os.listdir(parent_dir)}")
    except Exception as e:
        print(f"Error checking directory: {str(e)}")
    
    # Create output directory if specified
    if output_dir:
        os.makedirs(output_dir, exist_ok=True)
    
    all_runs_data = {
        'runs': [],
        'summary': {
            'total_runs': 0,
            'total_violations': 0,
            'total_boxes': 0,
            'boxes_with_violations': 0
        }
    }
    
    # List all directories in logs_dir
    try:
        contents = os.listdir(logs_dir)
        print(f"Directory contents: {contents}")  # Debug print
        
        # Get all run folders from logs directory
        run_pattern = re.compile(r'run_\d+')
        log_run_dirs = [os.path.join(logs_dir, d) for d in contents 
                       if os.path.isdir(os.path.join(logs_dir, d)) and run_pattern.match(d)]
    except Exception as e:
        print(f"Error listing directory {logs_dir}: {str(e)}")
        return all_runs_data  # Return empty data instead of None
    
    print(f"Found {len(log_run_dirs)} run directories to process")
    if len(log_run_dirs) > 0:
        print("Run directories found:")
        for d in log_run_dirs:
            print(f"  - {d}")
    
    # Process each run directory
    for log_run_dir in log_run_dirs:
        run_name = os.path.basename(log_run_dir)
        print(f"\nProcessing run: {run_name}")
        
        # Find corresponding reports directory
        report_run_dir = os.path.join(reports_dir, run_name)
        if not os.path.exists(report_run_dir):
            print(f"Warning: No matching report directory found for {run_name}")
            continue
        
        # Find the route log file in the run directory
        log_files = glob.glob(os.path.join(log_run_dir, "*route*.log"))
        if not log_files:
            print(f"Warning: No route log file found in {run_name}")
            continue
        log_file = log_files[0]  # Take the first matching log file
        print(f"Found log file: {log_file}")
        
        # Create output directory for this run
        run_output_dir = os.path.join(output_dir, run_name) if output_dir else log_run_dir
        os.makedirs(run_output_dir, exist_ok=True)
        
        try:
            # Process the log file and its violations
            box_tracker = process_single_file_new(log_file, run_output_dir, report_run_dir)
            
            # Collect statistics for this run
            total_violations = 0
            total_boxes = len(box_tracker.iterations[1]['boxes']) if 1 in box_tracker.iterations else 0
            boxes_with_violations = 0
            
            if total_boxes > 0:
                for box in box_tracker.iterations[1]['boxes']:
                    # Only count the box's own violations to avoid triple counting
                    # since each box's violations also appear in neighbor data
                    box_violations = box['drv_count']
                    total_violations += box_violations
                    if box_violations > 0:
                        boxes_with_violations += 1
            
            # Process the log file for iteration-level data
            with open(log_file, 'r') as f:
                current_iteration = None
                current_weights = None
                lines = f.readlines()
                
                # Parse initial design information
                design_pins = 0
                design_nets = 0
                for line in lines:
                    # Improved parsing with regex for pins/nets
                    pins_match = re.search(r'Number of terminals:\s+(\d+)', line)
                    if pins_match:
                        design_pins = int(pins_match.group(1))
                        continue
                    
                    nets_match = re.search(r'Number of nets:\s+(\d+)', line)
                    if nets_match:
                        design_nets = int(nets_match.group(1))
                        continue
                    
                    if "[INFO DRT-0195]" in line:
                        break

                # Dictionary to store stats for each iteration
                iter_stats = {}
                
                for i, line in enumerate(lines):
                    # Parse iteration start and weights
                    iteration_match = re.search(r'\[INFO DRT-0195\] Start (\d+)(?:st|nd|rd|th) optimization iteration with cost weights \[([\d\. ]+)\]', line)
                    if iteration_match:
                        current_iteration = int(iteration_match.group(1))
                        weights = [float(w) for w in iteration_match.group(2).split()]
                        
                        # Initialize stats for this iteration
                        iter_stats[current_iteration] = {
                            "uniqueID": box_tracker.run_id,
                            "designID": run_name,
                            "iteration": current_iteration,
                            "pin_count": design_pins,
                            "net_count": design_nets,
                            "drv": 0,
                            "wireLength": 0,
                            "drc_weight": weights[0] if len(weights) > 0 else 0,
                            "marker_weight": weights[1] if len(weights) > 1 else 0,
                            "fixed_weight": weights[2] if len(weights) > 2 else 0,
                            "decay_weight": weights[3] if len(weights) > 3 else 0
                        }
                        
                        # Look ahead for statistics until next iteration
                        print(f"\nProcessing iteration {current_iteration}")  # Debug
                        
                        # Scan from current line until we find next iteration
                        for j in range(i+1, len(lines)):
                            stat_line = lines[j]
                            
                            # Debug - print every 20th line to see what we're scanning
                            if j % 20 == 0:
                                print(f"Scanning line {j}: {stat_line.strip()}")
                            
                            # Capture wire length
                            if "Total wire length = " in stat_line:
                                wire_length_match = re.search(r'Total wire length = (\d+) um', stat_line)
                                if wire_length_match:
                                    iter_stats[current_iteration]["wireLength"] = int(wire_length_match.group(1))
                                    print(f"Found wire length: {iter_stats[current_iteration]['wireLength']}")
                            
                            # Capture violations from "Completing" line

                            # Violation match should come from "Number of violations ="
                            violation_match = re.search(r'Number of violations = (\d+)', stat_line)
                            if violation_match:
                                iter_stats[current_iteration]["drv"] = int(violation_match.group(1))
                                print(f"Found violations: {iter_stats[current_iteration]['drv']}")
                            
                            # Stop if we reach next iteration
                            if "Start" in stat_line and "optimization iteration" in stat_line:
                                print(f"Found next iteration at line {j}")
                                break
                
                # Add all iterations to the global data
                for iter_data in iter_stats.values():
                    iteration_data.append(iter_data)
            
            run_stats = {
                'run_name': run_name,
                'log_file': log_file,
                'run_id': box_tracker.run_id,
                'total_iterations': len(iter_stats),
                'total_violations': total_violations,
                'total_boxes': total_boxes,
                'boxes_with_violations': boxes_with_violations
            }
            
            # Update all_runs_data
            all_runs_data['runs'].append(run_stats)
            all_runs_data['summary']['total_runs'] += 1
            all_runs_data['summary']['total_violations'] += run_stats['total_violations']
            all_runs_data['summary']['total_boxes'] += run_stats['total_boxes']
            all_runs_data['summary']['boxes_with_violations'] += run_stats['boxes_with_violations']
            
        except Exception as e:
            print(f"Error processing run {run_name}: {str(e)}")
            continue
    
    # Write all_runs_data to JSON file
    if output_dir:
        json_file = os.path.join(output_dir, 'all_runs_summary.json')
        with open(json_file, 'w') as f:
            json.dump(all_runs_data, f, indent=2)
        
        # Write human-readable summary
        txt_file = os.path.join(output_dir, 'all_runs_summary.txt')
        write_summary_txt(all_runs_data, txt_file)
        
        # Write iteration data to CSV
        if iteration_data:
            csv_file = os.path.join(output_dir, 'iterations_summary.csv')
            df = pd.DataFrame(iteration_data)
            df.to_csv(csv_file, index=False)
    
    return all_runs_data

if __name__ == "__main__":
    import argparse
    
    parser = argparse.ArgumentParser(description='Process routing log files and violation reports')
    parser.add_argument('--logs-dir', type=str, required=True,
                      help='Directory containing run folders with log files')
    parser.add_argument('--reports-dir', type=str, required=True,
                      help='Directory containing run folders with violation reports')
    parser.add_argument('--output-dir', type=str,
                      help='Directory to save output files (optional)')
    parser.add_argument('--run_id', type=str,
                      help='Process only this specific run ID')
    parser.add_argument('--iteration', type=int,
                      help='Process only this specific iteration')
    
    args = parser.parse_args()
    
    # If run_id and iteration are specified, process just that run and iteration
    if args.run_id and args.iteration is not None:
        log_file = os.path.join(args.logs_dir, args.run_id, "5_2_route.log")
        report_dir = os.path.join(args.reports_dir, args.run_id)
        
        # Create output directory for this run
        run_output_dir = os.path.join(args.output_dir, args.run_id) if args.output_dir else None
        if run_output_dir:
            os.makedirs(run_output_dir, exist_ok=True)
        
        # Process the log file and its violations
        box_tracker = process_single_file_new(log_file, run_output_dir, report_dir)
        
        # Print statistics for this iteration
        if args.iteration in box_tracker.iterations:
            total_violations = 0
            total_boxes = len(box_tracker.iterations[args.iteration]['boxes'])
            boxes_with_violations = 0
            
            if total_boxes > 0:
                for box in box_tracker.iterations[args.iteration]['boxes']:
                    box_violations = box['drv_count']
                    total_violations += box_violations
                    if box_violations > 0:
                        boxes_with_violations += 1
            
            print(f"\nStatistics for {args.run_id} iteration {args.iteration}:")
            print(f"Total boxes: {total_boxes}")
            print(f"Total violations: {total_violations}")
            print(f"Boxes with violations: {boxes_with_violations}")
    else:
        # Process all runs
        all_runs_data = process_all_runs(args.logs_dir, args.reports_dir, args.output_dir)
        
        # Print summary
        print("\nProcessing Complete!")
        print("==================")
        print(f"Total runs processed: {all_runs_data['summary']['total_runs']}")
        print(f"Total violations found: {all_runs_data['summary']['total_violations']}")
        print(f"Total boxes processed: {all_runs_data['summary']['total_boxes']}")
        print(f"Total boxes with violations: {all_runs_data['summary']['boxes_with_violations']}")
