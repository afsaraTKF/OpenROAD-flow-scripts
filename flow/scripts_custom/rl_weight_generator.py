from stable_baselines3 import PPO
from rl_env import RoutingEnv


def generate_rl_weights(design_info, model_path="routing_agent.zip", optional_weight=None):
    """
    Generate weights using the trained RL model.
    This is for inference only - training data comes from weight_generator.py
    
    Args:
        design_info: Dictionary containing pin_count and net_count
        model_path: Path to trained model
        optional_weight: Override weight if provided
    Returns:
        Tuple of (drc_weight, marker_weight, fixed_weight, decay_weight)
    """
    if optional_weight is not None:
        return optional_weight
        
    # Load the trained model
    model = PPO.load(model_path)
    
    # Convert design info to state
    state = {
        'pin_count': design_info['pin_count'],
        'net_count': design_info['net_count']
    }
    
    # Get prediction from model
    action = model.predict(state)[0]
    
    # Convert to weights format
    weights = (
        int(action[0] * 10),  # drc_weight
        int(action[1] * 10),  # marker_weight
        int(action[2] * 10),  # fixed_weight
        float(action[3])      # decay_weight
    )
    
    return weights