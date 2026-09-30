# Yutani-Building-better-worlds
A high-performance, multi-threaded 3D Sandbox &amp; Multimedia Framework for Delphi.    
Powered by Jolt Physics, Raylib, R3D, SDL3, MiniAudio, TinySoundFont, libmpv, RecastNavigation, VerySimpleLua, and Skia4delphi.    
          
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/LaMitaOne/Yutani-Building-better-worlds)    
        
<img width="1672" height="941" alt="yutani_wallpaper2" src="https://github.com/user-attachments/assets/43b3557c-8b4d-4203-bd03-d798fcc60807" />
          
Sample video: https://youtu.be/EaJqNMYcxJo        
    
Welcome to **Yutani**, a cutting-edge, fully asynchronous 3D Multimedia & Physics Engine written from scratch in Object Pascal.    
    
This framework breaks the boundaries of traditional Delphi development by fusing industry-standard C-libraries into a highly optimized, thread-safe VCL sandbox ecosystem. No bloated form-designers, no legacy overhead—just pure, high-performance spatial engineering.   
Started as "sample" in Joltphysics4delphi repo, it got a bit too big, it had to get its own name.      
> 💡 **A personal note:** To be completely honest, I don't know how far I can get this thing since I am still learning 3D development—I've only been doing real 3D dev for about a month now! But I love the challenge, it's mutating into a giant powerhouse, and I try to push it as far as I possibly can. (And for the first time, I think playing Second Life wasn't totally useless :D)                
    
### 🛠️ The Tech-Stack Powering the Core:    
* **3D Physics Core:** Powered by **Jolt Physics** via a robust, custom multi-threaded wrapper with precise continuous collision detection (CCD).    
* **Blazing Fast Rendering:** Driven by **Raylib & r3d**, utilizing custom GLSL shaders for advanced lighting and shadows directly on the GPU.    
* **Procedural Textures & HUD (to do):** Fully generated via **Skia4Delphi** inside memory buffers for crisp, transparent, high-DPI vector interfaces.    
* **Cinematic Multimedia:** Integrated **libmpv** engine streaming hardware-accelerated video feeds straight into real-time 3D OpenGL textures.    
* **Input Layer:** Multi-threaded **SDL3 Gamepad Core** featuring button mapping and zero-latency feedback.    
* **Advanced Audio Engine:** A dual-engine setup providing full acoustic feedback. MiniAudio drives real-time 3D spatial sound and HRTF attenuation, while TinySoundFont handles on-the-fly SF2 synthesis for dynamic music sequences and retro soundtracks.
* **AI Pathfinding & Navigation:** We will use **RecastNavigation** for automated 3D NavMesh generation directly from Jolt geometry, allowing smooth asynchronous entity pathfinding.    
* **Dynamic Gameplay Scripting:** Embedded **VerySimpleLua** engine to script entity logic, triggers, and game rules at runtime without re-compiling the core.    
           
Status: Work in Progress (Alpha v0.62)    
         
<img width="550" alt="Unbenannt" src="https://github.com/user-attachments/assets/cd3f12d5-3752-4585-9d49-bfa5002fc5ac" />    
     
## ✨ Features     

### 🦾 Core Physics System (Jolt Physics)     
* **World Simulation:** Full asynchronous physics initialization, automated broadphase optimizations, and gravity control.     
* **Rigid Bodies:** Complete state synchronization (`Static`, `Kinematic`, `Dynamic`) with seamless position, rotation, and custom scale transformations.
* **Collision Shapes:** Native wrappers for Box, Sphere, Capsule, Cylinder, Tapered shapes, Convex Hulls, Compound shapes, Meshes, and Heightfields.     
* **Physics Interactions:** Real-time application of forces, torques, linear/angular impulses, and precise velocity controls.     
     
### 🔍 Advanced Collision & Queries     
* **3D Raycasting:** Screen-to-world raycasting for precise object grabbing, context selection, and mouse interaction.     
* **Shape Casting (Sweeps):** Advanced `CastShape` and `CollideShape` implementations for swept-sphere and swept-capsule testing, crucial for smooth character navigation.     
* **Table-based Layering:** Explicit object filtering via highly customized BroadPhase and ObjectLayer tables.     
* **Collision Groups:** GroupFilter and SubGroupID management to enforce complex collision rules (e.g., ignoring attached attachments or inner ragdoll constraints).     
     
### 🚀 Complex Engine Subsystems     
* **Virtual Characters & Avatars:** Fully integrated `CharacterVirtual` bindings with customized step-up/stair-walking algorithms and isolated rotation axis constraints (locking X/Z to keep characters perfectly upright).     
* **Ragdolls & Skeletons:** Full skeleton joint hierarchy mapping (Hinge, SwingTwist, Cone) with runtime ragdoll activation/deactivation.     
* **Vehicles:** Deep controller mechanics supporting engines, transmissions, anti-roll bars, differential gears, and custom track/wheel physics for cars and motorcycles.     
* **Soft Bodies:** Foundation for deformable objects built directly from custom vertex and edge maps.
* **AI Navigation & Pathfinding (Recast/Detour):** Automatic voxelization of 3D world meshes into walkable NavMeshes. Intelligent spatial steering, agent avoidance, and dynamic corridor paths for virtual entities.     
* **Runtime Scripting Interface (Lua):** Full binding layer exposing engine functions, entity transforms, and sound triggers to lightweight Lua scripts for instant gameplay prototyping.    
     
### 🎮 Input & Spatial Audio (SDL3, MiniAudio & TinySoundFont)    
* **Threaded Input Core: Multi-threaded SDL3 Gamepad integration supporting hot-plugging, custom axis mapping, and deadzone stabilization.    
* **3D Positional Acoustics: Audio rendering via MiniAudio4Delphi for real-time sound attenuation and space-aware acoustic feedback on physics impacts.        
* **Dynamic Soundtrack Synthesis: Integration of TinySoundFont4Delphi allowing on-the-fly MIDI sequencing and .sf2 SoundFont playback directly within the 3D environment.   
     
### 🪐 Multimedia & Video Pipeline (libmpv)     
* **Direct GPU Texture Mapping:** Utilizes `libmpv`'s native OpenGL context rendering (`libMPV.Render_gl.pas`) to stream video feeds directly into Raylib 3D textures without crushing CPU or VRAM bandwidth.     
* **Spatial Interactive Screens:** Interact with floating video panels using raycasts, move them in 3D space, and toss them around with Jolt physics while videos keep playing live.     
     
### 🎨 Procedural UI, HUD & Texturing (Skia4Delphi)     
* **Zero-Image Architecture:** Entirely procedural 2D/3D asset pipeline. No heavy `.png` or `.bmp` files needed—everything is drawn mathematically in memory.     
* **High-DPI Vector HUD:** Crisp, modern, transparent HUD elements and custom menus drawn via Skia, avoiding restrictive legacy Win32 VCL styling blocks.
* **Procedural 3D Textures:** Generate dynamic signs, indicators, and textures on the fly and map them directly onto Jolt rigid bodies.     
      
### 🛠️ Editor, Environment & Tooling     
* **Full Local Gizmo System:** Local-space Translate, Rotate, and Scale Gizmos (toggled via CTRL) that scale dynamically to remain grabbable at any distance.     
* **Object Inspector (RTTI):** Fully asynchronous property editor using Delphi RTTI. Modify Mass, Friction, Restitution, Scale, and Position live from a dark-themed TStringGrid.     
* **Safe Editing System:** Dynamic detach-on-grab mechanism that safely pulls bodies out of the physics simulation during gizmo scaling and safely re-attaches them without physics jitters.    
* **Advanced Shading & Weather:** Custom GLSL shaders for real-time ambient/diffuse shading, moving procedural cloud layers, a horizon-to-zenith gradient skybox, and a full Day/Night progression cycle.    
* **Dynamic Fake Shadows:** Shadow maps that scale in size and fade out realistically based on an object's Y-height.    
     
---    
     
## ⌨️ Controls    
* **CTRL:** Toggle between Move / Rotate / Scale Gizmos    
* **Middle Mouse Click + Drag:** Rotate Editor Camera    
* **WASD:** Move Editor Camera    
* **Mouse Wheel:** Zoom In / Out    
* **CTRL + Q / E:** Select previous / next Actor in Hierarchy    
    
---    
    
  Exe and sample project included    
      
Latest Changes:     
     
v0.62:    
     
    Changed project name for new single repo out of the joltphysics wrapper repo
    Added MRX Gamepad Core & SDL3.dll
    Added new Tab Controls
    Added skia4delphi rendered splash intro
    Added OnActorDestroyed event
    Fixed bombs not getting removed after explode
               
includes:      
Raylib 3d https://github.com/LaMitaOne/r3d-delphi   
MiniAudio4Delphi https://github.com/LaMitaOne/MiniAudio4Delphi    
JoltPhysics4Delphi https://github.com/LaMitaOne/JoltPhysics4Delphi    
MRX Gamepad Core https://github.com/LaMitaOne/MRX-Gamepad-Core     
TinySoundFont4Delphi https://github.com/LaMitaOne/Tinysoundfont4delphi     
RecastNavigationDelphi https://github.com/Kromster80/RecastNavigationDelphi   
VerySimpleLua https://github.com/Dennis1000/verysimplelua     
       
Get mpv2 dll: https://sourceforge.net/projects/mpv-player-windows/     
      
3D Test Models by https://kenney.nl/     
       
## 🌐 Recommended 3D Model Sources     
Looking for more `.glb` / `.gltf` assets to test in the sandbox? Check out these awesome free resources:     
- [Kenney](https://kenney.nl) | [Quaternius](https://quaternius.com) | [Kay Lousberg](https://kaylousberg.com)    
- [Poly Pizza](https://poly.pizza) | [Poly Haven](https://polyhaven.com) | [The Base Mesh](https://thebasemesh.com)
- [SketchFab](https://sketchfab.com)  https://upsampler.com/free-image-to-3d-no-signup       
              
## 📄 License
This project is licensed under the **Apache License 2.0** - see the LICENSE file for details. This protects the core Yutani Engine assets, graphics, and unique architecture configurations while enabling powerful open-source expansion.   
   
*"The engine is the code you write." — John Carmack.*     
      
### 🛸 Trivia / Easter Egg      
**Fun Fact:** The very first custom 3D `.glb` model successfully loaded and simulated into this engine's pipeline was the iconic **M577 Alien APC**. So choosing the name **Yutani** wasn't just a random sci-fi choice—it was practically hardcoded by fate! 🪐     
Cultural Note: In Japanese, Yutani (由谷) translates to "Valley of Origin"...     
