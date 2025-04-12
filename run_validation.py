#!/usr/bin/env python3

import os
import argparse
import re
import glob

def find_incomplete_runs(search_dir="logs", log_pattern="*route.log", success_string='[INFO DRT-0180] Post processing.'):
    """
    Identifies runs that are incomplete by checking for a success marker in log files.
    
    Args:
        search_dir: Directory to search for log files
        log_pattern: Pattern to match log files
        success_string: String that indicates a successful run completion
    
    Returns:
        List of tuples containing (tech_name, design_name, run_number, log_path)
    """
    print(f"Searching for incomplete runs in '{search_dir}'...")
    print(f"Looking for log files matching '{log_pattern}'")
    print(f"Success marker: '{success_string}'")
    
    # Find all log files matching the pattern
    log_files = glob.glob(os.path.join(search_dir, "**", log_pattern), recursive=True)
    
    if not log_files:
        print(f"No log files matching '{log_pattern}' found in '{search_dir}'.")
        return []
    
    print(f"Found {len(log_files)} potential log files. Checking each one...")
    
    incomplete_runs = []
    
    # Check each log file for the success marker
    for log_file in log_files:
        # Extract tech name, design name, and run number from log path
        tech_name, design_name, run_number = extract_run_info(log_file)
        
        # Check if the file contains the success marker
        with open(log_file, 'r', errors='ignore') as f:
            file_content = f.read()
            if success_string not in file_content:
                incomplete_runs.append((tech_name, design_name, run_number, log_file))
    
    return incomplete_runs

def find_nonzero_drv_runs(search_dir="logs", log_pattern="*route.log", drv_marker='[INFO DRT-0199]'):
    """
    Identifies runs with non-zero DRV violations by checking the last occurrence of 
    the DRV marker in log files.
    
    Args:
        search_dir: Directory to search for log files
        log_pattern: Pattern to match log files
        drv_marker: String that indicates a DRV violation count
    
    Returns:
        List of tuples containing (tech_name, design_name, run_number, log_path, drv_count)
    """
    print(f"Searching for non-zero DRV runs in '{search_dir}'...")
    print(f"Looking for log files matching '{log_pattern}'")
    print(f"DRV marker: '{drv_marker}'")
    
    # Find all log files matching the pattern
    log_files = glob.glob(os.path.join(search_dir, "**", log_pattern), recursive=True)
    
    if not log_files:
        print(f"No log files matching '{log_pattern}' found in '{search_dir}'.")
        return []
    
    print(f"Found {len(log_files)} potential log files. Checking each one...")
    
    nonzero_drv_runs = []
    
    # Regular expression to extract violation count - matches 'Number of violations = X.' pattern
    drv_pattern = re.compile(re.escape(drv_marker) + r'\s+Number of violations = (\d+)\.')
    
    # Check each log file for non-zero DRV
    for log_file in log_files:
        # Extract tech name, design name, and run number from log path
        tech_name, design_name, run_number = extract_run_info(log_file)
        
        try:
            # Find the last occurrence of the DRV marker
            with open(log_file, 'r', errors='ignore') as f:
                file_content = f.read()
                
                # Find all occurrences of the DRV marker
                matches = list(drv_pattern.finditer(file_content))
                
                # If we found matches, check the last one
                if matches:
                    last_match = matches[-1]
                    drv_count = int(last_match.group(1))
                    
                    # If the last DRV count is non-zero, record this run
                    if drv_count > 0:
                        nonzero_drv_runs.append((tech_name, design_name, run_number, log_file, drv_count))
        except Exception as e:
            print(f"Error processing file {log_file}: {str(e)}")
    
    return nonzero_drv_runs

def extract_run_info(log_file):
    """
    Extracts tech name, design name, and run number from a log file path.
    
    Args:
        log_file: Path to the log file
    
    Returns:
        Tuple of (tech_name, design_name, run_number)
    """
    try:
        # Extract information from path
        path_parts = os.path.normpath(log_file).split(os.sep)
        
        # Find the index of "run_" prefix
        run_index = -1
        for i, part in enumerate(path_parts):
            if part.startswith("run_"):
                run_index = i
                break
        
        if run_index > 1:  # We need at least tech and design
            # Check if we have the typical nangate45/design/base/run_X structure
            if path_parts[run_index-1] == "base" and run_index > 2:
                tech_name = path_parts[run_index-3]
                design_name = path_parts[run_index-2]
            else:  # Otherwise use the standard approach
                tech_name = path_parts[run_index-2]
                design_name = path_parts[run_index-1]
                
            # Extract run number from the directory name
            run_match = re.search(r'run_(\d+)', path_parts[run_index])
            run_number = int(run_match.group(1)) if run_match else -1
        else:
            # If we can't extract the information, use placeholders
            tech_name = "unknown"
            design_name = "unknown"
            # Try to extract just the run number if possible
            run_match = re.search(r'run_(\d+)', log_file)
            run_number = int(run_match.group(1)) if run_match else -1
            
        # If we couldn't determine tech or design name properly, check if we have a directory structure
        # that might contain tech/design information (e.g., technode/design)
        if tech_name == "unknown" or design_name == "unknown":
            # Look for common tech nodes or any directory that might be a tech node
            possible_tech_nodes = ["nangate45", "asap7", "sky130", "tsmc65lp"]
            for tech in possible_tech_nodes:
                if tech in path_parts:
                    tech_index = path_parts.index(tech)
                    tech_name = tech
                    if tech_index + 1 < len(path_parts) and not path_parts[tech_index + 1].startswith("run_"):
                        design_name = path_parts[tech_index + 1]
                    break
            
            # If still unknown, make an educated guess based on directory depth
            if tech_name == "unknown" and run_index > 1:
                # Try to infer tech and design based on directory structure
                # Look for directories that might represent tech and design
                for i in range(max(0, run_index-3), run_index):
                    if i >= 0 and i < len(path_parts):
                        if not path_parts[i].startswith("run_") and not path_parts[i] in ["logs", "base"]:
                            if tech_name == "unknown":
                                tech_name = path_parts[i]
                            elif design_name == "unknown":
                                design_name = path_parts[i]
    except Exception as e:
        print(f"Error extracting run info from {log_file}: {str(e)}")
        # Default values if extraction fails
        tech_name = "unknown"
        design_name = "unknown"
        run_number = -1
    
    return tech_name, design_name, run_number

def main():
    parser = argparse.ArgumentParser(description='Identify and report corrupted and incomplete runs')
    
    # General arguments
    parser.add_argument('--logs-dir', type=str, default='logs', 
                       help='Directory to search for log files')
    parser.add_argument('--log-pattern', type=str, default='5_2_route.log', 
                       help='Pattern to match log files')
    parser.add_argument('--output', type=str, default='validation_report.log', 
                       help='Path to save the validation report')
    
    # Incomplete runs arguments
    parser.add_argument('--success-string', type=str, 
                       default='[INFO DRT-0180] Post processing.', 
                       help='String that indicates a successful run completion')
    parser.add_argument('--incomplete-only', action='store_true', 
                       help='Only check for incomplete runs')
    
    # Non-zero DRV arguments
    parser.add_argument('--drv-marker', type=str, 
                       default='[INFO DRT-0199]', 
                       help='String that indicates DRV violation count')
    parser.add_argument('--nonzero-drv-only', action='store_true', 
                       help='Only check for non-zero DRV runs')
    
    args = parser.parse_args()
    
    # Determine which checks to run
    if not args.nonzero_drv_only and not args.incomplete_only:
        # By default, run both checks if neither flag is specified
        run_incomplete = True
        run_nonzero_drv = True
    else:
        # Otherwise, only run the specified check(s)
        run_incomplete = args.incomplete_only
        run_nonzero_drv = args.nonzero_drv_only
    
    # Results storage
    incomplete_runs = []
    nonzero_drv_runs = []
    
    # Find incomplete runs if requested
    if run_incomplete:
        incomplete_runs = find_incomplete_runs(
            search_dir=args.logs_dir,
            log_pattern=args.log_pattern,
            success_string=args.success_string
        )
    
    # Find non-zero DRV runs if requested
    if run_nonzero_drv:
        nonzero_drv_runs = find_nonzero_drv_runs(
            search_dir=args.logs_dir,
            log_pattern=args.log_pattern,
            drv_marker=args.drv_marker
        )
    
    # Generate the report
    report_lines = []
    report_lines.append("=" * 80)
    report_lines.append("RUN VALIDATION REPORT")
    report_lines.append("=" * 80)
    report_lines.append(f"Generated on: {os.path.basename(args.logs_dir)}")
    
    # Report incomplete runs
    if run_incomplete:
        report_lines.append(f"\nINCOMPLETE RUNS ({len(incomplete_runs)} found):")
        report_lines.append("-" * 50)
        
        if incomplete_runs:
            # Sort by tech, design, and run number
            incomplete_runs.sort()
            for tech, design, run_num, log_path in incomplete_runs:
                report_lines.append(f"Tech: {tech}, Design: {design}, Run: {run_num}")
                report_lines.append(f"   Log file: {log_path}")
                report_lines.append(f"   Issue: Incomplete run (missing success marker)")
                report_lines.append("")
        else:
            report_lines.append("No incomplete runs found.")
    
    # Report non-zero DRV runs
    if run_nonzero_drv:
        report_lines.append(f"\nNON-ZERO DRV RUNS ({len(nonzero_drv_runs)} found):")
        report_lines.append("-" * 50)
        
        if nonzero_drv_runs:
            # Sort by tech, design, and run number
            nonzero_drv_runs.sort(key=lambda x: (x[0], x[1], x[2]))
            for tech, design, run_num, log_path, drv_count in nonzero_drv_runs:
                report_lines.append(f"Tech: {tech}, Design: {design}, Run: {run_num}")
                report_lines.append(f"   Log file: {log_path}")
                report_lines.append(f"   Issue: Non-zero DRV in final iteration (violations: {drv_count})")
                report_lines.append("")
        else:
            report_lines.append("No runs with non-zero DRVs found.")
    
    # Write the report to a file
    try:
        with open(args.output, 'w') as f:
            f.write('\n'.join(report_lines))
        print(f"\nValidation report saved to {args.output}")
        
        # Also create CSV files for easier processing
        incomplete_csv = args.output.replace('.log', '_incomplete.csv')
        nonzero_csv = args.output.replace('.log', '_nonzero_drv.csv')
        rerun_script = args.output.replace('.log', '_rerun_commands.sh')
        
        # Create CSV for incomplete runs
        if run_incomplete and incomplete_runs:
            with open(incomplete_csv, 'w') as f:
                f.write('tech,design,run_number,log_file\n')
                for tech, design, run_num, log_path in incomplete_runs:
                    f.write(f'{tech},{design},{run_num},{log_path}\n')
            print(f"Incomplete runs CSV saved to {incomplete_csv}")
        
        # Create CSV for non-zero DRV runs
        if run_nonzero_drv and nonzero_drv_runs:
            with open(nonzero_csv, 'w') as f:
                f.write('tech,design,run_number,log_file,violations\n')
                for tech, design, run_num, log_path, drv_count in nonzero_drv_runs:
                    f.write(f'{tech},{design},{run_num},{log_path},{drv_count}\n')
            print(f"Non-zero DRV runs CSV saved to {nonzero_csv}")
            
        # Create rerun commands script
        with open(rerun_script, 'w') as f:
            f.write('#!/bin/bash\n\n')
            f.write('# Commands to rerun problematic designs\n\n')
            
            all_issues = []
            if run_incomplete and incomplete_runs:
                all_issues.extend([(tech, design, run_num, 'incomplete') 
                                 for tech, design, run_num, _ in incomplete_runs])
            if run_nonzero_drv and nonzero_drv_runs:
                all_issues.extend([(tech, design, run_num, f'nonzero_drv_{drv}') 
                                 for tech, design, run_num, _, drv in nonzero_drv_runs])
            
            # Sort by tech, design, run number
            all_issues.sort()
            
            for tech, design, run_num, issue_type in all_issues:
                # Skip runs with unknown tech or design
                if tech == "unknown" or design == "unknown" or run_num < 0:
                    continue
                
                # For nangate45 designs with base directory structure
                if tech == "nangate45":
                    f.write(f'# {issue_type}: {tech}/{design} run_{run_num}\n')
                    # Add cleanup commands for all three directories (logs, results, reports)
                    f.write(f'rm -rf flow/logs/{tech}/{design}/base/run_{run_num} flow/results/{tech}/{design}/base/run_{run_num} flow/reports/{tech}/{design}/base/run_{run_num}\n')
                    # For BP designs, add _top suffix to the design path in DESIGN_CONFIG
                    design_path = f"{design}_top" if design.startswith("bp_") else design
                    f.write(f'nohup ./dr_flow.sh --DESIGN_CONFIG=designs/{tech}/{design_path}/config.mk --flow --run={run_num} --mode=completely_random\n\n')
                # For other tech nodes
                elif tech not in ["logs", "unknown"]:
                    f.write(f'# {issue_type}: {tech}/{design} run_{run_num}\n')
                    # Add cleanup commands for all three directories (logs, results, reports)
                    f.write(f'rm -rf flow/logs/{tech}/{design}/base/run_{run_num} flow/results/{tech}/{design}/base/run_{run_num} flow/reports/{tech}/{design}/base/run_{run_num}\n')
                    # For BP designs, add _top suffix to the design path in DESIGN_CONFIG
                    design_path = f"{design}_top" if design.startswith("bp_") else design
                    f.write(f'nohup ./dr_flow.sh --DESIGN_CONFIG=designs/{tech}/{design_path}/config.mk --flow --run={run_num} --mode=completely_random\n\n')
            
        print(f"Rerun commands script saved to {rerun_script}")
        print(f"Make it executable with: chmod +x {rerun_script}")
    except Exception as e:
        print(f"Error saving reports: {str(e)}")
        # Print the report to console as a fallback
        print('\n'.join(report_lines))
    
    # Print summary to console
    print("\nSUMMARY:")
    if run_incomplete:
        print(f"- Incomplete runs: {len(incomplete_runs)}")
    if run_nonzero_drv:
        print(f"- Non-zero DRV runs: {len(nonzero_drv_runs)}")
    
    total_issues = len(incomplete_runs) + len(nonzero_drv_runs)
    print(f"Total issues found: {total_issues}")
    
    return 0

if __name__ == "__main__":
    main()
