<img src="assets/banner.png" alt="Logo" style="border-radius: 30px; width: 60%;">

## Context
- Cactus (YC S25) is a low-latency engine for mobile devices & wearables. 
- Cactus runs locally on edge devices with hybrid routing of complex tasks to cloud models like Gemini.
- Google DeepMind just released Gemma 4, the first on-device model you can voice-prompt. 
- Gemma 4 on Cactus is multimodal, supporting voice, vision, function calling, transcription and more! 

## Challenge
- All teams MUST build products that use Gemma 4 on Cactus. 
- All products MUST leverage voice functionality in some way. 
- All submissions MUST be working MVPs capable of venture backing. 
- Winner takes all: Guaranteed YC Interview + GCP Credits. 

## Special Tracks 
- Best On-Device Enterprise Agent (B2B): Highest commercial viability for offline tools.
- Ultimate Consumer Voice Experience (B2C): Best use of low-latency compute to create ultra-natural, instantaneous voice interaction.
- Deepest Technical Integration: Pushing the boundaries of the hardware/software stack (e.g., novel routing, multi-agent on-device setups, extreme power optimization).

Prizes per special track: 
- 1st Place: $2,000 in GCP credits
- 2nd Place: $1,000 in GCP credits 
- 3rd Place: $500 in GCP credits 

## Judging 
- **Rubric 1**: The relevnance and realness of the problem and appeal to enterprises and VCs. 
- **Rubric 2**: Correcness & quality of the MVP and demo. 

## Setup (clone this repo and hollistically follow)
- Step 1: Fork this repo, clone to your Mac, open terminal.
- Step 2: `git clone https://github.com/cactus-compute/cactus`
- Step 3: `cd cactus && source ./setup && cd ..` (re-run in new terminal)
- Step 4: `cactus build --python`
- Step 5: `cactus download google/functiongemma-270m-it --reconvert`
- Step 6: Get cactus key from the [cactus website](https://cactuscompute.com/dashboard/api-keys)
- Sept 7: Run `cactus auth` and enter your token when prompted.
- Step 8: `pip install google-genai` (if using cloud fallback) 
- Step 9: Obtain Gemini API key from [Google AI Studio](https://aistudio.google.com/api-keys) (if using cloud fallback) 
- Step 10: `export GEMINI_API_KEY="your-key"` (if using cloud fallback) 

## Next steps
1. Read Cactus docs carefully: [Link](https://docs.cactuscompute.com/latest/)
2. Read Gemma 4 on Cactus walkthrough carefully: [Link](https://docs.cactuscompute.com/latest/blog/gemma4/)
3. Cactus & DeepMind team would be available on-site. 
