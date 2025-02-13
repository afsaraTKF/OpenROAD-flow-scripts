import numpy as np
from stable_baselines3 import PPO
import os
import torch
import zipfile

def use_model_for_routing(model_path, initial_state):
    print(f"Checking if model exists at: {model_path}")
    print(f"Model file exists: {os.path.exists(model_path)}")
    print(f"Model file size: {os.path.getsize(model_path)} bytes")
    
    try:
        # Extract the model data
        with zipfile.ZipFile(model_path, 'r') as zip_ref:
            print("ZIP contents:", zip_ref.namelist())
        
        # Load the trained model with device specification
        device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
        print(f"Using device: {device}")
        model = PPO.load(model_path, device=device)
        
        # Convert state to numpy array and reshape for model input
        state = np.array(initial_state).reshape(1, -1)
        print(f"Input state shape: {state.shape}")
        print(f"Input state: {state}")
        
        # Get the model's action (weights)
        action, _ = model.predict(state)
        return action
    except Exception as e:
        print(f"Error loading model: {str(e)}")
        raise

# Calculate box-level statistics from run_32's iteration 2 data
box_drvs = [0] * 215  # 215 boxes without violations
box_drvs.extend([1] * 109)  # 109 boxes with violations
mean_box_drvs = np.mean(box_drvs)
var_box_drvs = np.var(box_drvs)

# Get run_32's iteration 2 data
initial_state = [
    2,                # iteration 2
    388,             # pin_count
    17172,           # net_count
    1072,            # drv (violations)
    310830,          # wireLength
    mean_box_drvs,   # mean violations per box
    var_box_drvs     # variance of box violations
]

print("\nInitial state:")
for i, (name, value) in enumerate(zip(
    ["iteration", "pin_count", "net_count", "drv", "wireLength", "mean_box_drvs", "var_box_drvs"],
    initial_state
)):
    print(f"{name}: {value}")

# Get weights for iteration 2
model_path = "/home/afsara/OpenROAD-flow-scripts/flow/scripts_custom/best_model/best_model.zip"
next_weights = use_model_for_routing(model_path, initial_state)
print("\nWeights for iteration 2:", next_weights)
