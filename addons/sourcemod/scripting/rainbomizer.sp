/*
 * Copyright (C) 2022  Mikusch
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

// Global handles
Handle g_SDKCallEquipWearable;
StringMap g_SoundCache;
StringMap g_ModelCache;
ArrayList g_BlacklistedSounds;
ArrayList g_PlayerModels;
ArrayList g_SkyNames;

// Other globals
bool g_IsEnabled;
int g_SoundPrecacheTableIdx;
int g_ModelPrecacheTableIdx;
int g_ParticleEffectNamesTableIdx;

// ConVars
ConVar rbmz_enabled;
ConVar rbmz_search_path_id;
ConVar rbmz_stringtable_safety_treshold;
ConVar rbmz_randomize_skybox;
ConVar rbmz_randomize_sounds;
ConVar rbmz_randomize_models;
ConVar rbmz_randomize_playermodels;
ConVar rbmz_randomize_entities;

public Plugin pluginInfo =
{
	name = "[TF2] Rainbomizer",
	author = "Mikusch",
	description = "A visual and auditory randomizer for Team Fortress 2",
	version = "1.0.0",
	url = "https://github.com/Mikusch/TF2.Rainbomizer"
};

public void OnPluginStart()
{
	LoadTranslations("rainbomizer.phrases");
	
	g_SoundCache = new StringMap();
	g_ModelCache = new StringMap();
	
	g_SoundPrecacheTableIdx = FindStringTable("soundprecache");
	g_ModelPrecacheTableIdx = FindStringTable("modelprecache");
	g_ParticleEffectNamesTableIdx = FindStringTable("ParticleEffectNames");
	
	RegAdminCmd("rbmz_clearsoundcache", ConCmd_ClearSoundCache, ADMFLAG_CONVARS, "Clears the sound cache.");
	RegAdminCmd("rbmz_clearmodelcache", ConCmd_ClearModelCache, ADMFLAG_CONVARS, "Clears the model cache.");
	RegAdminCmd("rbmz_rebuildsoundcache", ConCmd_RebuildSoundCache, ADMFLAG_CONVARS, "Clears the sound cache and then fully rebuilds it.");
	RegAdminCmd("rbmz_rebuildmodelcache", ConCmd_RebuildModelCache, ADMFLAG_CONVARS, "Clears the model cache and then fully rebuilds it.");
	
	rbmz_enabled = CreateConVar("rbmz_enabled", "1", "When set, the plugin will be enabled.");
	rbmz_enabled.AddChangeHook(ConVarChanged_Enabled);
	g_IsEnabled = rbmz_enabled.BoolValue;
	
	rbmz_search_path_id = CreateConVar("rbmz_search_path_id", "MOD", "The search path from gameinfo.txt used to find files.");
	rbmz_search_path_id.AddChangeHook(ConVarChanged_ClearCaches);
	rbmz_stringtable_safety_treshold = CreateConVar("rbmz_stringtable_safety_treshold", "0.75", "Stop precaching new files when string tables are this full (in %).", _, true, 0.0, true, 1.0);
	rbmz_stringtable_safety_treshold.AddChangeHook(ConVarChanged_ClearCaches);
	rbmz_randomize_skybox = CreateConVar("rbmz_randomize_skybox", "1", "When set, the skybox texture will be randomized.");
	rbmz_randomize_sounds = CreateConVar("rbmz_randomize_sounds", "1", "When set, sounds will be randomized.");
	rbmz_randomize_sounds.AddChangeHook(ConVarChanged_RandomizeSounds);
	rbmz_randomize_models = CreateConVar("rbmz_randomize_models", "1", "When set, models will be randomized.");
	rbmz_randomize_models.AddChangeHook(ConVarChanged_RandomizeModels);
	rbmz_randomize_playermodels = CreateConVar("rbmz_randomize_playermodels", "1", "When set, player models will be randomized.");
	rbmz_randomize_entities = CreateConVar("rbmz_randomize_entities", "1", "When set, map entity properties will be randomized.");
	
	AddNormalSoundHook(NormalSoundHook);
	
	HookEvent("post_inventory_application", Event_PostInventoryApplication);
	
	ReadFileList("configs/rainbomizer/blacklisted_sounds.cfg", g_BlacklistedSounds);
	ReadFileList("configs/rainbomizer/playermodels.cfg", g_PlayerModels);
	ReadFileList("configs/rainbomizer/skynames.cfg", g_SkyNames);
	
	GameData gamedata = new GameData("rainbomizer");
	if (!gamedata)
		SetFailState("Failed to read rainbomizer gamedata");
	
	StartPrepSDKCall(SDKCall_Player);
	if (!PrepSDKCall_SetFromConf(gamedata, SDKConf_Virtual, "CTFPlayer::EquipWearable"))
		SetFailState("Failed to create SDK call: CTFPlayer::EquipWearable");
	
	PrepSDKCall_AddParameter(SDKType_CBaseEntity, SDKPass_Pointer);
	g_SDKCallEquipWearable = EndPrepSDKCall();
	
	delete gamedata;
}

public void OnConfigsExecuted()
{
	g_IsEnabled = rbmz_enabled.BoolValue;
	
	if (!g_IsEnabled)
		return;
	
	// String tables get cleared on level start, clear our caches
	ClearAllCaches();
	RandomizeSky();
}

public void OnEntityCreated(int entity, const char[] classname)
{
	if (!g_IsEnabled)
		return;
	
	if (rbmz_randomize_models.BoolValue)
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
	
	if (rbmz_randomize_entities.BoolValue)
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
	if (!g_IsEnabled)
		return Plugin_Continue;
	
	if (!rbmz_randomize_sounds.BoolValue)
		return Plugin_Continue;
	
	char soundPath[PLATFORM_MAX_PATH], filePath[PLATFORM_MAX_PATH];
	GetSoundDirectory(sample, soundPath, sizeof(soundPath), filePath, sizeof(filePath));
	
	ArrayList sounds;
	if (!g_SoundCache.GetValue(filePath, sounds))
		CollectSounds(filePath, soundPath, sounds);
	
	if (sounds && sounds.Length > 0)
	{
		if (CanAddToStringTable(g_SoundPrecacheTableIdx))
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
				
				if (FindStringIndex(g_SoundPrecacheTableIdx, sound) == INVALID_STRING_INDEX)
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
		if (CanAddToStringTable(g_ModelPrecacheTableIdx))
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
				
				if (FindStringIndex(g_ModelPrecacheTableIdx, model) == INVALID_STRING_INDEX)
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

void RandomizeSky()
{
	if (rbmz_randomize_skybox.BoolValue && g_SkyNames.Length > 0)
	{
		char skyname[PLATFORM_MAX_PATH];
		g_SkyNames.GetString(GetRandomInt(0, g_SkyNames.Length - 1), skyname, sizeof(skyname));
		DispatchKeyValue(0, "skyname", skyname);
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

void ClearAllCaches()
{
	ClearCache(g_SoundCache);
	ClearCache(g_ModelCache);
}

int RebuildSoundCache()
{
	ClearCache(g_SoundCache);
	
	int numStrings = GetStringTableNumStrings(g_SoundPrecacheTableIdx);
	LogMessage("Rebuilding sound cache for %d string table entries...", numStrings);
	
	int total = 0;
	
	for (int i = 0; i < numStrings; i++)
	{
		char sound[PLATFORM_MAX_PATH];
		if (!GetStringTableEntry(g_SoundPrecacheTableIdx, i, sound, sizeof(sound)))
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
				LogMessage("Found %d files for: %s", count, filePath);
			}
		}
	}
	
	LogMessage("Sound cache has been rebuilt with %d files.", total);
	return total;
}

int RebuildModelCache()
{
	ClearCache(g_ModelCache);
	
	int numStrings = GetStringTableNumStrings(g_ModelPrecacheTableIdx);
	LogMessage("Rebuilding model cache for %d string table entries...", numStrings);
	
	int total = 0;
	
	for (int i = 0; i < numStrings; i++)
	{
		char model[PLATFORM_MAX_PATH];
		if (!GetStringTableEntry(g_ModelPrecacheTableIdx, i, model, sizeof(model)))
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
				LogMessage("Found %d files for: %s", count, filePath);
			}
		}
	}
	
	LogMessage("Model cache has been rebuilt with %d files.", total);
	return total;
}

int CollectSounds(const char[] directory, const char[] soundPath, ArrayList &sounds)
{
	sounds = new ArrayList(PLATFORM_MAX_PATH);
	IterateDirectoryRecursive(directory, sounds, IterateSounds);
	
	char file[PLATFORM_MAX_PATH];
	
	// Replace filepath with sound path and re-add any sound characters we removed
	for (int j = 0; j < sounds.Length; j++)
	{
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
	return float(num) / float(max) < rbmz_stringtable_safety_treshold.FloatValue;
}

void IterateDirectoryRecursive(const char[] directory, ArrayList &list, FileIterator callback)
{
	// Grab path ID
	char pathId[16];
	rbmz_search_path_id.GetString(pathId, sizeof(pathId));
	
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

void ReadFileList(const char[] file, ArrayList &list)
{
	list = new ArrayList(PLATFORM_MAX_PATH);
	
	// Build path
	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), file);
	
	// Iterate file list
	KeyValues kv = new KeyValues("Files");
	if (kv.ImportFromFile(path))
	{
		if (kv.GotoFirstSubKey(false))
		{
			do
			{
				char sound[PLATFORM_MAX_PATH];
				kv.GetString(NULL_STRING, sound, sizeof(sound));
				list.PushString(sound);
			}
			while (kv.GotoNextKey(false));
			kv.GoBack();
		}
		kv.GoBack();
	}
	else
	{
		LogError("Failed to find configuration file %s", file);
	}
	delete kv;
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
	
	// Exclude festivizers because they pollute weapon randomization
	if (StrContains(file, "festivizer") != -1 || StrContains(file, "xmas") != -1 || StrContains(file, "xms") != -1)
		return false;
	
	return true;
}

public bool IterateSounds(const char[] file)
{
	// Remove "sound/" prefix
	char copy[PLATFORM_MAX_PATH];
	strcopy(copy, sizeof(copy), file[6]);
	
	// Exclude robot vo because it pollutes voice line randomization
	if (strncmp(copy, "vo/mvm/", 7) == 0)
		return false;
	
	// Filter blacklisted sounds (usually endless loops)
	if (g_BlacklistedSounds.FindString(copy) != -1)
		return false;
	
	return true;
}

public void Event_PostInventoryApplication(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_IsEnabled)
		return;
	
	if (!rbmz_randomize_playermodels.BoolValue || g_PlayerModels.Length == 0)
		return;
	
	int client = GetClientOfUserId(event.GetInt("userid"));
	
	char model[PLATFORM_MAX_PATH];
	g_PlayerModels.GetString(GetRandomInt(0, g_PlayerModels.Length - 1), model, sizeof(model));
	
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

public void ConVarChanged_Enabled(ConVar convar, const char[] oldValue, const char[] newValue)
{
	g_IsEnabled = convar.BoolValue;
	
	if (!g_IsEnabled)
		ClearAllCaches();
	
	// Restart the round to reset entities
	ServerCommand("mp_restartgame_immediate 1");
}

public void ConVarChanged_ClearCaches(ConVar convar, const char[] oldValue, const char[] newValue)
{
	ClearAllCaches();
}

public void ConVarChanged_RandomizeSounds(ConVar convar, const char[] oldValue, const char[] newValue)
{
	if (!convar.BoolValue)
	{
		ClearCache(g_SoundCache);
	}
}

public void ConVarChanged_RandomizeModels(ConVar convar, const char[] oldValue, const char[] newValue)
{
	if (!convar.BoolValue)
	{
		ClearCache(g_ModelCache);
	}
}

public Action ConCmd_ClearSoundCache(int client, int args)
{
	ClearCache(g_SoundCache);
	ShowActivity(client, "%t", "SoundCache_Clear_Success");
	
	return Plugin_Handled;
}

public Action ConCmd_ClearModelCache(int client, int args)
{
	ClearCache(g_ModelCache);
	ShowActivity(client, "%t", "ModelCache_Clear_Success");
	
	return Plugin_Handled;
}

public Action ConCmd_RebuildSoundCache(int client, int args)
{
	int total = RebuildSoundCache();
	ShowActivity(client, "%t", "SoundCache_Rebuild_Success", total);
	
	return Plugin_Handled;
}

public Action ConCmd_RebuildModelCache(int client, int args)
{
	int total = RebuildModelCache();
	ShowActivity(client, "%t", "ModelCache_Rebuild_Success", total);
	
	return Plugin_Handled;
}

public void SDKHookCB_LightSpawnPost(int entity)
{
	SetEntProp(entity, Prop_Send, "m_clrRender", GetRandomColorInt());
}

public void SDKHookCB_FogControllerSpawnPost(int entity)
{
	SetEntProp(entity, Prop_Data, "m_fog.colorPrimary", GetRandomColorInt());
	SetEntProp(entity, Prop_Data, "m_fog.colorSecondary", GetRandomColorInt());
	SetEntProp(entity, Prop_Data, "m_fog.blend", true);
}

public void SDKHookCB_ShadowControlSpawnPost(int entity)
{
	SetEntProp(entity, Prop_Data, "m_shadowColor", GetRandomColorInt());
}

public void SDKHookCB_ParticleSystemSpawnPost(int entity)
{
	int num = GetStringTableNumStrings(g_ParticleEffectNamesTableIdx);
	int stringidx = GetRandomInt(0, num - 1);
	
	char effectName[PLATFORM_MAX_PATH];
	if (GetStringTableEntry(g_ParticleEffectNamesTableIdx, stringidx, effectName, sizeof(effectName)))
	{
		SetEntPropString(entity, Prop_Data, "m_iszEffectName", effectName);
	}
}
