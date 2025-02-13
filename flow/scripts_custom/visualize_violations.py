import matplotlib.pyplot as plt
import os
import re
from routeParser import parse_violations_file, parse_box_coordinates

def parse_boxes_from_log(log_file):
    """Parse box coordinates from routing log file"""
    boxes = []
    current_iteration = None
    iteration_boxes = {}
    
    print("Opening log file...")
    with open(log_file, 'r') as f:
        print("Reading log file lines...")
        for line in f:
            # Check for iteration marker
            if "optimization iteration" in line:
                match = re.search(r'Start (\d+)', line)
                if match:
                    current_iteration = int(match.group(1))
                    print(f"Found iteration {current_iteration}")
                    iteration_boxes[current_iteration] = []
            
            # Parse box coordinates
            if current_iteration is not None and "start DR worker (BOX)" in line:
                # Format: start DR worker (BOX) ( x1 y1 ) ( x2 y2 )
                match = re.search(r'BOX\) \( (\d+\.?\d*) (\d+\.?\d*) \) \( (\d+\.?\d*) (\d+\.?\d*) \)', line)
                if match:
                    x1, y1, x2, y2 = map(float, match.groups())
                    coords = (x1, y1, x2, y2)
                    print(f"Found box coordinates: {coords}")
                    iteration_boxes[current_iteration].append(coords)
    
    print(f"Finished parsing, found iterations: {list(iteration_boxes.keys())}")
    return iteration_boxes

def plot_boxes_and_violations(iteration, boxes, violations, output_dir):
    """Create a plot showing boxes and violations for an iteration"""
    plt.figure(figsize=(15, 15))
    ax = plt.gca()
    
    # Plot boxes in blue with alpha for transparency
    for box in boxes:
        x1, y1, x2, y2 = box
        width = x2 - x1
        height = y2 - y1
        rect = plt.Rectangle((x1, y1), width, height, fill=False, color='blue', linewidth=1, label='Routing Box')
        ax.add_patch(rect)
    
    # Plot violations in red
    for violation in violations:
        x1, y1, x2, y2 = violation
        width = x2 - x1
        height = y2 - y1
        rect = plt.Rectangle((x1, y1), width, height, color='red', alpha=0.5, label='Violation')
        ax.add_patch(rect)
    
    # Remove duplicate labels
    handles, labels = plt.gca().get_legend_handles_labels()
    by_label = dict(zip(labels, handles))
    plt.legend(by_label.values(), by_label.keys())
    
    # Set title and labels
    plt.title(f'Iteration {iteration}: Routing Boxes and Violations')
    plt.xlabel('X Coordinate')
    plt.ylabel('Y Coordinate')
    
    # Set equal aspect ratio and adjust limits
    plt.axis('equal')
    
    # Add grid
    plt.grid(True, linestyle='--', alpha=0.3)
    
    # Save plot
    output_file = os.path.join(output_dir, f'iteration_{iteration}_visualization.png')
    plt.savefig(output_file, dpi=300, bbox_inches='tight')
    plt.close()
    print(f"Generated visualization for iteration {iteration}: {output_file}")

def main():
    # Use relative paths from current directory
    log_file = '../logs_backup/nangate45/gcd/base/run_10/5_2_route.log'
    reports_dir = '../reports_backup/run_10'
    output_dir = 'visualizations'
    
    print(f"Reading log file: {log_file}")
    print(f"Reading reports from: {reports_dir}")
    
    # Create output directory if it doesn't exist
    os.makedirs(output_dir, exist_ok=True)
    print(f"Created output directory: {output_dir}")
    
    # Parse boxes from log file
    print("Starting to parse boxes...")
    iteration_boxes = parse_boxes_from_log(log_file)
    
    # Process each iteration
    for iteration in range(1, 4):  # Iterations 1 through 3
        print(f"\nProcessing iteration {iteration}")
        if iteration in iteration_boxes:
            boxes = iteration_boxes[iteration]
            print(f"Getting violations for iteration {iteration}")
            violations = parse_violations_file(reports_dir, iteration)
            
            print(f"\nIteration {iteration}:")
            print(f"Found {len(boxes)} boxes")
            print(f"Found {len(violations)} violations")
            
            # Create visualization
            print(f"Creating visualization for iteration {iteration}")
            plot_boxes_and_violations(iteration, boxes, violations, output_dir)
        else:
            print(f"No boxes found for iteration {iteration}")

if __name__ == "__main__":
    main()
