# Yutani-Building-better-worlds
A high-performance, multi-threaded 3D Sandbox &amp; Multimedia Framework for Delphi. Powered by Jolt Physics, Raylib, R3D, SDL3, MiniAudio, libmpv, and Skia4delphi. Building better worlds, the delphi way...     
    
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/LaMitaOne/Yutani-Building-better-worlds)    
        
<img width="550" alt="yutani_intro" src="https://github.com/user-attachments/assets/8a2bb15a-5463-4501-80e8-ca77b986561a" />

Sample video: https://youtu.be/EaJqNMYcxJo        
    
Welcome to **Yutani**, a cutting-edge, fully asynchronous 3D Multimedia & Physics Engine written from scratch in Object Pascal.    
    
This framework breaks the boundaries of traditional Delphi development by fusing industry-standard C-libraries into a highly optimized, thread-safe VCL sandbox ecosystem. No bloated form-designers, no legacy overhead—just pure, high-performance spatial engineering.   
    
### 🛠️ The Tech-Stack Powering the Core:    
* **3D Physics Core:** Powered by **Jolt Physics** via a robust, custom multi-threaded wrapper with precise continuous collision detection (CCD).    
* **Blazing Fast Rendering:** Driven by **Raylib & r3d**, utilizing custom GLSL shaders for advanced lighting and shadows directly on the GPU.    
* **Procedural Textures & HUD (to do):** Fully generated via **Skia4Delphi** inside memory buffers for crisp, transparent, high-DPI vector interfaces.    
* **Cinematic Multimedia:** Integrated **libmpv** engine streaming hardware-accelerated video feeds straight into real-time 3D OpenGL textures.    
* **Input Layer:** Multi-threaded **SDL3 Gamepad Core** featuring button mapping and zero-latency feedback.    
* **Spatial Audio:** Implemented via **MiniAudio** for real-time 3D sound attenuation and positional acoustics.     
    
Status: Work in Progress (Alpha v0.62)    
         
---     
     
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
     
### 🎮 Input & Spatial Audio (SDL3 & MiniAudio)     
* **Threaded Input Core:** Multi-threaded SDL3 Gamepad integration supporting hot-plugging, custom axis mapping, and deadzone stabilization.
* **3D Positional Acoustics:** Audio rendering via `MiniAudio4Delphi` for real-time sound attenuation and space-aware acoustic feedback on physics impacts.
     
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
          
includes:      
Raylib 3d Wrapper https://github.com/LaMitaOne/r3d-delphi   
MiniAudio4Delphi Wrapper https://github.com/LaMitaOne/MiniAudio4Delphi    
JoltPhysics4Delphi https://github.com/LaMitaOne/JoltPhysics4Delphi    
MRX Gamepad Core https://github.com/LaMitaOne/MRX-Gamepad-Core     

Get mpv2 dll: https://sourceforge.net/projects/mpv-player-windows/     
      
3D Test Models by https://kenney.nl/     
       
## 🌐 Recommended 3D Model Sources     
Looking for more `.glb` / `.gltf` assets to test in the sandbox? Check out these awesome free resources:     
- [Kenney](https://kenney.nl) | [Quaternius](https://quaternius.com) | [Kay Lousberg](https://kaylousberg.com)    
- [Poly Pizza](https://poly.pizza) | [Poly Haven](https://polyhaven.com) | [The Base Mesh](https://thebasemesh.com)
- [SketchFab](https://sketchfab.com)     
      
   


       
## 📄 License
This project is licensed under the **Apache License 2.0** - see the LICENSE file for details. This protects the core Yutani Engine assets, graphics, and unique architecture configurations while enabling powerful open-source expansion.   
   
*"The engine is the code you write." — John Carmack.*   
