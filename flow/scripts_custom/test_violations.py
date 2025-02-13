import os
from routeParser import BoxTracker, process_log_file, write_box_report

def create_test_files(test_dir):
    """Create test log and violation files"""
    # Create test directories
    os.makedirs(test_dir, exist_ok=True)
    
    # Create a sample route log
    log_content = """[INFO DRT-0195] Start 0th optimization iteration with cost weights [1 1 1 1]
[INFO DRT-0199] Number of violations = 42
Total wire length = 1000 um
start DR worker (BOX) (0 0) (100 100)

[INFO DRT-0195] Start 1st optimization iteration with cost weights [1 1 1 1]
[INFO DRT-0199] Number of violations = 35
Total wire length = 950 um
start DR worker (BOX) (0 0) (100 100)

[INFO DRT-0195] Start 2nd optimization iteration with cost weights [1 1 1 1]
[INFO DRT-0199] Number of violations = 28
Total wire length = 900 um
start DR worker (BOX) (0 0) (100 100)
"""
    log_file = os.path.join(test_dir, "test_route.log")
    with open(log_file, 'w') as f:
        f.write(log_content)
    
    # Create sample violation reports
    for i in range(3):
        violation_content = f"""[DRT-0199] Found violation:
bbox = (10.000, 10.000) - (20.000, 20.000)
[DRT-0199] Found violation:
bbox = (30.000, 30.000) - (40.000, 40.000)
"""
        with open(os.path.join(test_dir, f'violations-{i+1}.rpt'), 'w') as f:
            f.write(violation_content)
    
    return log_file

def test_box_tracking():
    """Test box tracking functionality"""
    # Get script directory and construct paths
    script_dir = os.path.dirname(os.path.abspath(__file__))
    flow_dir = os.path.dirname(script_dir)  # Up one level to flow
    
    # Look in reports directory for violations
    reports_dir = os.path.join(flow_dir, "reports - Copy", "nangate45", "aes", "base", "run_11")
    logs_dir = os.path.join(flow_dir, "logs - Copy", "nangate45", "aes", "base", "run_11")
    
    # Input files - route log is in logs directory
    log_file = os.path.join(logs_dir, "5_2_route.log")
    
    # Make sure we're using the right directories
    print(f"Looking for route log in: {log_file}")
    print(f"Looking for violation files in: {reports_dir}")
    
    # Output file
    output_dir = os.path.join(script_dir, "test_output")
    os.makedirs(output_dir, exist_ok=True)
    output_file = os.path.join(output_dir, "box_violations.txt")
    
    # Process the files
    box_tracker = process_log_file(log_file, reports_dir)
    
    # Save results
    write_box_report(box_tracker, output_file)
    print(f"\nResults saved to: {output_file}")
    
    # Print some statistics
    total_boxes = 0
    total_violations = 0
    boxes_with_violations = 0
    
    for iteration in sorted(box_tracker.iterations.keys()):
        # Write iteration header
        print(f"\nIteration {iteration}:")
        
        # Count boxes and violations for this iteration
        boxes = box_tracker.iterations[iteration]['boxes']
        iter_boxes = len(boxes)
        iter_violations = box_tracker.iterations[iteration]['total_drv']
        iter_boxes_with_violations = sum(1 for box in boxes if box['drv_count'] > 0)
        
        print(f"  Total boxes: {iter_boxes}")
        print(f"  Total violations: {iter_violations}")
        print(f"  Total violations in boxes: {box_tracker.iterations[iteration]['total_drv']}")
        print(f"  Boxes with violations: {iter_boxes_with_violations}")
        
        total_boxes += iter_boxes
        total_violations += iter_violations
        boxes_with_violations += iter_boxes_with_violations
    
    print(f"\nOverall Statistics:")
    print(f"Total boxes processed: {total_boxes}")
    print(f"Total violations found: {total_violations}")
    print(f"Total boxes with violations: {boxes_with_violations}")

if __name__ == "__main__":
    test_box_tracking()
