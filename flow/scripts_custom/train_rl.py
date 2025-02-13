from stable_baselines3 import PPO
from stable_baselines3.common.callbacks import CheckpointCallback, EvalCallback, BaseCallback
from stable_baselines3.common.monitor import Monitor
from stable_baselines3.common.torch_layers import BaseFeaturesExtractor
from rl_env import RoutingEnv
import numpy as np
import pandas as pd
import pickle
import os
import time
import matplotlib.pyplot as plt
import seaborn as sns
from pathlib import Path
import re
import torch
import torch.nn as nn
import gymnasium as gym

# Generate dummy data to train RL agent

def generate_dummy_data(num_runs=10, num_iterations=20, num_boxes=5):
    """Generate dummy training data if real data is not available"""
    print("Generating dummy training data...")
    data = []
    
    for run_id in range(1, num_runs + 1):
        design_id = f"dummy_design_{run_id}"
        pin_count = np.random.randint(100, 200)
        net_count = np.random.randint(50, 100)
        initial_drv = np.random.randint(80, 150)
        
        # Generate full sequence for this design
        for iteration in range(num_iterations):
            # DRV count decreases with some randomness
            drv_reduction = np.random.uniform(0.1, 0.3)
            drv = int(initial_drv * (1 - drv_reduction * iteration))
            drv = max(0, drv)
            
            wire_length = np.random.randint(1500, 2000) - (iteration * np.random.randint(50, 100))
            wire_length = max(500, wire_length)  # Ensure minimum wire length
            
            # Weights change slightly between iterations
            weights = np.random.uniform(0.8, 1.2, size=4)
            drvs_per_box = np.random.multinomial(drv, np.ones(num_boxes)/num_boxes)
            
            # Create box data for this iteration
            for box in range(num_boxes):
                base_x = box * 10
                base_y = box * 10
                offset_x = np.random.uniform(-0.5, 0.5) if iteration > 0 else 0
                offset_y = np.random.uniform(-0.5, 0.5) if iteration > 0 else 0
                
                box_coords = (
                    base_x + offset_x,
                    base_y + offset_y,
                    base_x + 10 + offset_x,
                    base_y + 10 + offset_y
                )
                
                data.append({
                    "uniqueID": run_id,
                    "designID": design_id,
                    "iteration": iteration,
                    "pin_count": pin_count,
                    "net_count": net_count,
                    "drv": drv,
                    "box_drv": drvs_per_box[box],
                    "wireLength": wire_length,
                    "drc_weight": weights[0],
                    "marker_weight": weights[1],
                    "fixed_weight": weights[2],
                    "decay_weight": weights[3],
                    "box_index": box,
                    "box_coords": box_coords
                })
    
    df = pd.DataFrame(data)
    
    # Save training data
    df.to_csv("parsed_log_data.csv", index=False)
    
    # Create and save box violations data
    box_violations = {}
    for uniqueID in df['uniqueID'].unique():
        design_data = df[df['uniqueID'] == uniqueID]
        box_violations[uniqueID] = {}
        
        for box in range(num_boxes):
            box_data = design_data[design_data['box_index'] == box]
            box_violations[uniqueID][box] = box_data['box_drv'].tolist()
    
    with open("box_violations.pkl", "wb") as f:
        pickle.dump(box_violations, f)
    
    print("Data generation complete!")
    return df, box_violations

def test_environment(env):
    """Test the RL environment with random actions"""
    print("\nTesting Environment:")
    print("-" * 50)
    
    obs, _ = env.reset()
    print(f"\nInitial Observation:")
    print(f"Values: {obs}")
    print(f"Features: [iteration, pin_count, net_count, drv, wireLength, box_mean, box_var]")
    
    print("\nTesting Steps:")
    for i in range(3):
        action = env.action_space.sample()
        obs, reward, terminated, truncated, info = env.step(action)
        
        print(f"\nStep {i+1}:")
        print(f"Action: {action}")
        print(f"Observation values: {obs}")
        print(f"Reward: {reward}")
        print(f"Terminated: {terminated}")
        print(f"Truncated: {truncated}")
        print(f"Info: {info}")

class CustomCombinedExtractor(BaseFeaturesExtractor):
    """
    Combined features extractor for Dict observation spaces.
    Builds a feature extractor for each key of the dict.
    """
    def __init__(self, observation_space: gym.spaces.Dict):
        # Save observation space
        super().__init__(observation_space, features_dim=64)  # Adjust features_dim as needed
        
        extractors = {}
        
        # Process chip features (5D vector)
        chip_features_dim = observation_space.spaces["chip_features"].shape[0]
        extractors["chip_features"] = nn.Sequential(
            nn.Linear(chip_features_dim, 32),
            nn.ReLU(),
            nn.Linear(32, 32),
            nn.ReLU(),
        )
        
        # Process box stats (2D vector)
        box_stats_dim = observation_space.spaces["box_stats"].shape[0]
        extractors["box_stats"] = nn.Sequential(
            nn.Linear(box_stats_dim, 16),
            nn.ReLU(),
            nn.Linear(16, 16),
            nn.ReLU(),
        )
        
        self.extractors = nn.ModuleDict(extractors)
        
        # Update the features dim
        self._features_dim = 48  # 32 + 16

    def forward(self, observations) -> torch.Tensor:
        # Process each feature type
        encoded_tensor_list = []
        
        # Extract and process chip features
        chip_features = torch.as_tensor(observations["chip_features"]).float()
        encoded_tensor_list.append(self.extractors["chip_features"](chip_features))
        
        # Extract and process box stats
        box_stats = torch.as_tensor(observations["box_stats"]).float()
        encoded_tensor_list.append(self.extractors["box_stats"](box_stats))
        
        # Concatenate all features
        return torch.cat(encoded_tensor_list, dim=1)

def load_all_runs_data():
    """Load data from all runs (11-15) and combine them"""
    # Load CSV data
    csv_path = "Research/scripts_custom/output/iterations_summary.csv"
    csv_data = pd.read_csv(csv_path)
    print(f"Loaded CSV data with uniqueIDs: {csv_data['uniqueID'].unique()}")
    print(f"CSV columns: {csv_data.columns.tolist()}")
    
    # Load box violations data for each run
    all_box_violations = {}
    base_path = "Research/scripts_custom/output"
    
    for run_id in csv_data['uniqueID'].unique():
        violations_file = f"{base_path}/{run_id}/box_violations_{run_id}.txt"
        
        if not os.path.exists(violations_file):
            print(f"Warning: {violations_file} not found")
            continue
            
        box_data = {}
        current_iteration = None
        box_count = 0
        
        with open(violations_file, 'r') as f:
            lines = f.readlines()
            
        for line in lines:
            if "Iteration" in line:
                match = re.search(r'Iteration (\d+):', line)
                if match:
                    current_iteration = int(match.group(1))
            elif "Box ID:" in line:
                match = re.search(r'Box ID: .*?_iter(\d+)_x([\d.]+)_y([\d.]+)', line)
                if match:
                    box_count += 1
            elif "DRV Count:" in line:
                if current_iteration is not None:
                    match = re.search(r'DRV Count: (\d+)', line)
                    if match:
                        drv_count = int(match.group(1))
                        box_idx = box_count - 1
                        if box_idx not in box_data:
                            box_data[box_idx] = []
                        while len(box_data[box_idx]) <= current_iteration:
                            box_data[box_idx].append(0)
                        box_data[box_idx][current_iteration] = drv_count
        
        print(f"Processed {run_id}: {box_count} boxes")
        all_box_violations[run_id] = box_data
    
    print(f"Loaded data for {len(all_box_violations)} runs")
    print(f"Available runs: {list(all_box_violations.keys())}")
    
    # Print box counts for verification
    for run_id, run_data in all_box_violations.items():
        num_boxes = len(run_data)
        print(f"{run_id}: {num_boxes} boxes")
    
    return csv_data, all_box_violations

class BoxAwareCallback(BaseCallback):
    def __init__(self, verbose=0):
        super().__init__(verbose)
        self.episode_violations = []
        
    def _on_step(self) -> bool:
        if "terminal_observation" in self.locals['infos'][0]:
            term_obs = self.locals['infos'][0]['terminal_observation']
            if isinstance(term_obs, dict) and 'violation_history' in term_obs:
                violations = term_obs['violation_history']
                if len(violations) > 0:
                    total_violations = np.sum(violations[-1])  # Get the last iteration's violations
                    self.episode_violations.append(total_violations)
                
                if 'neighbor_violation_ratios' in term_obs:
                    neighbor_ratios = term_obs['neighbor_violation_ratios']
                    self.logger.record('metrics/neighbor_ratio_var', np.var(neighbor_ratios))
        return True

class TrainingVisualizer(BaseCallback):
    def __init__(self, verbose=0):
        super().__init__(verbose)
        self.episode_rewards = []
        self.episode_violations = []
        self.violation_trends = []
        self.spatial_metrics = []
        # Add episode tracking
        self.current_episode_reward = 0
        self.current_episode_violations = []
        
    def _on_step(self) -> bool:
        # Accumulate reward for this step
        self.current_episode_reward += self.locals.get("rewards")[0]
        
        # Get current violations if available
        info = self.locals.get("infos")[0]
        if isinstance(info, dict) and "terminal_observation" in info:
            term_obs = info["terminal_observation"]
            if isinstance(term_obs, dict):
                if 'violation_history' in term_obs:
                    violations = term_obs['violation_history']
                    if len(violations) > 0:
                        self.current_episode_violations = violations
        
        # When episode ends
        if self.locals.get("dones")[0]:
            # Save accumulated reward
            self.episode_rewards.append(self.current_episode_reward)
            
            # Process violations for this episode
            if len(self.current_episode_violations) > 0:
                final_violations = np.sum(self.current_episode_violations[-1])
                self.episode_violations.append(final_violations)
                
                # Calculate violation trend (difference between start and end)
                if len(self.current_episode_violations) > 1:
                    start_violations = np.sum(self.current_episode_violations[0])
                    end_violations = np.sum(self.current_episode_violations[-1])
                    trend = (start_violations - end_violations) / start_violations if start_violations > 0 else 0
                    self.violation_trends.append(trend)
                
                # Calculate spatial consistency
                if len(self.current_episode_violations[-1]) > 1:
                    final_violations = self.current_episode_violations[-1]
                    ratios = []
                    for i in range(len(final_violations) - 1):
                        if final_violations[i+1] > 0:
                            ratios.append(final_violations[i] / final_violations[i+1])
                    if ratios:
                        self.spatial_metrics.append(np.var(ratios))
            
            # Reset episode accumulators
            self.current_episode_reward = 0
            self.current_episode_violations = []
            
            # Plot every 100 episodes
            if len(self.episode_rewards) % 100 == 0:
                self.plot_metrics()
        
        return True
    
    def plot_metrics(self):
        plt.figure(figsize=(15, 10))
        
        # Plot episode rewards
        plt.subplot(2, 2, 1)
        if len(self.episode_rewards) > 0:
            plt.plot(range(len(self.episode_rewards)), self.episode_rewards, 'b-', label='Reward')
            plt.title('Episode Rewards')
            plt.xlabel('Episode')
            plt.ylabel('Total Reward')
            plt.grid(True)
            min_reward = min(self.episode_rewards)
            max_reward = max(self.episode_rewards)
            plt.ylim(min_reward - abs(min_reward * 0.1), max_reward + abs(max_reward * 0.1))
        
        # Plot total violations
        plt.subplot(2, 2, 2)
        if len(self.episode_violations) > 0:
            plt.plot(range(len(self.episode_violations)), self.episode_violations, 'r-', label='Violations')
            plt.title('Final Violations per Episode')
            plt.xlabel('Episode')
            plt.ylabel('Number of Violations')
            plt.grid(True)
            plt.ylim(0, max(self.episode_violations) * 1.1)
        
        # Plot violation trends
        plt.subplot(2, 2, 3)
        if len(self.violation_trends) > 0:
            plt.plot(range(len(self.violation_trends)), self.violation_trends, 'g-', label='Trend')
            plt.title('Violation Reduction Trend')
            plt.xlabel('Episode')
            plt.ylabel('Reduction Rate')
            plt.grid(True)
            min_trend = min(self.violation_trends)
            max_trend = max(self.violation_trends)
            plt.ylim(min_trend - abs(min_trend * 0.1), max_trend + abs(max_trend * 0.1))
        
        # Plot spatial consistency
        plt.subplot(2, 2, 4)
        if len(self.spatial_metrics) > 0:
            plt.plot(range(len(self.spatial_metrics)), self.spatial_metrics, 'm-', label='Variance')
            plt.title('Spatial Consistency')
            plt.xlabel('Episode')
            plt.ylabel('Neighbor Variance')
            plt.grid(True)
            plt.ylim(0, max(self.spatial_metrics) * 1.1)
        
        plt.tight_layout()
        plt.savefig(f'training_progress_{len(self.episode_rewards)}.png')
        plt.close()

def train_agent(total_timesteps=500000):
    """Train RL agent with visualization"""
    device = "cuda" if torch.cuda.is_available() else "cpu"
    print(f"Using device: {device}")
    
    # Load data
    csv_data, box_violations = load_all_runs_data()
    
    # Create environment
    env = RoutingEnv(csv_data=csv_data, box_violations=box_violations)
    
    # Test environment before training
    test_environment(env)
    
    # Wrap environment
    env = Monitor(env, "./routing_logs/")
    
    # Create evaluation environment
    eval_env = RoutingEnv(csv_data=csv_data, box_violations=box_violations)
    eval_env = Monitor(eval_env, "./eval_logs/")
    
    # Initialize PPO agent
    model = PPO(
        "MlpPolicy",
        env,
        verbose=1,
        learning_rate=3e-4,
        n_steps=1024,
        batch_size=128,
        n_epochs=10,
        gamma=0.99,
        gae_lambda=0.95,
        clip_range=0.2,
        clip_range_vf=0.2,
        normalize_advantage=True,
        ent_coef=0.01,
        max_grad_norm=0.5,
        device=device,
        tensorboard_log="./routing_tensorboard/",
        policy_kwargs=dict(
            net_arch=dict(
                pi=[64, 64],
                vf=[64, 64]
            )
        )
    )
    
    # Setup callbacks
    checkpoint_callback = CheckpointCallback(
        save_freq=10000,
        save_path="./routing_checkpoints/",
        name_prefix="routing_model"
    )
    
    eval_callback = EvalCallback(
        eval_env,
        best_model_save_path="./best_model/",
        log_path="./eval_logs/",
        eval_freq=5000,
        n_eval_episodes=5,
        deterministic=True
    )
    
    visualizer = TrainingVisualizer()
    
    # Start training
    print("\nStarting training...")
    model.learn(
        total_timesteps=total_timesteps,
        callback=[checkpoint_callback, eval_callback, visualizer],
        progress_bar=True
    )
    
    # After training, analyze the best model's performance
    print("\nAnalyzing best model performance...")
    best_model_path = "./best_model/best_model.zip"
    if os.path.exists(best_model_path):
        best_model = PPO.load(best_model_path)
        
        # Test the model on each run
        results = []
        for run_id in env.runs:
            # Reset with specific run
            env.current_run = run_id
            obs, _ = env.reset()
            
            episode_weights = []
            episode_violations = []
            done = False
            
            while not done:
                # Get action (weights) from model
                action, _ = best_model.predict(obs, deterministic=True)
                episode_weights.append(action)
                
                # Step environment
                obs, reward, done, _, info = env.step(action)
                
                if 'terminal_observation' in info:
                    final_violations = info['terminal_observation']['violation_history'][-1]
                    episode_violations = info['terminal_observation']['violation_history']
            
            # Store results for this run
            results.append({
                'run_id': run_id,
                'weights': episode_weights,
                'violations': episode_violations,
                'final_violations': np.sum(final_violations),
                'num_iterations': len(episode_weights)
            })
        
        # Save results
        print("\nBest model performance summary:")
        print("-" * 50)
        for result in results:
            print(f"\nRun {result['run_id']}:")
            print(f"Final violations: {result['final_violations']}")
            print(f"Number of iterations: {result['num_iterations']}")
            print("\nBest weights sequence:")
            for i, weights in enumerate(result['weights']):
                print(f"Iteration {i}: {weights}")
        
        # Save detailed results to file
        with open('best_model_analysis.txt', 'w') as f:
            f.write("Best Model Analysis\n")
            f.write("=" * 50 + "\n\n")
            for result in results:
                f.write(f"Run {result['run_id']}\n")
                f.write("-" * 30 + "\n")
                f.write(f"Final violations: {result['final_violations']}\n")
                f.write(f"Number of iterations: {result['num_iterations']}\n")
                f.write("\nWeights sequence:\n")
                for i, weights in enumerate(result['weights']):
                    f.write(f"Iteration {i}: {weights}\n")
                f.write("\nViolation progression:\n")
                for i, violations in enumerate(result['violations']):
                    f.write(f"Iteration {i}: Total={np.sum(violations)}, Per-box={violations}\n")
                f.write("\n" + "=" * 50 + "\n\n")
    
    return model, visualizer, results if os.path.exists(best_model_path) else None

def use_model_for_routing(model_path, initial_state=None):
    """
    Helper function to demonstrate how to use the trained model with detailed router.
    
    Args:
        model_path: Path to the saved model
        initial_state: Optional initial state from 0th iteration.
                      If None, will explain what's needed.
    """
    if not os.path.exists(model_path):
        print("Error: Model file not found!")
        return
        
    # Load the trained model
    model = PPO.load(model_path)
    
    if initial_state is None:
        print("\nTo use this model, you need to:")
        print("1. Run 0th iteration with initial weights (e.g. [1.0, 1.0, 1.0, 1.0])")
        print("2. Collect the following state information:")
        print("   - iteration: 0")
        print("   - pin_count: from your design")
        print("   - net_count: from your design")
        print("   - drv: total DRV count from 0th iteration")
        print("   - wireLength: total wire length from 0th iteration")
        print("   - box_mean: mean of violations across boxes")
        print("   - box_var: variance of violations across boxes")
        print("\nThen call this function with the initial state array.")
        return
    
    # Convert state to numpy array if it isn't already
    state = np.array(initial_state, dtype=np.float32)
    
    # Get action (weights) from model
    action, _ = model.predict(state, deterministic=True)
    
    print("\nFor the given state:")
    print(f"Iteration: {state[0]}")
    print(f"Pin count: {state[1]}")
    print(f"Net count: {state[2]}")
    print(f"DRV count: {state[3]}")
    print(f"Wire length: {state[4]}")
    print(f"Box violation mean: {state[5]}")
    print(f"Box violation variance: {state[6]}")
    
    print("\nRecommended weights for next iteration:")
    print(f"DRC weight: {action[0]:.4f}")
    print(f"Marker weight: {action[1]:.4f}")
    print(f"Fixed weight: {action[2]:.4f}")
    print(f"Decay weight: {action[3]:.4f}")
    
    return action

if __name__ == "__main__":
    model, visualizer, results = train_agent(total_timesteps=500000)
    
    if results:
        print("\nTraining complete! Best weights have been saved to 'best_model_analysis.txt'")
        print("You can also find checkpoint models in './routing_checkpoints/'")
        print("And the best performing model in './best_model/best_model.zip'")
        
        # Example of how to use the model
        print("\nExample usage of the trained model:")
        print("-" * 50)
        use_model_for_routing("./best_model/best_model.zip")
    else:
        print("\nTraining complete, but no best model was saved. Check the training logs for issues.")