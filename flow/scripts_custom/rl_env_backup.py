import gym
import numpy as np
import pandas as pd
from gym import spaces

class RoutingEnv(gym.Env):
    """
    This environment uses chip-level information (from the CSV file)
    together with per-box DR violation (drv) history (from the parsed violation files)
    to simulate how applying a given set of weights changes the violation counts.
    Actions are four weights [drc_weight, marker_weight, fixed_weight, decay_weight]
    that are held constant for the whole iteration.
    Reward is inversely proportional to the total violation (plus a penalty for neighbor inconsistency).
    """
    def __init__(self, csv_data, box_violations):
        super(RoutingEnv, self).__init__()
        self.csv_data = csv_data
        self.box_violations = box_violations

        # Get list of available runs, e.g. ['run_11','run_12',…,'run_15']
        self.runs = csv_data['uniqueID'].unique().tolist()
        self.current_run = None
        self.run_data = None
        self.current_iteration = 0

        # actions are continuous weights (for now in a simple range)
        self.action_space = spaces.Box(low=0.5, high=2.0, shape=(4,), dtype=np.float32)

        # For observations we combine chip-level features and simple box summary stats.
        # Here we include: iteration, pin_count, net_count, total_drv, wireLength
        chip_feature_low = np.array([0, 0, 0, 0, 0], dtype=np.float32)
        chip_feature_high = np.array([np.inf, np.inf, np.inf, np.inf, np.inf], dtype=np.float32)
        # Box summary: mean violation and variance across boxes.
        box_feature_low = np.array([0, 0], dtype=np.float32)
        box_feature_high = np.array([np.inf, np.inf], dtype=np.float32)
        
        self.observation_space = spaces.Dict({
            'chip_features': spaces.Box(low=chip_feature_low, high=chip_feature_high, dtype=np.float32),
            'box_stats': spaces.Box(low=box_feature_low, high=box_feature_high, dtype=np.float32)
        })

        # For storing the violation evolution over the episode (for visualization etc.)
        self.violation_history = []

    def reset(self):
        # On reset, choose a random run from the available runs.
        self.current_run = np.random.choice(self.runs)
        # Filter chip-level data for that run (each row is one iteration)
        self.run_data = self.csv_data[self.csv_data['uniqueID'] == self.current_run].reset_index(drop=True)
        self.current_iteration = 0

        # Build initial observation from iteration 0.
        row = self.run_data.iloc[self.current_iteration]
        chip_features = np.array([
            row['iteration'],
            row['pin_count'],
            row['net_count'],
            row['total_drv'],
            row['wireLength']
        ], dtype=np.float32)

        # Get violation data for this run and iteration from the box_violations dictionary.
        # Assume box_violations[run_id] is a dict with keys as box indices (ints) and each value is a list.
        box_data = self.box_violations[self.current_run]
        violations = []
        for key, drv_list in box_data.items():
            if isinstance(key, int):  # Skip any non-box key (like "coords")
                # If we don’t have data for the current iteration, assume 0.
                if self.current_iteration < len(drv_list):
                    violations.append(drv_list[self.current_iteration])
                else:
                    violations.append(0)
        violations = np.array(violations) if violations else np.array([0])
        # Save for later analysis.
        self.violation_history = [violations]

        # Box-level stats: mean and variance.
        box_stats = np.array([np.mean(violations), np.var(violations)], dtype=np.float32)
        obs = {'chip_features': chip_features, 'box_stats': box_stats}

        # Return observation and (an empty) info dictionary per Gymnasium API.
        return obs, {}

    def step(self, action):
        # In our offline simulation, the chosen weights directly affect how much the current
        # violation counts are “improved” in the next iteration.
        # For our simple simulation, we use a basic model:
        #   new_drv = current_drv * (1 - improvement_factor)
        # where improvement_factor is proportional to the mean of the chosen weights.
        improvement = np.mean(action) / 20.0  # adjust denominator to tune how strong the effect is

        # Get current per-box violation counts from stored offline box data.
        box_data = self.box_violations[self.current_run]
        current_violations = []
        for key, drv_list in box_data.items():
            if isinstance(key, int):
                if self.current_iteration < len(drv_list):
                    current_violations.append(drv_list[self.current_iteration])
                else:
                    current_violations.append(0)
        current_violations = np.array(current_violations)
        
        # Simulate reduction of violations based on the weights.
        simulated_violations = current_violations * (1 - improvement)
        # Ensure we do not go below zero.
        simulated_violations = np.clip(simulated_violations, 0, None)
        total_violation = np.sum(simulated_violations)

        # Additionally, we can compute a basic neighbor metric: for sorted boxes (by index),
        # compute the ratio of each box’s violation to the next (adding one to avoid zero division).
        neighbor_ratios = []
        sorted_violations = simulated_violations
        for i in range(len(sorted_violations) - 1):
            ratio = sorted_violations[i] / (sorted_violations[i+1] + 1)
            neighbor_ratios.append(ratio)
        neighbor_ratios = np.array(neighbor_ratios) if neighbor_ratios else np.array([0.0])
        
        # Define reward such that lower total violations and lower neighbor variance are better.
        reward = -total_violation
        penalty = np.var(neighbor_ratios)
        reward -= penalty

        # Log info to help debug (you should see nonzero values in your terminal).
        print(f"Run {self.current_run} Iteration {self.current_iteration}:")
        print(f"   Action weights: {action}, improvement factor: {improvement:.4f}")
        print(f"   Current violations: {current_violations}, simulated: {simulated_violations}")
        print(f"   Total violations: {total_violation:.2f}, neighbor variance: {np.var(neighbor_ratios):.4f}")
        print(f"   Reward: {reward:.4f}")

        # Save the simulated violations in the history.
        self.violation_history.append(simulated_violations)

        # Update iteration counter.
        self.current_iteration += 1
        done = self.current_iteration >= len(self.run_data)

        # Prepare observation for next iteration.
        if not done:
            row = self.run_data.iloc[self.current_iteration]
            chip_features = np.array([
                row['iteration'],
                row['pin_count'],
                row['net_count'],
                row['total_drv'],
                row['wireLength']
            ], dtype=np.float32)

            # Get the next iteration’s offline box data and simulate the effect of our weights.
            next_violations = []
            for key, drv_list in box_data.items():
                if isinstance(key, int):
                    if self.current_iteration < len(drv_list):
                        base_drv = drv_list[self.current_iteration]
                    else:
                        base_drv = 0
                    next_violations.append(base_drv * (1 - improvement))
            next_violations = np.array(next_violations) if next_violations else np.array([0])
            box_stats = np.array([np.mean(next_violations), np.var(next_violations)], dtype=np.float32)
            obs = {'chip_features': chip_features, 'box_stats': box_stats}
        else:
            # When done, return a zero observation.
            obs = {'chip_features': np.zeros(5, dtype=np.float32),
                   'box_stats': np.zeros(2, dtype=np.float32)}

        # In the new Gymnasium API, info can include terminal_observation if done.
        info = {}
        if done:
            info['terminal_observation'] = {
                'violation_history': np.array(self.violation_history),
                'neighbor_violation_ratios': neighbor_ratios,
                'box_violation_trend': simulated_violations
            }
        return obs, reward, done, False, info

    def render(self, mode="human"):
        print(f"Run: {self.current_run} Iteration: {self.current_iteration}")
        if self.violation_history:
            print("Latest violation history:", self.violation_history[-1])