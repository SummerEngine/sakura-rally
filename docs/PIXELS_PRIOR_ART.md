# Pixel-based RL driving: prior art for Sakura Rally

Scope: web research only. Each claim cites a URL. `UNVERIFIED` = I could not confirm it from a primary source. `[INFERENCE]` = my own arithmetic or reading, not stated by the source.

Sakura Rally baseline, for comparison: PPO (SB3, CPU), 46 floats, 42 discrete actions (7 steer × 3 pedal × 2 handbrake), 10 Hz, 6M decisions / 80 min on an M1 Max for a ~95 s stage.

---

## 1. Linesight (Trackmania Nations Forever), the strongest image-based racing agent in the public domain

Sources: repo https://github.com/Linesight-RL/linesight · config https://github.com/Linesight-RL/linesight/blob/main/config_files/config.py · float assembly https://github.com/Linesight-RL/linesight/blob/main/trackmania_rl/tmi_interaction/game_instance_manager.py · network https://github.com/Linesight-RL/linesight/blob/main/trackmania_rl/agents/iqn.py · docs https://linesight-rl.github.io/linesight/build/html/

| Item | Value | Source |
|---|---|---|
| Image fed to the net | **160 × 120** (`W_downsized=160`, `H_downsized=120`) | config.py |
| Colour | **Grayscale**, 1 channel: BGRA frame → `cv2.COLOR_BGRA2GRAY`, stored as `(1, H, W) uint8` | game_instance_manager.py; https://linesight-rl.github.io/linesight/build/html/main_objects.html |
| Frame stacking | **None.** 1 image; the first conv has `in_channels=1`. Motion comes from floats: car-frame velocity, angular velocity and 5 previous actions | iqn.py (`img_head_channels = [1, 16, 32, 64, 32]`) |
| Capture method | **TMInterface 2 plugin, not DXcam.** `iface.request_frame(W, H)` then `get_frame()` reads `W*H*4` BGRA bytes over a socket. The game renders the frame and returns it already downscaled to 160×120 | https://github.com/Linesight-RL/linesight/blob/main/trackmania_rl/tmi_interaction/tminterface2.py |
| Game window | Windowed. Authors' settings: **640×480** windowed, 16× AA, minimum shadows. Docs: "lowest resolution available with low graphics quality"; trade-off between FPS and image quality | https://linesight-rl.github.io/linesight/build/html/_static/authors_settings.png ; https://linesight-rl.github.io/linesight/build/html/installation.html |
| Float vector length | **184** = `27 + 3*40 + 4*5 + 4*4 + 1` (matches `Linear(in_features=184)` in the printed model) | config.py; https://linesight-rl.github.io/linesight/build/html/wall_text.html |
| Float contents | [0] mini-race clock (actions elapsed in the 7 s horizon, overwritten at sampling time) · 20 = previous **5 actions** × {accel, brake, left, right} · 4 wheels × {is_sliding, has_ground_contact, damper_absorb} = 12 · gearbox_state, gear, actual_rpm, gear-change counter = 4 · 4 wheels × 4 one-hot contact-material types = 16 · angular velocity in car frame (3) · velocity in car frame (3) · world-up vector in car frame (3) · **40 reference-line ("zone centre") points, xyz in car frame = 120** · distance to finish, clipped at 700 m (1) · is_freewheeling (1) | game_instance_manager.py lines ~402–494; buffer_utilities.py L97 https://github.com/Linesight-RL/linesight/blob/main/trackmania_rl/buffer_utilities.py |
| Look-ahead geometry | Reference points are 0.5 m apart; one in every 20 is used, 40 of them → points every **10 m, out to 400 m ahead** [INFERENCE from `distance_between_checkpoints=0.5`, `one_every_n_zone_centers_in_inputs=20`, `n_zone_centers_in_inputs=40`]. **Linesight feeds road geometry alongside the pixels; it does not replace geometry with pixels.** | config.py |
| CNN | Conv(1→16, k4, s2) → Conv(16→32, k4, s2) → Conv(32→64, k3, s2) → Conv(64→32, k3, s1), LeakyReLU, flatten = 5632. Float MLP 184→256→256. Concat 5888 → dueling A/V heads (512 hidden), IQN cosine embedding 64. **6.58M parameters** in total | wall_text.html; config.py (`conv_head_output_dim=5632`) |
| Algorithm | **IQN** (implicit quantile network) with dueling heads. `iqn_n=8`, `iqn_k=32`, κ=5e-3. DDQN off. **n-step = 3**. PER code exists but `prio_alpha=0`, so sampling is effectively uniform. γ 0.999 → **1.0** after 2.5M steps, made workable by 7 s "mini-races" (Q = undiscounted reward over the next 7 s). Batch 512. Adam lr 1e-3 → 5e-5 (3M) → 1e-5 (15M). Soft target τ=0.02. ε 1 → 0.1 (300k) → 0.03 (3M), plus Boltzmann exploration. Replay 50k → 200k transitions; each transition is reused 32 times | config.py; https://linesight-rl.github.io/linesight/build/html/main_objects.html |
| Reward | −6/5000 per ms plus 5/500 per metre advanced along the reference line | config.py |
| Actions | **12 discrete** combinations of {forward, none, brake, brake+accel} × {straight, left, right} | https://github.com/Linesight-RL/linesight/blob/main/config_files/inputs_list.py |
| Decision rate | **50 ms per action (20 Hz)**: 5 engine steps × 10 ms | config.py; video "low refresh rate… more than 20 frames per second?" https://www.youtube.com/watch?v=9juZgQc4D7U |
| Game speed-up | Requested `running_speed = 80`. Achieved end to end: **~10×**, "most time spent now is in rendering game frames and running the inference". Physics-only TM runs at ~60× (donadigo, TMInterface author). HoD: trained at "9x speed" | config.py; https://news.ycombinator.com/item?id=40874659 ; https://hallofdreams.org/posts/trackmania-1/ |
| Parallel instances | Default `gpu_collectors_count = 2`. Sweet spot: **4 instances on Linux, 2 on Windows**; Linux is 58% faster | config.py; https://linesight-rl.github.io/linesight/build/html/user_faq.html |
| Hardware | Ryzen 7 5700G, 64 GB RAM, RTX 4070 Ti (docs). Video: "a mid-range gaming computer… 64 gigabytes of RAM, because I need to store a million screenshots" | user_faq.html; https://www.youtube.com/watch?v=cUojVsCJ51I |
| Samples to competence (Hockolicious, ~54 s track) | 300k steps: learns to press forward · **500k: first finish** · **1M: finishes regularly** · **3–5M: low-54 s** (near top-20 human) | https://linesight-rl.github.io/linesight/build/html/first_training.html |
| Wall-clock (Hockolicious video, 2023) | 20 min: first obstacle · **2 h: finishes consistently** · 8 h: beats gold medal · **40 h: beats the 2009 WR** · **<70 h: beats the 2012 WR** (CarlJr). Final run 23rd all-time. HoD: 80 h at 9× ≈ "a month" of play | https://www.youtube.com/watch?v=9juZgQc4D7U (transcript); https://hallofdreams.org/posts/trackmania-1/ |
| Wall-clock (2024 official WRs) | "Running the code from scratch takes days"; multiprocessing plus multiple instances tripled training speed; A02 WR (no-cut) "with just a few days of training" | https://www.youtube.com/watch?v=cUojVsCJ51I (transcript) |

[INFERENCE] 5M steps × 50 ms is about 69 h of game time. At ~9–10× aggregate speed that is about 7–8 h wall-clock, which matches "8 h beats gold" in the video. Linesight's step budget (1M steps to finish regularly, 3–5M to near-top on a 54 s track at 20 Hz) is in the same range as Sakura's 6M decisions, while using pixels **plus** a 184-float state that includes geometry.

---

## 2. Yosh (yoshtm) Trackmania AI: state vectors, not images

| Video | Inputs (his own words) | Rate | Training time | URL |
|---|---|---|---|---|
| "Training an unbeatable AI in Trackmania" (2023-09-30) | "a few numbers": speed, "position relative to the road centreline", "inputs to encode the map path for the next three corners", full car orientation, which wheels touch the road / are sliding. No image. Random spawn points along the map. Brake initially disabled | "every tenth of a second" (10 Hz) | on a laptop: ~9 h to first finish, **35 h** to beat his PB; "hundreds of hours" overall | https://www.youtube.com/watch?v=Dw3BZ6O_8LY |
| "AI Learns to Drive on Pipes" (2024-03-13) | "speed, position and orientation on the pipe", distance to / direction of next corner | 10 Hz | "after 12 hours of driving…" | https://www.youtube.com/watch?v=kojH8a7BW04 |
| "AI Learns to Exploit a Glitch" (noseboost, 2025-01-30) | state plus target-location inputs | "100 actions per second" | many days | https://www.youtube.com/watch?v=NUl6QikjR04 |
| "AI just Broke Trackmania's Greatest World Record" (A01, 2025-09-03) | "20 times per second, it gets a few numbers describing the state of the car and how it's positioned on the road" | 20 Hz | hours to beat the developers' time | https://www.youtube.com/watch?v=zFLQU70QstY |
| "I Trained an AI to Beat This Absurd World Record" (A06, 2026-03-11) | state (same framework) | — | 1 h: completes most of the map; **40 h**: near world top-300 | https://www.youtube.com/watch?v=1AGVABna3xQ |
| "AI Learns to Drive From Scratch in Trackmania" (2022-03-12) | — | — | Deep Q-Learning (video description) | https://www.youtube.com/watch?v=SX08NT55YhA |

- **Algorithm (2023+): UNVERIFIED.** The videos do not name it. Hall of Impossible Dreams links "Training an unbeatable AI" as an example of "Soft Actor-Critic" and describes the inputs as "a system like LIDAR, but with more information about the upcoming curvature" (secondary source: https://hallofdreams.org/posts/trackmania-1/).
- Other tricks: a temporary reward bonus to bootstrap neo-drifts, then removed; random spawn points (Dw3BZ6O_8LY transcript).

---

## 3. CarRacing (Gymnasium) from pixels

- Observation: **96×96 RGB** top-down view, including a bottom HUD. 5 discrete or 3 continuous actions. Reward −0.1/frame + 1000/N per tile. `reward_threshold=900`, `max_episode_steps=1000`. Sources: https://github.com/Farama-Foundation/Gymnasium/blob/main/gymnasium/envs/box2d/car_racing.py ; https://github.com/Farama-Foundation/Gymnasium/blob/main/gymnasium/envs/__init__.py
- "Solved" = average ≥900 over 100 consecutive episodes (https://github.com/openai/gym/wiki/Leaderboard).

| Method | Preprocessing | Budget | Score | Source |
|---|---|---|---|---|
| World Models (Ha & Schmidhuber 2018): VAE (z=32) + MDN-RNN + linear controller (867 params), CMA-ES pop 64 × 16 rollouts | 64×64 RGB, no stacking (the RNN supplies memory) | 10,000 random rollouts to train V/M; CMA-ES generations (count not extracted) | **906 ± 21**; V-only 632 ± 251; V + hidden 788 ± 141 | https://worldmodels.github.io/ |
| DQN / A3C (as cited by World Models) | — | — | DQN 343 ± 18; A3C cont. 591 ± 45; A3C discrete 652 ± 10 | https://worldmodels.github.io/ |
| PPO (SB2 PPO2), NotAnyMike | HUD removed, **grayscale, stack 4**, 5 discrete actions | **10M steps**, 6 envs, ~12 h, i7-8th gen + RTX 2080 | score not extracted | https://notanymike.github.io/Solving-CarRacing/ |
| PPO (xtma) | 4×96×96 stack, action repeat 8, Beta policy | — | leaderboard re-test ≈ 820 (shaped-score issue) | https://github.com/xtma/pytorch_car_caring ; https://github.com/openai/gym/wiki/Leaderboard |
| PPO (Rafael1s) | pixels | 2760 episodes | 901 claimed; re-test **820** | https://github.com/openai/gym/wiki/Leaderboard |
| SB3 RL-Zoo PPO, CarRacing-v3 config | frame-skip 2, **64×64 grayscale, frame_stack 2**, 8 envs, gSDE | **4M steps** | (v0 benchmark: PPO 153.9 ± 74.5 at 4M) | https://github.com/DLR-RM/rl-baselines3-zoo/blob/master/hyperparams/ppo.yml ; https://github.com/DLR-RM/rl-baselines3-zoo/blob/master/benchmark.md |
| SB3 PPO-LSTM, CarRacing-v0 | zoo preprocessing | **4M steps** | **880.4 ± 31.9** (HF card); 862.5 ± 97.3 (benchmark.md) | https://huggingface.co/sb3/ppo_lstm-CarRacing-v0 |
| SB3 RL-Zoo SAC / TQC | pretrained autoencoder on the image + 2-step history, MlpPolicy | 1M steps | — | https://github.com/DLR-RM/rl-baselines3-zoo/blob/master/hyperparams/sac.yml |
| DreamerV3 | — | — | **No published CarRacing number found (UNVERIFIED)** | — |

Typical preprocessing (from the rows above): crop the HUD, grayscale, 64–96 px, stack 2–4, frame-skip 2–8. Model-free PPO needs **~4–10M env steps** to approach 900. The only well-documented ≥900 results use a learned latent (World Models) or recurrence (PPO-LSTM).

---

## 4. Sample efficiency: pixels vs state (DeepMind Control)

### 4a. Raw numbers (6 PlaNet tasks, env steps)

Table from CURL (https://arxiv.org/abs/2004.04136, Table 1) and RAD (https://arxiv.org/abs/2004.14990, Table 1):

| Task | State SAC 100k | State SAC 500k | Pixel SAC 500k | CURL 100k | CURL 500k | RAD 100k | RAD 500k |
|---|---|---|---|---|---|---|---|
| finger spin | 811 | 923 | 179 | 767 | 926 | 856 | 947 |
| cartpole swingup | 835 | 848 | 419 | 582 | 841 | 828 | 863 |
| reacher easy | 746 | 923 | 145 | 538 | 929 | 826 | 955 |
| cheetah run | 616 | 795 | 197 | 299 | 518 | 447 | 728 |
| walker walk | 891 | 948 | 42 | 403 | 902 | 504 | 918 |
| ball-in-cup catch | 746 | 974 | 312 | 769 | 959 | (not extracted) | 974 |
| **median** [INFERENCE: computed] | **778** | **923** | **188** | **560** | **914** | 826 (5 tasks) | **932** |

- **Pixel SAC without augmentation** reaches 0.04–0.49× of state SAC at 500k. At 500k it is still below state SAC at 100k on **6/6 tasks**, so it needs >5× the samples, often unbounded [INFERENCE from the table].
- SAC-AE paper, Table 1 (https://arxiv.org/abs/1910.01741): after **1000–3000 episodes (1–3M env steps)**, SAC:pixel vs SAC:state = walker walk **33 vs 974**, reacher 121 vs 953, cheetah 366 vs 836. The authors: "large performance gap between SAC:pixel and SAC:state".
- **With augmentation or representation learning:** CURL at 500k ≥ state SAC at 100k on 5/6 tasks. RAD and DrQ at 500k ≥ state SAC at 100k on 6/6 tasks. So the multiplier is **≤5×**, and at the 500k mark they **match** state SAC (CURL "matches the median state-based score" at 500k; RAD "matches state SAC on 11 of 15 envs"; RAD "improves pixel SAC by 4×"). At 100k, CURL/state ratios are 0.45–1.03 per task and RAD's are 0.57–1.11.
- DrQ (https://arxiv.org/abs/2004.13649, Table 1): 500k medians DrQ **929.5** vs State SAC 945.5 [INFERENCE: medians computed]. At 100k, DrQ ≥ State SAC on finger (901 vs 672) and cheetah (344 vs 228). DrQ uses 84×84 inputs, **3-frame stack**, random shift = pad 4 px + random 84×84 crop.
- **DreamerV3** (https://arxiv.org/abs/2301.04104, Tables 11–12): Dreamer on **proprio at 500k** mean **871** / median 754; Dreamer on **visual at 1M** mean **861** / median 786. Equal score at **~2× the steps** from pixels. DrQ-v2 visual at 1M mean 770 vs proprio D4PG/DMPO at 500k 792/801 (≈2×). Plain SAC from pixels at 1M: mean **81**. **PPO** is weak on both: proprio 500k mean 94, visual 1M mean 94. All DreamerV3 benchmarks ran on 1 A100 each; Visual Control uses action repeat 2 and 16 env instances.

### 4b. Multiplier summary

| Regime | k = pixel samples / state samples | Basis |
|---|---|---|
| Augmented off-policy (DrQ/RAD/CURL/DrQ-v2) or world model (DreamerV3) | **~1–2×** at convergence, **≤5×** early | CURL/RAD/DrQ tables; DreamerV3 500k proprio ≈ 1M visual |
| Pixel SAC with no augmentation or auxiliary loss | **>5×, often >10× or never** | CURL/RAD Pixel SAC column; SAC-AE Table 1 |
| Pixel PPO | no clean DMC multiplier; weak in both modalities at 0.5–1M steps. CarRacing needs 4–10M steps | DreamerV3 Tables 11/12; §3 |

### 4c. Wall-clock / throughput and architectures

- **DrQ-v2** (https://arxiv.org/abs/2107.09645): **96 env FPS on one V100** (up from DrQ's 28), i.e. **1M env steps ≈ 2.9 h**, "most tasks… 8 hours on a single GPU". Humanoid walk: **30M frames ≈ 86 h**. 3.5× faster than the DrQ implementation; 4× faster wall-clock than DreamerV2 at similar sample efficiency. Uses 84×84, 3-stack, random shift ±4 px, n-step returns, DDPG backbone. [INFERENCE] 96 FPS ≈ 345k frames/hour.
- **IMPALA CNN** (https://arxiv.org/abs/1802.01561): 3 stacks of [Conv3×3 → MaxPool3×3/s2 → 2 residual blocks] with **[16, 32, 32] channels**, then FC 256. On DMLab-30, deep beats shallow: 46.5% vs 37.1% test score (IMPALA, 1 GPU); experts 191.8% vs 93.2% median. Throughput up to 250k frames/s distributed.
- **Nature CNN** (DQN, Mnih 2015), as implemented in SB3: Conv 32 8×8 s4 → 64 4×4 s2 → 64 3×3 s1 → FC 512, on 84×84×4 grayscale. SB3 `CombinedExtractor` (Dict obs) = NatureCNN(image → 256) concatenated with the flattened vector obs. https://github.com/DLR-RM/stable-baselines3/blob/master/stable_baselines3/common/torch_layers.py
- **Procgen** (https://arxiv.org/abs/1912.01588): 64×64 RGB, IMPALA CNN, **no frame stacking** ("only minimally impacts performance"), 25M steps ≈ 3 GPU-hours with PPO (easy mode).

---

## 5. Other image-based (and state-based) racing drivers

- **GT Sophy** (Wurman et al., Nature 2022; open PDF https://www.cs.utexas.edu/~pstone/Papers/bib2html-links/nature22.pdf). **Confirmed: state, not pixels.**
  - Inputs:
    - **60 equally spaced 3D points** on each of left edge, right edge and centre line, spanning ~**6 s** of travel at current speed, in the ego frame.
    - Car state: 3D velocity, angular velocity, acceleration, tyre loads, slip angles.
    - Track state: progress (sin/cos), surface inclination, orientation vs centre line.
    - Opponents: ordered lists of state features.
  - Rate and algorithm: **10 Hz** (5–60 Hz tested, "no substantial performance gains" above 10 Hz). **QR-SAC**, n-step.
  - Compute: 10–20 PS4s, each controlling up to 20 cars, running in real time. Trainer: 1 V100 or ½ A100.
  - Time: "only a few hours" to get around the track, faster than 95% of humans in 1–2 days, **+9 days (>45,000 driving hours)** to plateau. Maggiore: most seeds superhuman in **10 days**, the slowest in 25.
  - Course-representation ablation (Fig. 2b): "Representing the upcoming track as sequences of points was advantageous". The bar values in PDF text order are baseline 114.47 s, 115.72, 117.11, >130 for "course points only / wall lidar + curvature / projected position" [INFERENCE: label-to-value mapping from text order].
- **AWS DeepRacer** (Balaji et al. 2019, https://arxiv.org/abs/1911.01562): camera at **15 fps → 160×120 grayscale**, single image. **PPO**, 10 discrete actions (2 throttle × 5 steer). Converges "in <5 minutes and ∼5000 simulation steps" (simple lane following). Domain randomisation for sim2real.
- **Donkey Car, "Learning to drive smoothly in minutes"** (Raffin): camera 160×120 **RGB**, top third cropped → 160×80, **VAE latent (z=64 in README) + last 20 commands**, **SAC**, **5000 steps**. https://github.com/araffin/learning-to-drive-in-5-minutes (config.py, README)
- **Learning to Drive in a Day** (Kendall et al. 2018, Wayve, https://arxiv.org/abs/1807.00412): monocular image **+ vehicle speed + steering angle**. **DDPG**, RL loop at **10 Hz**, 100 Hz low-level controller. Real car on a 250 m road: pixels 35 episodes / 37 min; **VAE 11 episodes / 15 min**. Image resolution **UNVERIFIED** (not stated in text).
- **End-to-end race driving, WRC6** (Jaritz et al. 2018, https://arxiv.org/abs/1807.02371), the closest analogue to a rally game:
  - Input: **84×84×3 RGB** front camera (30 fps) **+ speed + previous action** fed into an LSTM (no frame stack).
  - Algorithm: **A3C**, 32 discrete actions including **handbrake**, random-checkpoint respawn.
  - Scale: **9 game instances on 2 machines**, **140M steps**, 29.6 km of training tracks. Generalises to unseen tracks.
- **TORCS, A3C** (Mnih et al. 2016, https://arxiv.org/abs/1602.01783): "only a visual input in the form of an RGB image of the current frame", Atari architecture. **16 CPU threads, no GPU**. **~12 h** to reach 75–90% of human score. Input resolution **UNVERIFIED**; the Atari net uses 84×84.
- **TMRL** (Trackmania 2020): **64×64 grayscale, 4-frame history** + speed, gear, rpm (+ action buffer). SAC, **20 FPS real time**. LIDAR variant = 19 beams. "approximatively 5 hours for the car to understand how to take a turn" on an RTX 3080 trainer. https://github.com/trackmania-rl/tmrl/blob/master/readme/get_started.md ; https://github.com/trackmania-rl/tmrl/blob/master/tmrl/custom/tm/tm_gym_interfaces.py

### Driver summary table

| Name | Pixels W×H, colour | Stack | Extra inputs | Algorithm | Samples / wall-clock | Hardware | Source |
|---|---|---|---|---|---|---|---|
| Linesight (TMNF) | 160×120 gray (from 640×480 window) | 1 | 183 floats + mini-race clock: 5 prev actions, wheel contact/slide/damper, gear/rpm, surface one-hot, car-frame vel/ang-vel/up, **40 ref-line points (400 m)**, dist-to-finish | IQN, dueling, 3-step, γ→1 with 7 s horizon, 12 actions, 20 Hz | 1M steps finish; 3–5M near-top; 2 h / 8 h / 40–70 h (finish / gold / WR) at ~10× speed | Ryzen 7 5700G, RTX 4070 Ti, 64 GB; 2–4 instances | https://github.com/Linesight-RL/linesight |
| Yosh (TMNF/TM) | none (state) | — | speed, centreline offset, next 3 corners, orientation, wheel contact/slide | UNVERIFIED (HoD: SAC; 2022: DQN) | 9 h finish, 35 h > author; 40 h top-300 (A06) | laptop | https://www.youtube.com/watch?v=Dw3BZ6O_8LY |
| GT Sophy | none (state) | — | 3×60 course points (6 s), vel/acc/ang-vel, tyre load/slip, opponents | QR-SAC, 10 Hz | hours to lap; 1–2 days >95% humans; 10–25 days superhuman; >45k driving h | 10–20 PS4 + V100/½A100 | https://www.cs.utexas.edu/~pstone/Papers/bib2html-links/nature22.pdf |
| WRC6 (Jaritz) | 84×84 RGB | LSTM | speed, previous action | A3C, 32 actions incl. handbrake | 140M steps | 9 game instances / 2 machines | https://arxiv.org/abs/1807.02371 |
| TORCS A3C | RGB (84×84 UNVERIFIED) | Atari-style | none | A3C | ~12 h → 75–90% human | 16 CPU threads | https://arxiv.org/abs/1602.01783 |
| DeepRacer | 160×120 gray | 1 | none | PPO, 10 actions | ~5000 steps, <5 min (lane following) | cloud sim | https://arxiv.org/abs/1911.01562 |
| Donkey (Raffin) | 160×80 RGB → VAE z | — | 20 past commands | SAC | 5000 steps | desktop | https://github.com/araffin/learning-to-drive-in-5-minutes |
| Wayve LtDiaD | mono camera (res UNVERIFIED) | — | speed, steering angle | DDPG (+VAE) | 11 episodes / 15 min (VAE) | on-car compute | https://arxiv.org/abs/1807.00412 |
| TMRL | 64×64 gray | 4 | speed, gear, rpm, action buffer | SAC, 20 Hz real time | ~5 h to take turns (LIDAR env) | RTX 3080 trainer | https://github.com/trackmania-rl/tmrl |
| CarRacing PPO-LSTM (SB3) | 64×64 gray | 2 + LSTM | none | PPO-LSTM | 4M steps → 880 | — | https://huggingface.co/sb3/ppo_lstm-CarRacing-v0 |
| CarRacing PPO (NotAnyMike) | 96-wide gray, HUD panel removed (exact crop size not stated) | 4 | none | PPO2, 5 discrete actions | 10M steps / ~12 h, 6 envs | i7-8th gen + RTX 2080 | https://notanymike.github.io/Solving-CarRacing/ |
| World Models | 64×64 RGB → VAE z32 | RNN | none | CMA-ES on VAE+RNN | 10k random rollouts + ES | P100 + 64-core CPU | https://worldmodels.github.io/ |
| DrQ-v2 (DMC) | 84×84 RGB | 3 | none | DDPG + aug, n-step | 1M steps ≈ 2.9 h (96 FPS) | 1 V100 | https://arxiv.org/abs/2107.09645 |

---

## 6. Domain randomisation and augmentation for visual generalisation

- **Tobin et al. 2017** (https://arxiv.org/abs/1703.06907): detector trained only on sim images with random textures (non-realistic), lighting, camera pose and distractors transfers to the real world at **~1.5 cm** accuracy. Trained on "hundreds of thousands of low-fidelity rendered images".
- **RAD** (https://arxiv.org/abs/2004.14990): of all tested augmentations, **random crop / random translate** gives by far the largest gain. Decomposition: translation drives the gain, masking ("random window") does little. 4× over pixel SAC.
- **DrQ / DrQ-v2**: **random shift** (pad 4, crop back to 84) is the only augmentation used, and it is sufficient for SOTA sample efficiency (https://arxiv.org/abs/2004.13649 ; https://arxiv.org/abs/2107.09645).
- **Procgen** (Cobbe et al. 2020, https://arxiv.org/abs/1912.01588): PPO overfits strongly to small level sets. **~10,000 levels** are needed to close the train/test gap. The benchmark standard is 500 training levels. IMPALA CNN beats smaller nets; bigger IMPALA (×2, ×4) also generalises better.
- **DMControl Generalization Benchmark / SODA** (Hansen & Wang 2021, https://arxiv.org/abs/2011.13389; https://github.com/nicklashansen/dmcontrol-generalization-benchmark): test on random colours and natural-video backgrounds. New **random overlay** augmentation: `(1−α)·obs + α·Places-image`. **SODA** puts augmentation in an auxiliary consistency loss, keeping RL on clean data.
- **SVEA** (Hansen, Su & Wang 2021, https://arxiv.org/abs/2107.00644, Table 1): test returns, train on default visuals.

| Test | Walker walk | Cartpole swingup | Ball-in-cup |
|---|---|---|---|
| Colour_hard | DrQ 520 → **SVEA-conv 760 / SVEA-overlay 749** | 586 → 837 | 365 → 961 |
| Video_easy | DrQ 682 → **SVEA-overlay 819** (SVEA-conv 612) | 485 → 782 | 318 → 871 |

  Rule: **random conv / colour jitter** covers colour shifts; **overlay** covers background / texture shifts. SVEA stabilises Q-targets by computing them on un-augmented views.
- **Gymnasium CarRacing** has a built-in `domain_randomize=True` that changes background and track colours per reset (car_racing.py above). **DeepRacer** reports DR generalising "to multiple cars, tracks and to variations in speed, background, lighting, track shape, color and texture" (https://arxiv.org/abs/1911.01562).

---

## Implications for Sakura Rally

- **Inputs: hybrid, not pure pixels.** Every top racing agent that beat humans had look-ahead road geometry: Linesight (40 ref-line points to 400 m, *in addition to* the 160×120 image), GT Sophy (3×60 points over 6 s, no pixels) and Yosh (next-3-corners, no pixels). Pixels in Linesight add surface and obstacle information on top of geometry.
  - For a pixel-driven policy, keep the **non-geometric floats**: speed / car-frame velocity (3), yaw / angular velocity, current and last ~5 actions, and wheel contact / slide / surface if Godot exposes them.
  - Drop the 9 edge rays and the 14 centre-line points only as a deliberate experiment. That is the part pixels must replace, and no cited source shows pixels replacing it at human-beating level.
  - Keep centre-line progress for the **reward only** (as Linesight does).
- **Resolution and stack.**
  - Grayscale **128×96 to 160×120** single frame (Linesight, DeepRacer, Donkey) if velocity / yaw floats and previous actions are in the vector. Linesight uses no stack for this reason; Procgen found stacking of minor value.
  - Otherwise **84×84 gray × 3–4 stack** (DrQ/DMC, CarRacing, TMRL 64×64×4).
  - Render at low settings; Linesight is bound by rendering and inference, not physics (~10× vs ~60×).
- **Network.** Linesight's 4-conv head on 160×120 → 5632 features, then concat with a float MLP (256). Equivalent in SB3: `MultiInputPolicy` with `CombinedExtractor`, i.e. NatureCNN (→256) + the vector obs. Use the IMPALA CNN if the track visuals are diverse.
- **Algorithm.**
  - Discrete 42-action space plus off-policy reuse of expensive rendered frames favours a **value-based distributional agent (IQN / QR-DQN, n-step 3, replay ×32 reuse, dueling)**, as in Linesight. SB3-contrib has QR-DQN, but it needs a flattened `Discrete(42)` [INFERENCE].
  - PPO can work from pixels (CarRacing 4–10M steps; DeepRacer) but reuses each sample only `n_epochs` times and is the weakest pixel learner in the DreamerV3 tables.
  - Add **random shift ±4 px** (DrQ). Add **colour jitter / overlay** only if track visuals will vary at test time (SVEA/SODA).
- **Sample multiplier vs the current 6M state decisions.**
  - Augmented off-policy or world model: **~1–2×** at convergence, ≤5× early (CURL / RAD / DrQ ≈ state SAC at 500k; DreamerV3 visual 1M ≈ proprio 500k).
  - Hybrid pixels + floats with IQN: Linesight's own 1M (finish) / 3–5M (near-top) on a ~1000-step race is about **1×** our budget.
  - Naive pixel PPO / SAC without augmentation: **>5–10×**, sometimes never converging (Pixel SAC columns; SAC-AE Table 1; CarRacing PPO 4–10M).
  - Planning range [INFERENCE]: **2–5× → 12–30M decisions** for a hybrid augmented agent. Budget **≥10× (60M+)** if running plain SB3 PPO on pixels alone.
  - Wall-clock is then set by Godot render throughput, not physics. DrQ-v2's reference is ~345k frames/h on one V100.
- **Generalisation.** Train across several stages and random spawn points (Yosh, Jaritz random checkpoints). Procgen suggests level diversity in the thousands is needed to generalise to unseen stages.

Sources for this paragraph: Linesight config and docs, GT Sophy PDF, Yosh videos, CURL / RAD / DrQ / DrQ-v2 / DreamerV3 / SAC-AE papers, CarRacing leaderboard / zoo, SVEA / SODA, Procgen (all URLs above).
