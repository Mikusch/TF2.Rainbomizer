# Rainbomizer: TF2 🌈

<img alt="Rainbomized plr_nightfall" src="https://user-images.githubusercontent.com/25514044/152795195-7dd74150-91ce-406f-91c9-c4f9c5b537c7.jpg" height="512"/>

A SourceMod plugin for Team Fortress 2 that randomizes various aspects of the game from sounds to models and the environment. This is purely a visual and auditory randomizer with no gameplay changes.

Inspired by [Rainbomizer: V](https://github.com/Parik27/V.Rainbomizer), a similar mod for Grand Theft Auto V with the same name.

## Features

* **💬 Voice Line Randomizer** - Randomizes voice lines spoken by players and other characters.
* **🔊 Sound Randomizer** - Randomizes all sound effects being played.
* **🎩 Cosmetic Randomizer** - Randomizes the appearance of your cosmetics.
* **🔫 Weapon Randomizer** - Randomizes the appearance of your weapons.
* **🚂 Model Randomizer** - Randomizes models of pickups, objectives, doors, and other map entities.
* **🚶 Player Model Randomizer** - Randomizes everyone's player models into different classes, robots, or Halloween bosses.
* **🌌 Skybox Randomizer** - Randomizes the look of the sky.
* **💡 Light Randomizer** - Randomizes the color of certain lights.
* **💨 Particle Randomizer** - Randomizes particles placed in the map.
* **🌫️ Fog Randomizer** - Randomizes the color of fog.
* **👥 Shadow Randomizer** - Randomizes the color of shadows.

## Configuration

* **`rbmz_enabled` (def. `1`)** - When set, the plugin will be enabled.
* **`rbmz_search_path_id` (def. `MOD`)** - The search path from gameinfo.txt used to find files.
    * When set to `GAME`, the plugin will scan all Source Engine paths. When set to `MOD`, it will only search mod-specific paths.
    * This can be useful if you want to include HL2 assets in the randomization.
* **`rbmz_stringtable_safety_treshold` (def. `0.75`)** - Stop precaching new files when string tables are this full (in %).
    * Lower value means less random models and sounds, higher value means less stability and the risk of crashing.
* **`rbmz_randomize_skybox` (def. `1`)** - When set, the skybox texture will be randomized.
* **`rbmz_randomize_sounds` (def. `1`)** - When set, sounds will be randomized.
    * This includes voice lines and miscellaneous sounds.
* **`rbmz_randomize_models` (def. `1`)** - When set, models will be randomized.
* **`rbmz_randomize_playermodels` (def. `1`)** - When set,player models will be randomized.
* **`rbmz_randomize_entities` (def. `1`)** - When set, map entity properties will be randomized.
    * This includes lights, fog controllers, and shadow controllers.

## Caching

Whenever a sound is played or a model is set to an entity, the plugin recursively searches its path for related files to randomize to. This makes the server stutter because file system operations are expensive.

To avoid the server process hanging each time, a cache is used to store discovered files. The server will still hang the first few times the plugin is discovering files, but it should recover fairly quickly.

The cache can be controlled with these commands:

* **``rbmz_clearsoundcache``** - Clears the sound cache.
* **``rbmz_clearsoundcache``** - Clears the model cache.
* **``rbmz_rebuildsoundcache``** - Clears the sound cache and then fully rebuilds it.
* **``rbmz_rebuildmodelcache``** - Clears the model cache and then fully rebuilds it.
