{==============================================================================*
 *  Yutani Render Shaders
 *------------------------------------------------------------------------------
 *  Author : Lara Miriam Tamy Reschke / LamitaOne
 *
 *  Description:
 *    This unit contains all GLSL shader source codes used by the Yutani
 *    RaylibSandbox engine. Centralizing them makes it easier to maintain,
 *    debug, and expand the graphics pipeline.
 *
 *  Shaders included:
 *    - Lighting & Shadow Map (Vertex + Fragment)
 *    - Procedural Skybox (Vertex + Fragment)
 *    - Scrolling Clouds (Vertex + Fragment)
 *==============================================================================}
unit Yutani.Render.Shaders;

interface

const
  /// <summary>
  /// Vertex Shader for main 3D objects. Calculates world position, normals,
  /// lighting space position for shadows, and passes data to the fragment shader.
  /// </summary>
  VERT: AnsiString =
    '#version 330' + #10 +
    'in vec3 vertexPosition;' + #10 +        // Input: local vertex position (x,y,z)
    'in vec3 vertexNormal;' + #10 +          // Input: local vertex normal for lighting
    'in vec2 vertexTexCoord;' + #10 +        // Input: UV texture coordinates
    'in vec4 vertexColor;' + #10 +           // Input: vertex tint color (RGBA)
    'uniform mat4 mvp;' + #10 +              // Uniform: combined Model-View-Projection matrix
    'uniform mat4 matModel;' + #10 +         // Uniform: Model matrix (local to world space)
    'uniform mat4 lightView;' + #10 +        // Uniform: Light source view matrix (for shadow mapping)
    'uniform mat4 lightProj;' + #10 +        // Uniform: Light source projection matrix (for shadow mapping)
    'out vec3 vNormal;' + #10 +              // Output: normal vector to fragment shader
    'out vec2 vTexCoord;' + #10 +            // Output: UV coordinates to fragment shader
    'out vec4 vColor;' + #10 +               // Output: vertex color to fragment shader
    'out vec4 vWorldPos;' + #10 +            // Output: world space position to fragment shader
    'out vec4 vLightSpacePos;' + #10 +       // Output: position in light clip space (for shadow lookup)
    'void main()' + #10 +
    '{' + #10 +
    '  vWorldPos = matModel * vec4(vertexPosition, 1.0);' + #10 +           // Transform vertex position to world space
    '  vNormal = normalize(mat3(matModel) * vertexNormal);' + #10 +         // Transform normal to world space (using mat3 to ignore translation) and normalize it
    '  vTexCoord = vertexTexCoord;' + #10 +                                // Pass UV coordinates through to fragment shader
    '  vColor = vertexColor;' + #10 +                                      // Pass vertex color through to fragment shader
    '  vLightSpacePos = lightProj * lightView * vWorldPos;' + #10 +        // Transform world position into the light's clip space for shadow mapping
    '  gl_Position = mvp * vec4(vertexPosition, 1.0);' + #10 +             // Calculate final screen position (clip space) for the rasterizer
    '}';

  /// <summary>
  /// Fragment Shader for main 3D objects. Handles texturing, directional lighting,
  /// and basic shadow mapping with bias.
  /// </summary>
  FRAG: AnsiString =
    '#version 330' + #10 +
    'in vec3 vNormal;' + #10 +               // Input: interpolated world normal
    'in vec2 vTexCoord;' + #10 +             // Input: interpolated UV coordinates
    'in vec4 vColor;' + #10 +                // Input: interpolated vertex color
    'in vec4 vWorldPos;' + #10 +             // Input: interpolated world position
    'in vec4 vLightSpacePos;' + #10 +        // Input: interpolated light space position
    'uniform vec3 lightPos;' + #10 +         // Uniform: position of the light source in world space
    'uniform vec3 viewPos;' + #10 +          // Uniform: position of the camera/viewer in world space
    'uniform vec4 ambient;' + #10 +          // Uniform: ambient light color and intensity
    'uniform vec4 diffuse;' + #10 +          // Uniform: diffuse light color and intensity
    'uniform sampler2D texture0;' + #10 +    // Uniform: main diffuse texture (albedo)
    'uniform sampler2D shadowMap;' + #10 +   // Uniform: 2D shadow map texture rendered from the light's perspective
    'uniform float shadowBias;' + #10 +      // Uniform: bias value to prevent shadow acne (self-shadowing artifacts)
    'out vec4 finalColor;' + #10 +           // Output: final pixel color rendered to the screen
    'void main()' + #10 +
    '{' + #10 +
    '  vec3 lightDir = normalize(lightPos - vWorldPos.xyz);' + #10 +        // Calculate direction from pixel to light source and normalize it
    '  vec3 normal = normalize(vNormal);' + #10 +                          // Re-normalize the interpolated normal to ensure unit length
    '  float diff = max(dot(normal, lightDir), 0.0);' + #10 +              // Calculate diffuse intensity using dot product (Lambertian reflectance)
    '  vec4 texColor = texture(texture0, vTexCoord);' + #10 +              // Sample the main texture color at the given UV coordinates
    '  vec4 baseColor = vec4(vColor.rgb, vColor.a) * vec4(texColor.rgb, 1.0);' + #10 + // Combine vertex tint color with texture color
    '  vec3 projCoords = vLightSpacePos.xyz / vLightSpacePos.w;' + #10 +   // Perform perspective divide to get normalized device coordinates (NDC) in range [-1, 1]
    '  projCoords = projCoords * 0.5 + 0.5;' + #10 +                       // Remap NDC from [-1, 1] to [0, 1] to sample the shadow map
    '  float shadow = 0.0;' + #10 +                                        // Initialize shadow factor to 0 (no shadow)
    '  if(projCoords.z <= 1.0 && projCoords.x >= 0.0 && projCoords.x <= 1.0 && projCoords.y >= 0.0 && projCoords.y <= 1.0) {' + #10 + // Check if pixel is inside the shadow map frustum
    '    float closestDepth = texture(shadowMap, projCoords.xy).r;' + #10 +// Sample the depth value from the shadow map at the current pixel's XY position
    '    float currentDepth = projCoords.z;' + #10 +                       // Get the current pixel's depth from the light's perspective
    '    shadow = currentDepth - shadowBias > closestDepth ? 1.0 : 0.0;' + #10 + // If current depth is greater than closest depth (minus bias), pixel is in shadow (1.0)
    '  }' + #10 +
    '  float lightIntensity = ambient.r + (1.0 - ambient.r) * diff * (1.0 - shadow);' + #10 + // Calculate final light intensity: ambient + diffuse * shadow factor
    '  vec3 finalLight = diffuse.rgb * lightIntensity;' + #10 +            // Apply the light source's diffuse color to the calculated intensity
    '  finalColor = vec4(baseColor.rgb * finalLight, baseColor.a * vColor.a);' + #10 + // Multiply base color by final light intensity, preserve alpha for transparency
    '}';

  /// <summary>
  /// Vertex Shader for the Skybox. Removes translation from the view matrix
  /// so the skybox infinitely follows the camera.
  /// </summary>
  SKYBOX_VERT: AnsiString =
    '#version 330' + #10 +
    'in vec3 vertexPosition;' + #10 +        // Input: local vertex position
    'out vec3 fragPosition;' + #10 +         // Output: direction vector to fragment shader
    'uniform mat4 projection;' + #10 +       // Uniform: camera projection matrix
    'uniform mat4 view;' + #10 +             // Uniform: camera view matrix
    'void main()' + #10 +
    '{' + #10 +
    '  fragPosition = vertexPosition;' + #10 +                              // Pass local position as direction vector to fragment shader
    '  mat4 rotView = mat4(mat3(view));' + #10 +                            // Convert view matrix to mat3 (removes translation) and back to mat4 (keeps only rotation)
    '  vec4 clipPos = projection * rotView * vec4(vertexPosition, 1.0);' + #10 + // Calculate clip position using rotation-only view matrix
    '  gl_Position = clipPos.xyww;' + #10 +                                 // Set Z coordinate to W (1.0 after perspective divide) to force maximum depth (background)
    '}';

  /// <summary>
  /// Fragment Shader for the Skybox. Generates a procedural gradient sky
  /// that transitions between day and night colors based on a 'daytime' uniform.
  /// </summary>
  SKYBOX_FRAG: AnsiString =
    '#version 330' + #10 +
    'in vec3 fragPosition;' + #10 +          // Input: direction vector from vertex shader
    'uniform float daytime;' + #10 +         // Uniform: time of day factor (0.0 = night, 1.0 = day)
    'out vec4 finalColor;' + #10 +           // Output: final sky pixel color
    'void main()' + #10 +
    '{' + #10 +
    '  vec3 dir = normalize(fragPosition);' + #10 +                         // Normalize the direction vector
    '  float t = dir.y * 0.5 + 0.5;' + #10 +                                // Calculate a gradient factor 't' based on Y direction (0.0 at bottom, 1.0 at top)
    '  vec3 horizonColor = mix(vec3(0.8, 0.4, 0.1), vec3(0.2, 0.4, 0.8), smoothstep(0.0, 0.3, daytime));' + #10 + // Mix sunset orange and day blue for horizon based on daytime
    '  vec3 zenithColor = mix(vec3(0.05, 0.05, 0.1), vec3(0.0, 0.4, 0.9), smoothstep(0.0, 0.5, daytime));' + #10 + // Mix night dark blue and day bright blue for zenith based on daytime
    '  vec3 skyColor = mix(horizonColor, zenithColor, smoothstep(0.0, 0.4, t));' + #10 + // Blend horizon and zenith colors based on the vertical gradient 't'
    '  finalColor = vec4(skyColor, 1.0);' + #10 +                           // Output the final sky color with full opacity
    '}';

  /// <summary>
  /// Vertex Shader for scrolling clouds. Simple pass-through for UVs and position.
  /// </summary>
  CLOUD_VERT: AnsiString =
    '#version 330' + #10 +
    'in vec3 vertexPosition;' + #10 +        // Input: local vertex position
    'in vec2 vertexTexCoord;' + #10 +        // Input: UV texture coordinates
    'out vec2 vTexCoord;' + #10 +            // Output: UV coordinates to fragment shader
    'uniform mat4 mvp;' + #10 +              // Uniform: combined Model-View-Projection matrix
    'void main()' + #10 +
    '{' + #10 +
    '  vTexCoord = vertexTexCoord;' + #10 +                                // Pass UV coordinates through to fragment shader
    '  gl_Position = mvp * vec4(vertexPosition, 1.0);' + #10 +             // Calculate final screen position
    '}';

  /// <summary>
  /// Fragment Shader for scrolling clouds. Scrolls a cloud texture over the sky
  /// and adjusts its brightness based on the time of day.
  /// </summary>
  CLOUD_FRAG: AnsiString =
    '#version 330' + #10 +
    'in vec2 vTexCoord;' + #10 +             // Input: interpolated UV coordinates
    'out vec4 finalColor;' + #10 +           // Output: final cloud pixel color
    'uniform sampler2D texture0;' + #10 +    // Uniform: cloud texture (alpha channel defines cloud shape)
    'uniform float moveFactor;' + #10 +      // Uniform: scrolling offset value (changes over time to create movement)
    'uniform float daytime;' + #10 +         // Uniform: time of day factor (0.0 = night, 1.0 = day)
    'void main()' + #10 +
    '{' + #10 +
    '  vec2 uv = vTexCoord + vec2(moveFactor, moveFactor * 0.5);' + #10 +   // Offset UVs by moveFactor to scroll the cloud texture (slower vertical scroll)
    '  vec4 cloudTex = texture(texture0, uv);' + #10 +                     // Sample the cloud texture at the scrolled UV position
    '  vec3 cloudColor = mix(vec3(0.2, 0.2, 0.2), vec3(1.0, 1.0, 1.0), daytime);' + #10 + // Lerp cloud color from dark grey (night) to white (day) based on daytime
    '  finalColor = vec4(cloudColor, cloudTex.a * 0.8);' + #10 +           // Apply cloud color and use texture alpha multiplied by 0.8 for semi-transparency
    '}';

implementation

end.
