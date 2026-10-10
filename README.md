# Yutani-Building-better-worlds
A high-performance, multi-threaded 3D Sandbox &amp; Multimedia Framework for Delphi.    
Powered by Jolt Physics, Raylib, R3D, SDL3, MiniAudio, TinySoundFont, libmpv, RecastNavigation, VerySimpleLua, GameNetworkingSockets, and Skia4delphi.    
          
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/LaMitaOne/Yutani-Building-better-worlds)    
        
<img width="1671" height="941" alt="yutani_wallpaper3" src="https://github.com/user-attachments/assets/bcce1fa4-51e7-4e91-a5a3-9275fb71967e" />
         
Sample video: https://youtu.be/uUjvsre8F4g         
(thats the sf2 used in sample video "FluidR3 GM.sf2" get it at https://github.com/urish/cinto/tree/master/media ❗      
    
Welcome to **Yutani**, a cutting-edge, fully asynchronous 3D Multimedia & Physics Engine written from scratch in Object Pascal.    
    
This framework breaks the boundaries of traditional Delphi development by fusing industry-standard C-libraries into a highly optimized, thread-safe VCL sandbox ecosystem. No bloated form-designers, no legacy overhead—just pure, high-performance spatial engineering.   
Started as "sample" in Joltphysics4delphi repo, it got a bit too big, it had to get its own name.      
> 💡 **A personal note:** To be completely honest, I don't know how far I can get this thing since I am still learning 3D development—I've only been doing real 3D dev for about a month now! But I love the challenge, it's mutating into a giant powerhouse, and I try to push it as far as I possibly can. (And for the first time, I think playing Second Life wasn't totally useless :D)                
    
### 🛠️ The Tech-Stack Powering the Core:    
* **3D Physics Core:** Powered by **Jolt Physics** via a robust, custom multi-threaded wrapper with precise continuous collision detection (CCD).    
* **Blazing Fast Rendering:** Driven by **Raylib & r3d**, utilizing custom GLSL shaders for advanced lighting and shadows directly on the GPU.    
* **Procedural Textures & HUD :** Fully generated via **Skia4Delphi** inside memory buffers for crisp, transparent, high-DPI vector interfaces.    
* **Cinematic Multimedia:** Integrated **libmpv** engine streaming hardware-accelerated video feeds straight into real-time 3D OpenGL textures.    
* **Input Layer:** Multi-threaded **SDL3 Gamepad Core** featuring button mapping and zero-latency feedback.    
* **Advanced Audio Engine:** A dual-engine setup providing full acoustic feedback. MiniAudio drives real-time 3D spatial sound and HRTF attenuation, while TinySoundFont handles on-the-fly SF2 synthesis for dynamic music sequences and retro soundtracks.
* **AI Pathfinding & Navigation:** We will use **RecastNavigation** for automated 3D NavMesh generation directly from Jolt geometry, allowing smooth asynchronous entity pathfinding.    
* **Dynamic Gameplay Scripting:** Embedded **VerySimpleLua** engine to script entity logic, triggers, and game rules at runtime without re-compiling the core.    
           
Status: Work in Progress (Alpha v0.647)    
         
<img width="1917" height="1081" alt="Unbenannt" src="https://github.com/user-attachments/assets/0e5bc929-34fc-4636-a5b1-f33af976b065" />
       
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
     
<img width="1920" height="1080" alt="Unbenannt" src="https://github.com/user-attachments/assets/f195e0bf-d0ee-48e2-a4aa-f3b9c437b8dd" />     
My first spaceship 🤤     
             
## ⌨️ Controls    
* **CTRL:** Toggle between Move / Rotate / Scale Gizmos    
* **Middle Mouse Click + Drag:** Rotate Editor Camera    
* **WASD:** Move Editor Camera    
* **Mouse Wheel:** Zoom In / Out    
* **CTRL + Q / E:** Select previous / next Actor in Hierarchy    
* **F10 on selected send alive highlighter     
    
---    
    
  Exe and sample project included    
      
Latest Changes:    
      
v0.647:        
     
  - Added a skia4delphi rendered, threaded, transparent holographic loading screen overlay for world transitions.
  - Moved heavy procedural planet texture generation to on-demand loading to fix startup freezes.
  - Made the loading screen trigger its own asynchronous fade-out and self-destruct without blocking the render loop.
  - Added a skia4delphi rendered sci-fi particle stream intro from the logo to form the "YUTANI" text.
  - Implemented floating origin system to eliminate physics jitter on planet surfaces
  - Added Solar System generation with suns, orbiting planets, moons, and proper lighting (Darksides)
  - Implemented dynamic sun lighting with Shader integration for planet models
  - Added comet collisions triggering surface impact particle bursts
  - Added slow-motion compatibility (TimeScale) for space simulation
  - Refined star distribution with cluster-based generation and galaxy-style coloring
  - Added Landing Autopilot System (F9): Smooth cinematic approach to planetary surfaces
  - Added Planetary Surface Camera Mode: Walk on Mario-Galaxy style little planets with correct surface normals and straight horizons
  - Added Planetary Orbit Cam (F8) for construction and building mechanics
  - Added Second Life style ALT+Click focus camera system
  - Added vehicle flight control system (F11): Possess any object and fly it with WASD/Numpad+/- physics thrust with a rigid Third-Person camera
  - Refactored startup intro to form the logo and text entirely from a dynamic Skia4Delphi particle stream.
              
v0.646:        

  - Added space skybox 
  - Removed space skybox, built real infinite procedural cosmos
    (Yutani.Worlds.Space: star sprites, nebulae, comets, planets)
  - Added Yutani.Worlds.Space.Textures: Skia-rendered procedural
    planet surfaces (Rocky, Earth, Mars, Gas Giant, Ice)
  - Planets are now textured 3D spheres (Mario Galaxy scale)
  - Comets now spray hundreds of flame particles (white-hot → dark red)
  - Nebulae use circular gradient billboards
  - Atmosphere glow uses two-layer circular billboards
  - Far plane extended to 10000 during space rendering
  - Stars use 4-pointed gradient sprites with twinkle
  - Chunk-based infinite procedural generation (deterministic per chunk)
  - Added SQLite.dll cause I think I Need it...later :D
     
<img width="1920" height="1080" alt="Unbenannt" src="https://github.com/user-attachments/assets/81943bd5-f072-4e5d-a045-d278d088adee" />
    
      
v0.645:        

    Added new yutani.render.nanofog unit
      
https://github.com/user-attachments/assets/b9df7c07-8160-479a-8271-9885242cc695
             
v0.644:        

    Changed beam spawn effect to new particle materialization 
    Added button dematerialization - demat actual object
    Added functions: DematerializeSelectedObject,  DematerializeActor(Actor: TA3DComponent)     
      
v0.643:        
    
    Fixed 3D Model Gizmo Resizing    
    Scene Save/Load: The physics state (IsStatic) is now correctly serialized and restored.    
    Added sample Scene. Load it, and objects falling down like i paused them here.    
    Enhanced Slow Motion System: Added property and trackbar to dynamically adjust the exact slow-motion speed multiplier (0.05x to 1.0x) on the fly.    
    Added Yutani.AliveHighlighter3d Select object, press F10 to send or Hide    
    Added unit Yutani.Worlds.Island - WorldBase Island now partly working   
    Added unit Yutani.Render.Particles and already working too   
    Added fog button, 10k particles spawn  
    Added particles on bomb explosion     
     
v0.642:    

    Fixed textures black or blueish on 3d models from far distance       
    Fixed spawned 3d model now same size like ghost preview     
    Added new gizmo mode Uniform Scale (Corner Resize)        
    Raised tinysoundfont thread idle timeout from 2s to 5s to allow sustained notes (e.g., piano) to fully decay and ring out without being abruptly cut off.        
    Integrated Yutani.VoronoiFracture: Dynamically generates real 3D Voronoi fragments when destructable objects take heavy impact. The system now successfully creates custom Raylib meshes with lighting, injects them into the Jolt Physics engine, and applies explosion forces.     
    Note: Fracture system is basically working now, but fragment rendering 
    (some transparency/normal issues) and physics colliders (misalignment, floating, minor jitter) 
    are not fully correct yet and require further headaches. :P   
     
v0.641:    

    Added 3d working piano connected to tinysoundfont    
    Added loadsoundfont btn in audio tab
    Added unit yutani.audio

<img height="150" alt="Unbenannt" src="https://github.com/user-attachments/assets/32c2bfca-4dd5-4b52-a5bb-6feca4320f42" />
     
v0.64:    
     
    Added TWorldBaseType = wbLand, wbSpace, wbHolodeck, wbIsland
    Added WorldBase selection combobox in engine tab
    Added TSpawnEffectType = spefNone, spefBeam, spefFade
    Added Checkbox chkAntialias
    Added Spinedit to set Gravity
    Added isDestructable Checkbox and property in TA3DComponent/SpawnREquest
    Improved Lighting System Reworked the GLSL light shader to prevent color washing on lit surfaces. Lighting is now calculated multiplicatively, preserving deep blacks and vibrant base colors while ensuring shadows darken surfaces correctly.
    Added Yutani.VoronoiFracture unit
     
v0.63:    
     
    Added Fullscreen btn, 
    Added Audio tab, Master Volume Control Trackbar &  Audio test btn
    Added TinySoundFont wrapper & dll
    Added RecastNavigationDelphi Units
    Added VerySimple.Lua Units & dll
    Added GameNetworkingSockets4delphi wrapper & dlls
     
v0.62:    
     
    Changed project name for new single repo out of the joltphysics wrapper repo
    Added MRX Gamepad Core & SDL3.dll
    Added new Tab Controls
    Added skia4delphi rendered splash intro
    Added OnActorDestroyed event
    Fixed bombs not getting removed after explode

<img width="1196" height="795" alt="Unbenannt" src="https://github.com/user-attachments/assets/eb0d1c04-cca6-45e8-ad33-7fe69539d728" />

700 fps on rtx 2060s... not bad :D    
               
includes:      
Raylib 3d https://github.com/LaMitaOne/r3d-delphi   
MiniAudio4Delphi https://github.com/LaMitaOne/MiniAudio4Delphi    
JoltPhysics4Delphi https://github.com/LaMitaOne/JoltPhysics4Delphi    
MRX Gamepad Core https://github.com/LaMitaOne/MRX-Gamepad-Core     
TinySoundFont4Delphi https://github.com/LaMitaOne/Tinysoundfont4delphi     
RecastNavigationDelphi https://github.com/Kromster80/RecastNavigationDelphi   
VerySimpleLua https://github.com/Dennis1000/verysimplelua     
GameNetworkingSockets4delphi https://github.com/LaMitaOne/GameNetworkingSockets4delphi        
Yutani Voronoi-Destruction-Engine https://github.com/LaMitaOne/Yutani-Voronoi-Destruction-Engine      
Yutani Particle Engine https://github.com/LaMitaOne/Yutani-Particle-Engine    
       
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

<img height="500" alt="Unbenannt" src="https://github.com/user-attachments/assets/389ab4f3-4822-4042-b2c3-96f65ec53335" />   
    
