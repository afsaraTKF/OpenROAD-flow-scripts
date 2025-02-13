import os
import re
import shutil

print("Starting the script...")

# store all box coordinates from log file 
def process_worker_lines(worker_lines):
    worker_entries = []
    for line in worker_lines:
        match = re.match(r'start DR worker \(BOX\) \(\s*(.*?)\s+(.*?)\s*\) \(\s*(.*?)\s+(.*?)\s*\)', line)
        if match:
            x1, y1, x2, y2 = match.groups()
            try:
                x1 = float(x1)
                y1 = float(y1)
                x2 = float(x2)
                y2 = float(y2)
                worker_entries.append(((x1, y1, x2, y2), line))
            except ValueError:
                # if conversion to float fails, keep the original line
                worker_entries.append(((float('inf'), float('inf'), float('inf'), float('inf')), line))
        else:
            worker_entries.append(((float('inf'), float('inf'), float('inf'), float('inf')), line))
    # sort entries based on coordinates
    worker_entries.sort(key=lambda x: x[0])
    return [entry[1] for entry in worker_entries]

# arrange the boxes by coordinates
def arrange_boxes_in_log(input_log_path, output_log_path):
    iteration_start_regex = re.compile(r'\[INFO DRT-0195\] Start \d+(?:st|nd|rd|th) optimization iteration.*')
    worker_line_regex = re.compile(r'start DR worker \(BOX\) \(\s*(.*?)\s+(.*?)\s*\) \(\s*(.*?)\s+(.*?)\s*\)')

    partition = False  # if top level route log only
    with open(input_log_path, 'r') as infile, open(output_log_path, 'w') as outfile:
        in_iteration = False
        collecting_workers = False
        worker_lines = []
        for line in infile:
            # check if line is an iteration start line
            if iteration_start_regex.match(line):
                # process worker lines from previous iteration
                if worker_lines:
                    sorted_worker_lines = process_worker_lines(worker_lines)
                    outfile.writelines(sorted_worker_lines)
                    worker_lines = []
                # write the iteration start line
                outfile.write(line)
                in_iteration = True
                collecting_workers = False
            elif in_iteration and worker_line_regex.match(line):
                # collect worker lines
                worker_lines.append(line)
                collecting_workers = True
                partition = True  # found box coordinates
            else:
                if collecting_workers and worker_lines:
                    # process collected worker lines
                    sorted_worker_lines = process_worker_lines(worker_lines)
                    outfile.writelines(sorted_worker_lines)
                    worker_lines = []
                    collecting_workers = False
                # write the current line
                outfile.write(line)
        # check if any worker lines remain
        if worker_lines:
            sorted_worker_lines = process_worker_lines(worker_lines)
            outfile.writelines(sorted_worker_lines)

    return partition

# collect and process/sort logs
def process_all_logs():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    # move one directory up to access "logs" folder
    root_dir = os.path.join(script_dir, "..", "logs")
    output_dir = os.path.join(script_dir, "..", "combined_routelogs")

    print(f"Root directory: {root_dir}")
    print(f"Output directory: {output_dir}")

    os.makedirs(output_dir, exist_ok=True)

    log_file_paths = []
    for dirpath, _, filenames in os.walk(root_dir):
        for file in filenames:
            if file.strip().lower() in ["5_2_route.log", "5_2_route.txt"]:
                full_path = os.path.join(dirpath, file)
                log_file_paths.append(full_path)

    if not log_file_paths:
        print("No log files found.")
        return

    for log_file in log_file_paths:
        relative_path = os.path.relpath(log_file, root_dir)
        unique_name = "_".join(relative_path.split(os.sep))
        destination_path = os.path.join(output_dir, unique_name)

        try:
            with open(log_file, 'r', encoding='utf-8', errors='ignore') as src, open(destination_path, 'w', encoding='utf-8') as dest:
                content = src.read()
                if not content.strip():
                    print(f"Warning: Empty or unreadable source file: {log_file}")
                else:
                    print(f"Read content from {log_file} (first 100 chars): {content[:100]}")
                dest.write(content)
            print(f"Copied: {log_file} -> {destination_path}")
        except Exception as e:
            print(f"Error reading or writing file {log_file}: {e}")

if __name__ == "__main__":
    process_all_logs()
    print("Script completed.")
