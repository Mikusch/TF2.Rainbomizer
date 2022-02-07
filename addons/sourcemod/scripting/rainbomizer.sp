/*
 * Copyright (C) 2021  Mikusch
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

#include <sourcemod>
#include <sdkhooks>
#include <sdktools>
#include <tf2items>

#pragma newdecls required
#pragma semicolon 1

#define CHAR_STREAM			'*'		// as one of 1st 2 chars in name, indicates streaming wav data
#define CHAR_USERVOX		'?'		// as one of 1st 2 chars in name, indicates user realtime voice data
#define CHAR_SENTENCE		'!'		// as one of 1st 2 chars in name, indicates sentence wav
#define CHAR_DRYMIX			'#'		// as one of 1st 2 chars in name, indicates wav bypasses dsp fx
#define CHAR_DOPPLER		'>'		// as one of 1st 2 chars in name, indicates doppler encoded stereo wav: left wav (incomming) and right wav (outgoing).
#define CHAR_DIRECTIONAL	'<'		// as one of 1st 2 chars in name, indicates stereo wav has direction cone: mix left wav (front facing) with right wav (rear facing) based on soundfacing direction
#define CHAR_DISTVARIANT	'^'		// as one of 1st 2 chars in name, indicates distance variant encoded stereo wav (left is close, right is far)
#define CHAR_OMNI			'@'		// as one of 1st 2 chars in name, indicates non-directional wav (default mono or stereo)
#define CHAR_SPATIALSTEREO	')'		// as one of 1st 2 chars in name, indicates spatialized stereo wav
#define CHAR_FAST_PITCH		'}'		// as one of 1st 2 chars in name, forces low quality, non-interpolated pitch shift

typeset FileIterator
{
	function bool(const char[] file);
}

char g_Playermodels[][] =
{
	"models/bots/headless_hatman.mdl",
	"models/bots/skeleton_sniper/skeleton_sniper.mdl",
	"models/bots/skeleton_sniper_boss/skeleton_sniper_boss.mdl",
	"models/bots/merasmus/merasmus.mdl",
	"models/bots/demo/bot_demo.mdl",
	"models/bots/demo/bot_sentry_buster.mdl",
	"models/bots/engineer/bot_engineer.mdl",
	"models/bots/heavy/bot_heavy.mdl",
	"models/bots/medic/bot_medic.mdl",
	"models/bots/pyro/bot_pyro.mdl",
	"models/bots/scout/bot_scout.mdl",
	"models/bots/sniper/bot_sniper.mdl",
	"models/bots/soldier/bot_soldier.mdl",
	"models/bots/spy/bot_spy.mdl",
	"models/player/demo.mdl",
	"models/player/engineer.mdl",
	"models/player/heavy.mdl",
	"models/player/medic.mdl",
	"models/player/pyro.mdl",
	"models/player/scout.mdl",
	"models/player/sniper.mdl",
	"models/player/soldier.mdl",
	"models/player/spy.mdl",
	"models/player/items/taunts/yeti/yeti.mdl",
};

// Skybox names (excluding Pyrovision skyboxes)
char g_SkyNames[][] =
{
	"sky_alpinestorm_01",
	"sky_badlands_01",
	"sky_dustbowl_01",
	"sky_goldrush_01",
	"sky_granary_01",
	"sky_gravel_01",
	"sky_halloween",
	"sky_halloween_night2014_01",
	"sky_halloween_night_01",
	"sky_harvest_01",
	"sky_harvest_night_01",
	"sky_hydro_01",
	"sky_island_01",
	"sky_morningsnow_01",
	"sky_night_01",
	"sky_nightfall_01",
	"sky_rainbow_01",
	"sky_stormfront_01",
	"sky_tf2_04",
	"sky_trainyard_01",
	"sky_upward",
	"sky_well_01",
};

Handle g_SDKCallEquipWearable;
StringMap g_SoundCache;
StringMap g_ModelCache;

int g_SoundPrecacheTable;
int g_ModelPrecacheTable;
int g_ParticleEffectNamesTable;

ConVar rbm_search_path_id;
ConVar rbm_stringtable_safety_treshold;
ConVar rbm_randomize_skybox;
ConVar rbm_randomize_sounds;
ConVar rbm_randomize_models;
ConVar rbm_randomize_playermodels;
ConVar rbm_randomize_entities;

public Plugin pluginInfo =
{
	name = "[TF2] Rainbomizer",
	author = "Mikusch",
	description = "A visual randomizer for Team Fortress 2",
	version = "1.0.0",
	url = "https://github.com/Mikusch/TF2.Rainbomizer"
};

public void OnPluginStart()
{
	g_SoundCache = new StringMap();
	g_ModelCache = new StringMap();
	
	g_SoundPrecacheTable = FindStringTable("soundprecache");
	g_ModelPrecacheTable = FindStringTable("modelprecache");
	g_ParticleEffectNamesTable = FindStringTable("ParticleEffectNames");
	
	RegAdminCmd("rbm_clearsoundcache", ConCmd_ClearSoundCache, ADMFLAG_GENERIC, "Clears the internal sound cache");
	RegAdminCmd("rbm_clearmodelcache", ConCmd_ClearModelCache, ADMFLAG_GENERIC, "Clears the internal model cache");
	RegAdminCmd("rbm_rebuildsoundcache", ConCmd_RebuildSoundCache, ADMFLAG_ROOT, "Rebuilds the internal sound cache (WARNING: This might hang or crash the server)");
	RegAdminCmd("rbm_rebuildmodelcache", ConCmd_RebuildModelCache, ADMFLAG_ROOT, "Rebuilds the internal model cache (WARNING: This might hang or crash the server)");
	
	HookEvent("post_inventory_application", Event_PostInventoryApplication);
	
	rbm_search_path_id = CreateConVar("rbm_search_path_id", "MOD", "The search path from gameinfo.txt used to find files.");
	rbm_stringtable_safety_treshold = CreateConVar("rbm_stringtable_safety_treshold", "0.95", "Stop precaching files when string tables are this full (in percent). Setting this to 0 will disable precaching of new assets.", _, true, 0.0, true, 1.0);
	rbm_randomize_skybox = CreateConVar("rbm_randomize_skybox", "1", "Whether to randomize the skybox texture.");
	rbm_randomize_sounds = CreateConVar("rbm_randomize_sounds", "1", "Whether to randomize sounds.");
	rbm_randomize_models = CreateConVar("rbm_randomize_models", "1", "Whether to randomize models");
	rbm_randomize_playermodels = CreateConVar("rbm_randomize_playermodels", "1", "Randomize player models?");
	rbm_randomize_entities = CreateConVar("rbm_randomize_entities", "1", "Whether to randomize map entity properties such as light and fog color.");
	
	AddNormalSoundHook(NormalSoundHook);
	
	GameData gamedata = new GameData("rainbomizer");
	if (gamedata)
	{
		StartPrepSDKCall(SDKCall_Player);
		if (PrepSDKCall_SetFromConf(gamedata, SDKConf_Virtual, "CTFPlayer::EquipWearable"))
		{
			PrepSDKCall_AddParameter(SDKType_CBaseEntity, SDKPass_Pointer);
			g_SDKCallEquipWearable = EndPrepSDKCall();
		}
		else
		{
			SetFailState("Failed to create SDK call: CTFPlayer::EquipWearable");
		}
		
		delete gamedata;
	}
	else
	{
		SetFailState("Failed to read rainbomizer gamedata");
	}
}

public void OnMapStart()
{
	// String tables get cleared on level start, clear our cache
	ClearCache(g_SoundCache);
	ClearCache(g_ModelCache);
	
	if (rbm_randomize_skybox.BoolValue)
	{
		DispatchKeyValue(0, "skyname", g_SkyNames[GetRandomInt(0, sizeof(g_SkyNames) - 1)]);
	}
}

public void OnEntityCreated(int entity, const char[] classname)
{
	if (rbm_randomize_models.BoolValue)
	{
		// Check if this entity is a non-player CBaseAnimating
		if (entity > MaxClients && HasEntProp(entity, Prop_Send, "m_bClientSideAnimation"))
		{
			SDKHook(entity, SDKHook_SpawnPost, SDKHookCB_ModelEntitySpawnPost);
		}
		
		// Allows random cosmetics to be visible
		if (HasEntProp(entity, Prop_Send, "m_bValidatedAttachedEntity"))
		{
			SetEntProp(entity, Prop_Send, "m_bValidatedAttachedEntity", true);
		}
	}
	
	if (rbm_randomize_entities.BoolValue)
	{
		// Randomize light colors
		if (StrContains(classname, "light") != -1 || StrEqual(classname, "env_lightglow"))
		{
			SDKHook(entity, SDKHook_SpawnPost, SDKHookCB_LightSpawnPost);
		}
		
		if (StrEqual(classname, "env_fog_controller"))
		{
			SDKHook(entity, SDKHook_SpawnPost, SDKHookCB_FogControllerSpawnPost);
		}
		
		if (StrEqual(classname, "env_fog_controller"))
		{
			char color[16];
			Format(color, sizeof(color), "%d %d %d", GetRandomInt(0, 255), GetRandomInt(0, 255), GetRandomInt(0, 255));
			DispatchKeyValue(entity, "fogcolor", color);
			
			Format(color, sizeof(color), "%d %d %d", GetRandomInt(0, 255), GetRandomInt(0, 255), GetRandomInt(0, 255));
			DispatchKeyValue(entity, "fogcolor2", color);
		}
		
		if (StrEqual(classname, "shadow_control"))
		{
			SDKHook(entity, SDKHook_SpawnPost, SDKHookCB_ShadowControlSpawnPost);
		}
		
		if (StrEqual(classname, "info_particle_system"))
		{
			SDKHook(entity, SDKHook_SpawnPost, SDKHookCB_ParticleSystemSpawnPost);
		}
	}
}

public Action NormalSoundHook(int clients[MAXPLAYERS], int &numClients, char sample[PLATFORM_MAX_PATH], int &entity, int &channel, float &volume, int &level, int &pitch, int &flags, char soundEntry[PLATFORM_MAX_PATH], int &seed)
{
	if (!rbm_randomize_sounds.BoolValue)
		return Plugin_Continue;
	
	char soundPath[PLATFORM_MAX_PATH], filePath[PLATFORM_MAX_PATH];
	GetSoundDirectory(sample, soundPath, sizeof(soundPath), filePath, sizeof(filePath));
	
	ArrayList sounds;
	if (!g_SoundCache.GetValue(filePath, sounds))
		CollectSounds(filePath, soundPath, sounds);
	
	if (sounds && sounds.Length > 0)
	{
		if (CanAddToStringTable(g_SoundPrecacheTable))
		{
			sounds.GetString(GetRandomInt(0, sounds.Length - 1), sample, sizeof(sample));
			PrecacheSound(sample);
			return Plugin_Changed;
		}
		else
		{
			char sound[PLATFORM_MAX_PATH];
			
			// Remove non-precached entries from our cache
			for (int i = 0; i < sounds.Length; i++)
			{
				sounds.GetString(i, sound, sizeof(sound));
				
				if (FindStringIndex(g_SoundPrecacheTable, sound) == INVALID_STRING_INDEX)
					sounds.Erase(i--);
			}
			
			// Update our cache
			g_SoundCache.SetValue(filePath, sounds);
			
			if (sounds.Length > 0)
			{
				// Fetch random string from updated cache
				sounds.GetString(GetRandomInt(0, sounds.Length - 1), sound, sizeof(sound));
				strcopy(sample, sizeof(sample), sound);
				return Plugin_Changed;
			}
		}
	}
	
	return Plugin_Continue;
}

public void SDKHookCB_ModelEntitySpawnPost(int entity)
{
	char model[PLATFORM_MAX_PATH];
	GetEntPropString(entity, Prop_Data, "m_ModelName", model, sizeof(model));
	
	// Do not randomize if there is no model
	if (model[0] == '\0')
		return;
	
	char filePath[PLATFORM_MAX_PATH];
	GetModelDirectory(model, filePath, sizeof(filePath));
	
	ArrayList models;
	if (!g_ModelCache.GetValue(filePath, models))
		CollectModels(filePath, models);
	
	if (models && models.Length > 0)
	{
		if (CanAddToStringTable(g_ModelPrecacheTable))
		{
			models.GetString(GetRandomInt(0, models.Length - 1), model, sizeof(model));
			
			int index = PrecacheModel(model);
			SetEntProp(entity, Prop_Data, "m_nModelIndexOverrides", index);
			SetEntProp(entity, Prop_Data, "m_nModelIndex", index);
		}
		else
		{
			// Remove non-precached entries from our cache
			for (int i = 0; i < models.Length; i++)
			{
				models.GetString(i, model, sizeof(model));
				
				if (FindStringIndex(g_ModelPrecacheTable, model) == INVALID_STRING_INDEX)
					models.Erase(i--);
			}
			
			// Update our cache
			g_ModelCache.SetValue(filePath, models);
			
			if (models.Length > 0)
			{
				// Fetch random string from updated cache
				models.GetString(GetRandomInt(0, models.Length - 1), model, sizeof(model));
				
				int index = PrecacheModel(model);
				SetEntProp(entity, Prop_Data, "m_nModelIndexOverrides", index);
				SetEntProp(entity, Prop_Data, "m_nModelIndex", index);
			}
		}
	}
}

void ClearCache(StringMap cache)
{
	// Delete all contained lists in the map
	StringMapSnapshot snapshot = cache.Snapshot();
	for (int i = 0; i < snapshot.Length; i++)
	{
		int size = snapshot.KeyBufferSize(i);
		char[] key = new char[size];
		snapshot.GetKey(i, key, size);
		
		ArrayList list;
		if (cache.GetValue(key, list))
			delete list;
	}
	delete snapshot;
	
	// Finally, clear the cache map
	cache.Clear();
}

int RebuildSoundCache()
{
	ClearCache(g_SoundCache);
	
	int numStrings = GetStringTableNumStrings(g_SoundPrecacheTable);
	LogMessage("Rebuilding sound cache for %d string table entries", numStrings);
	
	int total = 0;
	
	for (int i = 0; i < numStrings; i++)
	{
		char sound[PLATFORM_MAX_PATH];
		if (!GetStringTableEntry(g_SoundPrecacheTable, i, sound, sizeof(sound)))
			continue;
		
		char soundPath[PLATFORM_MAX_PATH], filePath[PLATFORM_MAX_PATH];
		GetSoundDirectory(sound, soundPath, sizeof(soundPath), filePath, sizeof(filePath));
		
		ArrayList sounds;
		if (!g_SoundCache.GetValue(filePath, sounds))
		{
			int count = CollectSounds(filePath, soundPath, sounds);
			if (count > 0)
			{
				total += count;
				LogMessage("Collected %d file(s) for %s", count, filePath);
			}
		}
	}
	
	LogMessage("Successfully rebuilt sound cache with %d file(s)", total);
	return total;
}

int RebuildModelCache()
{
	ClearCache(g_ModelCache);
	
	int numStrings = GetStringTableNumStrings(g_ModelPrecacheTable);
	LogMessage("Rebuilding model cache for %d string table entries", numStrings);
	
	int total = 0;
	
	for (int i = 0; i < numStrings; i++)
	{
		char model[PLATFORM_MAX_PATH];
		if (!GetStringTableEntry(g_ModelPrecacheTable, i, model, sizeof(model)))
			continue;
		
		// Ignore non-studio models
		if (StrContains(model, ".mdl") == -1)
			continue;
		
		char filePath[PLATFORM_MAX_PATH];
		GetModelDirectory(model, filePath, sizeof(filePath));
		
		// Do not scan models/ for files to avoid stack overflows
		if (StrEqual(filePath, "models"))
			continue;
		
		ArrayList models;
		if (!g_ModelCache.GetValue(filePath, models))
		{
			int count = CollectModels(filePath, models);
			if (count > 0)
			{
				total += count;
				LogMessage("Collected %d file(s) for %s", count, filePath);
			}
		}
	}
	
	LogMessage("Successfully rebuilt model cache with %d file(s)", total);
	return total;
}

int CollectSounds(const char[] directory, const char[] soundPath, ArrayList &sounds)
{
	sounds = new ArrayList(PLATFORM_MAX_PATH);
	IterateDirectoryRecursive(directory, sounds, IterateSounds);
	
	// Replace filepath with sound path and re-add any sound characters we removed
	for (int j = 0; j < sounds.Length; j++)
	{
		char file[PLATFORM_MAX_PATH];
		sounds.GetString(j, file, sizeof(file));
		ReplaceString(file, sizeof(file), directory, soundPath);
		sounds.SetString(j, file);
	}
	
	// Add fetched sounds to cache
	g_SoundCache.SetValue(directory, sounds);
	return sounds.Length;
}

int CollectModels(const char[] directory, ArrayList &models)
{
	models = new ArrayList(PLATFORM_MAX_PATH);
	IterateDirectoryRecursive(directory, models, IterateModels);
	
	// Add fetched models to cache
	g_ModelCache.SetValue(directory, models);
	return models.Length;
}

bool GetStringTableEntry(int tableidx, int stringidx, char[] str, int maxlength)
{
	if (ReadStringTable(tableidx, stringidx, str, maxlength) > 0)
	{
		// Ignore empty entries
		if (str[0] == '\0')
			return false;
		
		// Fix up Windows paths
		ReplaceString(str, maxlength, "\\", "/");
		
		return true;
	}
	
	return false;
}

void GetPreviousDirectoryPath(char[] directory, int levels = 1)
{
	for (int i = 0; i < levels; i++)
	{
		int pos = FindCharInString(directory, '/', true);
		
		if (pos != -1)
			strcopy(directory, pos + 1, directory);
	}
}

void GetModelDirectory(const char[] model, char[] buffer, int size)
{
	strcopy(buffer, size, model);
	
	// Weapons and cosmetics usually reside in their own subfolders, so go back two levels
	// For everything else, go up one level
	if (StrContains(buffer, "weapons/") != -1 || StrContains(buffer, "player/items/") != -1)
		GetPreviousDirectoryPath(buffer, 2);
	else
		GetPreviousDirectoryPath(buffer, 1);
}

void GetSoundDirectory(const char[] sound, char[] soundPathBuffer, int soundPathLength, char[] filePathBuffer, int filePathLength)
{
	// For sounds, we generally just go up one level
	strcopy(soundPathBuffer, soundPathLength, sound);
	GetPreviousDirectoryPath(soundPathBuffer);
	
	// Remove sound chars and prepend "sound/"
	strcopy(filePathBuffer, filePathLength, soundPathBuffer);
	SkipSoundChars(filePathBuffer, filePathBuffer, filePathLength);
	Format(filePathBuffer, filePathLength, "sound/%s", filePathBuffer);
}

bool CanAddToStringTable(int tableidx)
{
	// If the string table is getting full, do not add to it
	int num = GetStringTableNumStrings(tableidx);
	int max = GetStringTableMaxStrings(tableidx);
	return float(num) / float(max) < rbm_stringtable_safety_treshold.FloatValue;
}

void IterateDirectoryRecursive(const char[] directory, ArrayList &list, FileIterator callback)
{
	// Grab path ID
	char pathId[16];
	rbm_search_path_id.GetString(pathId, sizeof(pathId));
	
	// Search the directory we are trying to randomize
	DirectoryListing directoryListing = OpenDirectory(directory, true, pathId);
	if (!directoryListing)
		return;
	
	char file[PLATFORM_MAX_PATH];
	FileType type;
	while (directoryListing.GetNext(file, sizeof(file), type))
	{
		Format(file, sizeof(file), "%s/%s", directory, file);
		
		switch (type)
		{
			case FileType_Directory:
			{
				// Collect files in subfolders too
				IterateDirectoryRecursive(file, list, callback);
			}
			case FileType_File:
			{
				// Call iterator function
				Call_StartFunction(null, callback);
				Call_PushString(file);
				
				bool result;
				if (Call_Finish(result) == SP_ERROR_NONE && !result)
					continue;
				
				list.PushString(file);
			}
		}
	}
	
	delete directoryListing;
}

stock bool IsSoundChar(char c)
{
	bool b;
	
	b = (c == CHAR_STREAM || c == CHAR_USERVOX || c == CHAR_SENTENCE || c == CHAR_DRYMIX || c == CHAR_OMNI);
	b = b || (c == CHAR_DOPPLER || c == CHAR_DIRECTIONAL || c == CHAR_DISTVARIANT || c == CHAR_SPATIALSTEREO || c == CHAR_FAST_PITCH);
	
	return b;
}

stock void SkipSoundChars(const char[] sound, char[] buffer, int size)
{
	int cnt = 0;
	
	for (int i = 0; i < size; i++)
	{
		if (!IsSoundChar(sound[i]))
			break;
		
		cnt++;
	}
	
	strcopy(buffer, size, sound[cnt]);
}

stock void GetRandomColorRGB(int &r, int &g, int &b, int &a)
{
	r = GetRandomInt(0, 255);
	g = GetRandomInt(0, 255);
	b = GetRandomInt(0, 255);
	a = GetRandomInt(0, 255);
}

stock int GetRandomColorInt()
{
	int r, g, b, a;
	GetRandomColorRGB(r, g, b, a);
	return Color32ToInt(r, g, b, a);
}

stock int Color32ToInt(int r, int g, int b, int a)
{
	return (r << 24) | (g << 16) | (b << 8) | (a);
}

public bool IterateModels(const char[] file)
{
	// Only allow studio models
	if (StrContains(file, ".mdl") == -1)
		return false;
	
	// Exclude all kinds of festivizers
	if (StrContains(file, "festivizer") != -1 || StrContains(file, "xms") != -1 || StrContains(file, "xmas") != -1)
		return false;
	
	return true;
}

public bool IterateSounds(const char[] file)
{
	// Filters a few looping sounds
	if (StrContains(file, "loop") != -1)
		return false;
	
	return true;
}

public void Event_PostInventoryApplication(Event event, const char[] name, bool dontBroadcast)
{
	if (!rbm_randomize_playermodels.BoolValue)
		return;
	
	int client = GetClientOfUserId(event.GetInt("userid"));
	
	char model[PLATFORM_MAX_PATH];
	strcopy(model, sizeof(model), g_Playermodels[GetRandomInt(0, sizeof(g_Playermodels) - 1)]);
	
	Handle item = TF2Items_CreateItem(OVERRIDE_ALL | FORCE_GENERATION);
	TF2Items_SetClassname(item, "tf_wearable");
	TF2Items_SetItemIndex(item, 8938);
	TF2Items_SetLevel(item, GetRandomInt(1, 100));
	
	int wearable = TF2Items_GiveNamedItem(client, item);
	
	delete item;
	
	SDKCall(g_SDKCallEquipWearable, client, wearable);
	
	SetEntProp(client, Prop_Send, "m_nRenderFX", 6);
	SetEntProp(wearable, Prop_Data, "m_nModelIndexOverrides", PrecacheModel(model));
	SetEntProp(wearable, Prop_Send, "m_bValidatedAttachedEntity", true);
}

public Action ConCmd_ClearSoundCache(int client, int args)
{
	ClearCache(g_SoundCache);
	ShowActivity(client, "Cleared sound cache");
}

public Action ConCmd_ClearModelCache(int client, int args)
{
	ClearCache(g_ModelCache);
	ShowActivity(client, "Cleared model cache");
}

public Action ConCmd_RebuildSoundCache(int client, int args)
{
	int total = RebuildSoundCache();
	ShowActivity(client, "Rebuilt sound cache with %d file(s)", total);
}

public Action ConCmd_RebuildModelCache(int client, int args)
{
	int total = RebuildModelCache();
	ShowActivity(client, "Rebuilt model cache with %d file(s)", total);
}

public void SDKHookCB_LightSpawnPost(int entity)
{
	if (HasEntProp(entity, Prop_Send, "m_clrRender"))
	{
		SetEntProp(entity, Prop_Send, "m_clrRender", GetRandomColorInt());
	}
}

public void SDKHookCB_FogControllerSpawnPost(int entity)
{
	SetEntProp(entity, Prop_Data, "m_fog.colorPrimary", GetRandomColorInt());
	SetEntProp(entity, Prop_Data, "m_fog.colorSecondary", GetRandomColorInt());
}

public void SDKHookCB_ShadowControlSpawnPost(int entity)
{
	SetEntProp(entity, Prop_Data, "m_shadowColor", GetRandomColorInt());
}

public void SDKHookCB_ParticleSystemSpawnPost(int entity)
{
	int num = GetStringTableNumStrings(g_ParticleEffectNamesTable);
	int stringidx = GetRandomInt(0, num - 1);
	
	char effectName[25];
	if (GetStringTableEntry(g_ParticleEffectNamesTable, stringidx, effectName, sizeof(effectName)))
	{
		SetEntPropString(entity, Prop_Data, "m_iszEffectName", effectName);
	}
}
