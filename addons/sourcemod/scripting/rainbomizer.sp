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

int g_ModelPrecacheTable;
int g_SoundPrecacheTable;
char g_SearchPathId[32];

ConVar rainbomizer_search_path_id;
ConVar rainbomizer_stringtable_safety_treshold;
ConVar rainbomizer_randomize_skybox;
ConVar rainbomizer_randomize_sounds;
ConVar rainbomizer_randomize_models;
ConVar rainbomizer_randomize_playermodels;
ConVar rainbomizer_randomize_entities;

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
	
	g_ModelPrecacheTable = FindStringTable("modelprecache");
	g_SoundPrecacheTable = FindStringTable("soundprecache");
	
	RegServerCmd("rainbomizer_flushsoundcache", SrvCmd_FlushSoundCache, "Flushes the internal sound cache");
	RegServerCmd("rainbomizer_flushmodelcache", SrvCmd_FlushModelCache, "Flushes the internal model cache");
	
	HookEvent("post_inventory_application", Event_PostInventoryApplication);
	
	rainbomizer_search_path_id = CreateConVar("rainbomizer_search_path_id", "GAME", "The game path to search for assets (GAME, MOD, etc.)");
	rainbomizer_search_path_id.AddChangeHook(ConVarChanged_SearchPathId);
	rainbomizer_stringtable_safety_treshold = CreateConVar("rainbomizer_stringtable_safety_treshold", "0.9", "Stop writing to string tables when they are this full.");
	rainbomizer_randomize_skybox = CreateConVar("rainbomizer_randomize_skybox", "1", "Randomize skybox?");
	rainbomizer_randomize_sounds = CreateConVar("rainbomizer_randomize_sounds", "1", "Randomize sounds?");
	rainbomizer_randomize_models = CreateConVar("rainbomizer_randomize_models", "1", "Randomize models?");
	rainbomizer_randomize_playermodels = CreateConVar("rainbomizer_randomize_playermodels", "1", "Randomize player models?");
	rainbomizer_randomize_entities = CreateConVar("rainbomizer_randomize_entities", "1", "Randomize map entity properties?");
	
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

public void OnConfigsExecuted()
{
	rainbomizer_search_path_id.GetString(g_SearchPathId, sizeof(g_SearchPathId));
}

public void OnMapStart()
{
	// Map started or plugin has loaded, collect all currently precached files
	RebuildModelCache();
	RebuildSoundCache();
	
	if (rainbomizer_randomize_skybox.BoolValue)
	{
		DispatchKeyValue(0, "skyname", g_SkyNames[GetRandomInt(0, sizeof(g_SkyNames) - 1)]);
	}
}

void RebuildModelCache()
{
	g_ModelCache.Clear();
	
	char model[PLATFORM_MAX_PATH];
	
	int numStrings = GetStringTableNumStrings(g_ModelPrecacheTable);
	for (int i = 0; i < numStrings; i++)
	{
		ReadStringTable(g_ModelPrecacheTable, i, model, sizeof(model));
		
		char directory[PLATFORM_MAX_PATH];
		GetModelDirectory(model, directory, sizeof(directory));
		
		ArrayList models;
		if (!g_ModelCache.GetValue(directory, models))
			models = new ArrayList(PLATFORM_MAX_PATH);
		
		models.PushString(model);
		g_ModelCache.SetValue(directory, models);
	}
}

void RebuildSoundCache()
{
	g_SoundCache.Clear();
	
	char sound[PLATFORM_MAX_PATH];
	
	int numStrings = GetStringTableNumStrings(g_SoundPrecacheTable);
	for (int i = 0; i < numStrings; i++)
	{
		ReadStringTable(g_SoundPrecacheTable, i, sound, sizeof(sound));
		
		char soundPath[PLATFORM_MAX_PATH];
		strcopy(soundPath, sizeof(soundPath), sound);
		GetPreviousDirectoryPath(soundPath);
		
		char directory[PLATFORM_MAX_PATH];
		Format(directory, sizeof(directory), "sound/%s", soundPath);
		SkipSoundChars(directory, sizeof(directory));
		
		ArrayList sounds;
		if (!g_SoundCache.GetValue(directory, sounds))
			sounds = new ArrayList(PLATFORM_MAX_PATH);
		
		sounds.PushString(sound);
		g_SoundCache.SetValue(directory, sounds);
	}
}

public void OnEntityCreated(int entity, const char[] classname)
{
	if (rainbomizer_randomize_models.BoolValue)
	{
		// Check if this entity is a non-player CBaseAnimating
		if (entity > MaxClients && HasEntProp(entity, Prop_Send, "m_bClientSideAnimation"))
		{
			SDKHook(entity, SDKHook_SpawnPost, OnModelSpawned);
		}
	}
	
	if (rainbomizer_randomize_entities.BoolValue)
	{
		// Randomize light colors
		if (StrContains(classname, "light") != -1 || strcmp(classname, "env_lightglow") == 0)
		{
			SDKHook(entity, SDKHook_SpawnPost, SDKHookCB_LightSpawnPost);
		}
		
		if (strcmp(classname, "env_fog_controller") == 0)
		{
			SDKHook(entity, SDKHook_SpawnPost, SDKHookCB_FogControllerpawnPost);
		}
		
		if (strcmp(classname, "env_fog_controller") == 0)
		{
			char color[16];
			Format(color, sizeof(color), "%d %d %d", GetRandomInt(0, 255), GetRandomInt(0, 255), GetRandomInt(0, 255));
			DispatchKeyValue(entity, "fogcolor", color);
			
			Format(color, sizeof(color), "%d %d %d", GetRandomInt(0, 255), GetRandomInt(0, 255), GetRandomInt(0, 255));
			DispatchKeyValue(entity, "fogcolor2", color);
		}
	}
}

public void OnModelSpawned(int entity)
{
	char model[PLATFORM_MAX_PATH];
	GetEntPropString(entity, Prop_Data, "m_ModelName", model, sizeof(model));
	
	// Do not randomize if there is no model
	if (model[0] == '\0')
		return;
	
	char directory[PLATFORM_MAX_PATH];
	GetModelDirectory(model, directory, sizeof(directory));
	
	ArrayList models;
	
	if (!g_ModelCache.GetValue(directory, models) && !IsStringTableAlmostFull(g_ModelPrecacheTable))
	{
		models = new ArrayList(PLATFORM_MAX_PATH);
		IterateDirectoryRecursive(directory, models, IterateModels);
		
		// Add fetched models to cache
		g_ModelCache.SetValue(directory, models);
	}
	
	if (models && models.Length > 0)
	{
		if (!IsStringTableAlmostFull(g_ModelPrecacheTable))
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
			g_ModelCache.SetValue(directory, models);
			
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

bool IsSoundChar(char c)
{
	bool b;
	
	b = (c == CHAR_STREAM || c == CHAR_USERVOX || c == CHAR_SENTENCE || c == CHAR_DRYMIX || c == CHAR_OMNI);
	b = b || (c == CHAR_DOPPLER || c == CHAR_DIRECTIONAL || c == CHAR_DISTVARIANT || c == CHAR_SPATIALSTEREO || c == CHAR_FAST_PITCH);
	
	return b;
}

void SkipSoundChars(char[] sound, int len)
{
	int cnt = 0;
	
	for (int i = 0; i < len; i++)
	{
		if (!IsSoundChar(sound[i]))
			break;
		
		cnt++;
	}
	
	strcopy(sound, len, sound[cnt]);
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

void GetModelDirectory(const char[] model, char[] directory, int maxlength)
{
	strcopy(directory, maxlength, model);
	
	// For weapons and cosmetics, go back an additional directory.
	// This usually leads to all items of that class.
	if (StrContains(directory, "weapons/") != -1 || StrContains(directory, "player/items/") != -1)
		GetPreviousDirectoryPath(directory, 2);
	else
		GetPreviousDirectoryPath(directory, 1);
}

bool IsStringTableAlmostFull(int tableidx)
{
	return float(GetStringTableNumStrings(tableidx)) / float(GetStringTableMaxStrings(tableidx)) >= rainbomizer_stringtable_safety_treshold.FloatValue;
}

void IterateDirectoryRecursive(const char[] directory, ArrayList &list, FileIterator callback)
{
	// Search the directory we are trying to randomize
	DirectoryListing directoryListing = OpenDirectory(directory, true, g_SearchPathId);
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
	// No special filtering for sounds
	return true;
}

public void ConVarChanged_SearchPathId(ConVar convar, const char[] oldValue, const char[] newValue)
{
	strcopy(g_SearchPathId, sizeof(g_SearchPathId), newValue);
}

public Action NormalSoundHook(int clients[MAXPLAYERS], int &numClients, char sample[PLATFORM_MAX_PATH], int &entity, int &channel, float &volume, int &level, int &pitch, int &flags, char soundEntry[PLATFORM_MAX_PATH], int &seed)
{
	if (!rainbomizer_randomize_sounds.BoolValue)
		return Plugin_Continue;
	
	char soundPath[PLATFORM_MAX_PATH];
	strcopy(soundPath, sizeof(soundPath), sample);
	GetPreviousDirectoryPath(soundPath);
	
	char directory[PLATFORM_MAX_PATH];
	Format(directory, sizeof(directory), "sound/%s", soundPath);
	SkipSoundChars(directory, sizeof(directory));
	
	ArrayList sounds;
	
	if (!g_SoundCache.GetValue(directory, sounds) && !IsStringTableAlmostFull(g_SoundPrecacheTable))
	{
		sounds = new ArrayList(PLATFORM_MAX_PATH);
		IterateDirectoryRecursive(directory, sounds, IterateSounds);
		
		// Replace filepath with sound path and re-add any sound characters we removed
		for (int i = 0; i < sounds.Length; i++)
		{
			char file[PLATFORM_MAX_PATH];
			sounds.GetString(i, file, sizeof(file));
			ReplaceString(file, sizeof(file), directory, soundPath);
			sounds.SetString(i, file);
		}
		
		// Add fetched sounds to cache
		g_SoundCache.SetValue(directory, sounds);
	}
	
	if (sounds && sounds.Length > 0)
	{
		if (!IsStringTableAlmostFull(g_SoundPrecacheTable))
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
			g_SoundCache.SetValue(directory, sounds);
			
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

public void Event_PostInventoryApplication(Event event, const char[] name, bool dontBroadcast)
{
	if (!rainbomizer_randomize_playermodels.BoolValue)
		return;
	
	int client = GetClientOfUserId(event.GetInt("userid"));
	
	char model[PLATFORM_MAX_PATH];
	strcopy(model, sizeof(model), g_Playermodels[GetRandomInt(0, sizeof(g_Playermodels) - 1)]);
	
	Handle item = TF2Items_CreateItem(OVERRIDE_ALL | FORCE_GENERATION);
	TF2Items_SetClassname(item, "tf_wearable");
	TF2Items_SetItemIndex(item, 8938);
	TF2Items_SetQuality(item, 6);
	TF2Items_SetLevel(item, 1);
	
	int wearable = TF2Items_GiveNamedItem(client, item);
	
	delete item;
	
	SDKCall(g_SDKCallEquipWearable, client, wearable);
	
	SetEntProp(client, Prop_Send, "m_nRenderFX", 6);
	SetEntProp(wearable, Prop_Data, "m_nModelIndexOverrides", PrecacheModel(model));
	SetEntProp(wearable, Prop_Send, "m_bValidatedAttachedEntity", 1);
}

public Action SrvCmd_FlushSoundCache(int args)
{
	g_SoundCache.Clear();
	ReplyToCommand(0, "Sound cache cleared!");
}

public Action SrvCmd_FlushModelCache(int args)
{
	g_ModelCache.Clear();
	ReplyToCommand(0, "Model cache cleared!");
}

public void SDKHookCB_LightSpawnPost(int entity)
{
	if (HasEntProp(entity, Prop_Send, "m_clrRender"))
	{
		SetEntProp(entity, Prop_Send, "m_clrRender", GetRandomColorInt());
	}
}

public void SDKHookCB_FogControllerpawnPost(int entity)
{
	float fog = GetRandomFloat(500.0, 1000.0);
	SetEntPropFloat(entity, Prop_Data, "m_fog.start", fog);
	SetEntPropFloat(entity, Prop_Data, "m_fog.end", fog * GetRandomFloat(1.5, 3.0));
	SetEntPropFloat(entity, Prop_Data, "m_fog.maxdensity", GetRandomFloat());
	SetEntProp(entity, Prop_Data, "m_fog.colorPrimary", GetRandomColorInt());
	SetEntProp(entity, Prop_Data, "m_fog.colorSecondary", GetRandomColorInt());
	SetEntProp(entity, Prop_Data, "m_fog.blend", GetRandomInt(0, 1));
}

void GetRandomColor(int &r, int &g, int &b, int &a)
{
	r = GetRandomInt(0, 255);
	g = GetRandomInt(0, 255);
	b = GetRandomInt(0, 255);
	a = GetRandomInt(0, 255);
}

int GetRandomColorInt()
{
	int r, g, b, a;
	GetRandomColor(r, g, b, a);
	return Color32ToInt(r, g, b, a);
}

int Color32ToInt(int r, int g, int b, int a)
{
	return (r << 24) | (g << 16) | (b << 8) | (a);
}
