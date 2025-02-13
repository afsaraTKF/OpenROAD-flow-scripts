from stable_baselines3 import PPO
from rl_env import RoutingEnv
import numpy as np
import time
import os
from train_rl import generate_dummy_data

def evaluate_model(model_path="final_routing_agent.zip", num_episodes=5, use_dummy_data=True):
    """Evaluate a trained model's performance"""
    print("\nEvaluating model performance...")
    total_start_time = time.time()
    
    # Generate dummy data if needed
    if use_dummy_data or not os.path.exists("parsed_log_data.csv"):
        print("Generating dummy data for evaluation...")
        data_start_time = time.time()
        generate_dummy_data()
        data_gen_time = time.time() - data_start_time
        print(f"Data generation time: {data_gen_time:.2f} seconds")
    
    try:
        # Load model
        load_start_time = time.time()
        model = PPO.load(model_path)
        model_load_time = time.time() - load_start_time
        print(f"Model load time: {model_load_time:.2f} seconds")
        
        # Create evaluation environment
        env = RoutingEnv("parsed_log_data.csv", "box_violations.pkl")
        
        # Track metrics
        total_rewards = []
        drv_reductions = []
        wire_length_changes = []
        episode_lengths = []
        total_inference_time = 0  # Time spent on model.predict
        total_step_time = 0      # Time spent on env.step
        total_episode_time = 0    # Total episode time including everything
        
        for episode in range(num_episodes):
            print(f"\nEpisode {episode + 1}/{num_episodes}")
            obs, _ = env.reset()
            episode_reward = 0
            initial_drv = None
            initial_wire_length = None
            steps = 0
            episode_start_time = time.time()
            episode_inference_time = 0
            episode_step_time = 0
            
            while True:
                # Get initial metrics
                if initial_drv is None:
                    current_data = env.sequence_data[env.current_uniqueID]
                    initial_data = current_data[current_data['iteration'] == 0].iloc[0]
                    initial_drv = initial_data['total_drv']
                    initial_wire_length = initial_data['wireLength']
                
                # Get action from model
                inference_start = time.time()
                action, _ = model.predict(obs, deterministic=True)
                episode_inference_time += time.time() - inference_start
                
                # Take step
                step_start = time.time()
                obs, reward, terminated, truncated, _ = env.step(action)
                episode_step_time += time.time() - step_start
                
                episode_reward += reward
                steps += 1
                
                if terminated or truncated:
                    # Get final metrics
                    current_data = env.sequence_data[env.current_uniqueID]
                    final_data = current_data[current_data['iteration'] == env.current_iteration].iloc[0]
                    final_drv = final_data['total_drv']
                    final_wire_length = final_data['wireLength']
                    
                    # Calculate improvements
                    drv_reduction = (initial_drv - final_drv) / initial_drv * 100 if initial_drv > 0 else 0
                    wire_length_change = (final_wire_length - initial_wire_length) / initial_wire_length * 100
                    
                    # Store metrics
                    total_rewards.append(episode_reward)
                    drv_reductions.append(drv_reduction)
                    wire_length_changes.append(wire_length_change)
                    episode_lengths.append(steps)
                    
                    episode_total_time = time.time() - episode_start_time
                    total_episode_time += episode_total_time
                    total_inference_time += episode_inference_time
                    total_step_time += episode_step_time
                    
                    print(f"Steps: {steps}")
                    print(f"Total Reward: {episode_reward:.2f}")
                    print(f"DRV Reduction: {drv_reduction:.1f}%")
                    print(f"Wire Length Change: {wire_length_change:.1f}%")
                    print(f"Episode Time: {episode_total_time:.3f}s")
                    print(f"  - Inference Time: {episode_inference_time:.3f}s")
                    print(f"  - Environment Step Time: {episode_step_time:.3f}s")
                    break
        
        total_eval_time = time.time() - total_start_time
        
        # Print summary statistics
        print("\nPerformance Summary:")
        print("-" * 50)
        print(f"Average Episode Length: {np.mean(episode_lengths):.1f} steps")
        print(f"Average Total Reward: {np.mean(total_rewards):.2f}")
        print(f"Average DRV Reduction: {np.mean(drv_reductions):.1f}%")
        print(f"Average Wire Length Change: {np.mean(wire_length_changes):.1f}%")
        print("\nTiming Summary:")
        print("-" * 50)
        print(f"Model Load Time: {model_load_time:.3f} seconds")
        print(f"Average Episode Time: {total_episode_time/num_episodes:.3f} seconds")
        print(f"Average Inference Time per Episode: {total_inference_time/num_episodes:.3f} seconds")
        print(f"Average Environment Step Time per Episode: {total_step_time/num_episodes:.3f} seconds")
        print(f"Average Time per Step: {total_episode_time/sum(episode_lengths)*1000:.2f} ms")
        print(f"Total Evaluation Time: {total_eval_time:.2f} seconds")
        
        return {
            'rewards': total_rewards,
            'drv_reductions': drv_reductions,
            'wire_length_changes': wire_length_changes,
            'episode_lengths': episode_lengths,
            'model_load_time': model_load_time,
            'total_inference_time': total_inference_time,
            'total_step_time': total_step_time,
            'total_episode_time': total_episode_time,
            'total_eval_time': total_eval_time
        }
    
    finally:
        # Clean up if using dummy data
        if use_dummy_data:
            try:
                if os.path.exists("parsed_log_data.csv"):
                    os.remove("parsed_log_data.csv")
                if os.path.exists("box_violations.pkl"):
                    os.remove("box_violations.pkl")
            except Exception as e:
                print(f"Warning: Could not clean up temporary files: {e}")

if __name__ == "__main__":
    evaluate_model(num_episodes=5, use_dummy_data=True)
