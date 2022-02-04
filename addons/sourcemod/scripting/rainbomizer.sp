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

typeset FileIterator
{
	function bool(const char[] file);
}

char g_Models[][] =
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
char g_SkyList[][] =
{
	"sky_dustbowl_01",
	"sky_granary_01",
	"sky_gravel_01",
	"sky_well_01",
	"sky_tf2_04",
	"sky_hydro_01",
	"sky_badlands_01",
	"sky_goldrush_01",
	"sky_trainyard_01",
	"sky_night_01",
	"sky_alpinestorm_01",
	"sky_morningsnow_01",
	"sky_nightfall_01",
	"sky_harvest_01",
	"sky_harvest_night_01",
	"sky_upward",
	"sky_stormfront_01",
	"sky_halloween",
	"sky_halloween_night_01",
	"sky_halloween_night2014_01",
	"sky_island_01",
	"sky_jungle_01",
	"sky_invasion2fort_01",
	"sky_well_02",
	"sky_outpost_01",
	"sky_coastal_01",
	"sky_midnight_01",
	"sky_midnight_02",
	"sky_volcano_01",
	"sky_day01_01",
};

Handle g_SDKCallEquipWearable;
StringMap g_SoundCache;
StringMap g_ModelCache;

int g_ModelPrecacheTable;
int g_SoundPrecacheTable;

ConVar rainbomizer_skybox;
ConVar rainbomizer_sounds;
ConVar rainbomizer_sounds_use_precache_table;
ConVar rainbomizer_models;
ConVar rainbomizer_models_use_precache_table;
ConVar rainbomizer_playermodels;
ConVar rainbomizer_entities;

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
	
	HookEvent("post_inventory_application", Event_PostInventoryApplication);
	
	RegServerCmd("rainbomizer_flushsoundcache", SrvCmd_FlushSoundCache, "Flushes the internal sound cache");
	RegServerCmd("rainbomizer_flushmodelcache", SrvCmd_FlushModelCache, "Flushes the internal model cache");
	
	rainbomizer_skybox = CreateConVar("rainbomizer_skybox", "1", "Randomize skybox?");
	rainbomizer_sounds = CreateConVar("rainbomizer_sounds", "1", "Randomize sounds?");
	rainbomizer_sounds_use_precache_table = CreateConVar("rainbomizer_sounds_use_precache_table", "0", "Whether to use the sound precache table for randomization (better performance, worse randomization)");
	rainbomizer_models = CreateConVar("rainbomizer_models", "1", "Randomize models?");
	rainbomizer_models_use_precache_table = CreateConVar("rainbomizer_models_use_precache_table", "0", "Whether to use the model precache table for randomization (better performance, worse randomization)");
	rainbomizer_playermodels = CreateConVar("rainbomizer_playermodels", "1", "Randomize player models?");
	rainbomizer_entities = CreateConVar("rainbomizer_entities", "1", "Randomize map entity properties?");
	
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
	if (rainbomizer_skybox.BoolValue)
	{
		DispatchKeyValue(0, "skyname", g_SkyList[GetRandomInt(0, sizeof(g_SkyList) - 1)]);
	}
}

public void OnEntityCreated(int entity, const char[] classname)
{
	if (rainbomizer_models.BoolValue)
	{
		// Check if this entity is a non-player CBaseAnimating
		if (entity > MaxClients && HasEntProp(entity, Prop_Send, "m_bClientSideAnimation"))
		{
			SDKHook(entity, SDKHook_SpawnPost, OnModelSpawned);
		}
	}
	
	if (rainbomizer_entities.BoolValue)
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
	int numStrings = GetStringTableNumStrings(g_ModelPrecacheTable);
	
	char model[PLATFORM_MAX_PATH];
	GetEntPropString(entity, Prop_Data, "m_ModelName", model, sizeof(model));
	
	// Do not randomize if there is no model
	if (model[0] == '\0')
		return;
	
	if (rainbomizer_models_use_precache_table.BoolValue)
	{
		for (;;)
		{
			int index = GetRandomInt(0, numStrings - 1);
			ReadStringTable(g_ModelPrecacheTable, index, model, sizeof(model));
			
			// Ignore brush and sprite models
			if (StrContains(model, ".mdl") != -1)
			{
				SetEntProp(entity, Prop_Data, "m_nModelIndexOverrides", index);
				SetEntProp(entity, Prop_Data, "m_nModelIndex", index);
				break;
			}
		}
	}
	else
	{
		char directory[PLATFORM_MAX_PATH];
		strcopy(directory, sizeof(directory), model);
		
		// For weapons and cosmetics, go back an additional directory.
		// This usually leads to all items of that class.
		if (StrContains(directory, "weapons/") != -1 || StrContains(directory, "player/items/") != -1)
			GetPreviousDirectoryPath(directory, 2);
		else
			GetPreviousDirectoryPath(directory, 1);
		
		ArrayList models;
		
		if (!g_ModelCache.GetValue(directory, models))
		{
			models = new ArrayList(PLATFORM_MAX_PATH);
			IterateDirectoryRecursive(directory, models, IterateModels);
			
			// Add fetched models to cache
			g_ModelCache.SetValue(directory, models);
		}
		
		if (!models)
			ThrowError("Failed to fetch random models list for %s", model);
		
		if (models.Length > 0)
		{
			models.GetString(GetRandomInt(0, models.Length - 1), model, sizeof(model));
			
			int index = PrecacheModel(model);
			SetEntProp(entity, Prop_Data, "m_nModelIndexOverrides", index);
			SetEntProp(entity, Prop_Data, "m_nModelIndex", index);
		}
	}
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

void IterateDirectoryRecursive(const char[] directory, ArrayList &list, FileIterator callback)
{
	// Search the directory we are trying to randomize
	DirectoryListing directoryListing = OpenDirectory(directory, true);
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

public Action NormalSoundHook(int clients[MAXPLAYERS], int &numClients, char sample[PLATFORM_MAX_PATH], int &entity, int &channel, float &volume, int &level, int &pitch, int &flags, char soundEntry[PLATFORM_MAX_PATH], int &seed)
{
	if (!rainbomizer_sounds.BoolValue)
		return Plugin_Continue;
	
	char sound[PLATFORM_MAX_PATH];
	
	if (rainbomizer_sounds_use_precache_table.BoolValue)
	{
		int numStrings = GetStringTableNumStrings(g_SoundPrecacheTable);
		int index = GetRandomInt(0, numStrings - 1);
		ReadStringTable(g_SoundPrecacheTable, index, sound, sizeof(sound));
		
		strcopy(sample, sizeof(sample), sound);
		return Plugin_Changed;
	}
	else
	{
		char soundPath[PLATFORM_MAX_PATH];
		strcopy(soundPath, sizeof(soundPath), sample);
		GetPreviousDirectoryPath(soundPath);
		
		char directory[PLATFORM_MAX_PATH];
		Format(directory, sizeof(directory), "sound/%s", soundPath);
		
		// TODO: Remove more sound chars
		ReplaceString(directory, sizeof(directory), ")", "");
		
		ArrayList sounds;
		
		// Filesystem operations are VERY expensive, keep a cache of the sounds we have fetched so far.
		// This will make memory usage of the plugin fairly big but it shouldn't be much of an issue.
		if (!g_SoundCache.GetValue(directory, sounds))
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
		
		if (!sounds)
			ThrowError("Failed to fetch random sound list for %s", sample);
		
		if (sounds.Length > 0)
		{
			sounds.GetString(GetRandomInt(0, sounds.Length - 1), sound, sizeof(sound));
			PrecacheSound(sound);
			
			strcopy(sample, sizeof(sample), sound);
			return Plugin_Changed;
		}
	}
	
	return Plugin_Continue;
}

public void Event_PostInventoryApplication(Event event, const char[] name, bool dontBroadcast)
{
	if (!rainbomizer_playermodels.BoolValue)
		return;
	
	int client = GetClientOfUserId(event.GetInt("userid"));
	
	char model[PLATFORM_MAX_PATH];
	strcopy(model, sizeof(model), g_Models[GetRandomInt(0, sizeof(g_Models) - 1)]);
	
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

void IntToColor32(int inColor, int &r, int &g, int &b, int &a)
{
	r = (inColor >> 24);
	g = (inColor >> 16) & 0xFF;
	b = (inColor >> 8) & 0xFF;
	a = (inColor) & 0xFF;
}

int Color32ToInt(int r, int g, int b, int a)
{
	return (r << 24) | (g << 16) | (b << 8) | (a);
}
