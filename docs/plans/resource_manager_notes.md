# Resource Manager for OpenGL resources

## Gl resources by Object
- Shaders
  - id
- Textures
  - gl_texture_id
- Shapes
  - vao
  - vbo
  - ebo
  - color_vbo
- MeshPrimatives
  - vao
  - vbo_positions
  - vbo_normals
  - vbo_texcoords
  - vbo_tangents
  - vbo_colors
  - vbo_joints
  - vbo_weights
  - ebo_indices
- GltfAsset
  - loaded_textures - hashmap of textures

- Model
  - gltf_asset
    - load_textures
      - hashmap of Textures
  - meshes
    - primitives 
       - list of MeshPrimitives
         - deleteGlObjects() 

## Implementation Options
- 1. Object passed by pointer at init
  - init changes to taking a config with allocator and ?*pointer to resource manager
  - if not null, call register api with type, and it will know how to find the gl resource in the type and add them 
    to the right resource list
- 2. Object called after init
  - Same behavior just it's a call done by the resource user on create, such as the scene
- 3. Service Object
  - has a wrapper function for each type of object that can be created
  - Ok for some object, poor for other because more maintenance overhead with function signatures

### Option 2 
- is probably the best with the least changes to the other objects. Easy to extend.
- Each object that creates GL resources should have a deleteGl() function to delete them. 
- The resource manager then 
  - has a Resource type interface with a deleteGl() dispatch function
  - has a list of Resource types that are added when by the creator of the different resources types
          
### Notes
- Added deleteGlResources() to all types that acquire GL objects
- Created a ResourceManager with an interface type Resources 
  - Enables adding different resource types to the same resource list
  - Calls deleteGlResources on those types
- The questions is as it currently stands 
  - it really doesn't provide anything more then scene calling deleteGlObject on each loaded object like the doing 
    deinit.
  - Requires each scene object to add the resources it creates one by one to the ResourceManager by call add on each 
    object.
- A solution to make it more useful would be to make the resource manager a wrapper class that has an api to create all 
  the GL types such as shaders, textures, shapes, models
- Doing that would make it a single place to find all the create functions and it would also handle resource clean up 
  and over time we could added other functionality like reference counting resources and coordinating scene changes.