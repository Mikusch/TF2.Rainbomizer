/*
 * Copyright (C) 2024  Mikusch
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

#pragma newdecls required
#pragma semicolon 1

#include <sourcemod>
#include <sdkhooks>
#include <sdktools>
#include <pluginstatemanager>

#define PLUGIN_VERSION	"3.0.0"

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

public Plugin myinfo =
{
	name = "[TF2] Rainbomizer",
	author = "Mikusch",
	description = "A visual and auditory randomizer for Team Fortress 2",
	version = PLUGIN_VERSION,
	url = "https://github.com/Mikusch/TF2.Rainbomizer"
};

int g_particleEffectNamesTable;
int g_soundPrecacheTable;
int g_modelPrecacheTable;

StringMap g_modelCache;
StringMap g_soundCache;
StringMap g_soundReplacements;
ArrayList g_loopingSounds;
ArrayList g_skyNames;
ArrayList g_playerModels;
ArrayList g_viewModels;

Handle g_sdkCallEquipWearable;

ConVar rbmz_enabled;
ConVar rbmz_randomize_models;
ConVar rbmz_randomize_sounds;
ConVar rbmz_randomize_playermodels;
ConVar rbmz_randomize_viewmodels;
ConVar rbmz_randomize_scale;
ConVar rbmz_full_random;
ConVar rbmz_max_sound_precaches;
ConVar rbmz_max_model_precaches;

public void OnPluginStart()
{
	g_particleEffectNamesTable = FindStringTable("ParticleEffectNames");
	g_soundPrecacheTable = FindStringTable("soundprecache");
	g_modelPrecacheTable = FindStringTable("modelprecache");

	g_modelCache = new StringMap();
	g_soundCache = new StringMap();
	g_soundReplacements = new StringMap();

	CreateConVar("rbmz_version", PLUGIN_VERSION, "Rainbomizer plugin version.", FCVAR_NOTIFY | FCVAR_DONTRECORD);
	rbmz_enabled = CreateConVar("rbmz_enabled", "1", "When set, the plugin will be enabled.", FCVAR_NOTIFY);
	rbmz_randomize_models = CreateConVar("rbmz_randomize_models", "1", "When set, models will be randomized.", FCVAR_NOTIFY);
	rbmz_randomize_sounds = CreateConVar("rbmz_randomize_sounds", "1", "When set, sounds will be randomized.", FCVAR_NOTIFY);
	rbmz_randomize_playermodels = CreateConVar("rbmz_randomize_playermodels", "1", "When set, player models will be randomized.", FCVAR_NOTIFY);
	rbmz_randomize_viewmodels = CreateConVar("rbmz_randomize_viewmodels", "0", "When set, first-person weapon viewmodels will be randomized.", FCVAR_NOTIFY);
	rbmz_randomize_scale = CreateConVar("rbmz_randomize_scale", "0", "When set, the model scale of props/weapons is randomized.", FCVAR_NOTIFY);
	rbmz_full_random = CreateConVar("rbmz_full_random", "0", "When set, models and sounds are randomized from the entire game instead of by matching asset path.", FCVAR_NOTIFY);
	rbmz_max_sound_precaches = CreateConVar("rbmz_max_sound_precaches", "8192", "Stop precaching new randomized sounds once the engine 'soundprecache' string table reaches this many total entries.", _, true, 0.0, true, 16384.0);
	rbmz_max_model_precaches = CreateConVar("rbmz_max_model_precaches", "2048", "Stop precaching new randomized models once the engine 'modelprecache' string table reaches this many total entries.", _, true, 0.0, true, 4096.0);

	GameData gamedata = new GameData("rainbomizer");
	if (gamedata)
	{
		g_sdkCallEquipWearable = PrepSDKCall_EquipWearable(gamedata);
		delete gamedata;
	}
	else
	{
		LogError("Failed to load rainbomizer gamedata");
	}

	PSM_Init("rbmz_enabled");
	PSM_AddNormalSoundHook(NormalSoundHook);
	PSM_AddEventHook("post_inventory_application", EventHook_PostInventoryApplication);
	PSM_AddEventHook("teamplay_round_start", EventHook_TeamplayRoundStart);

	ReadFilesFromKeyValues("configs/rainbomizer/looping_sounds.cfg", g_loopingSounds);
	ReadFilesFromKeyValues("configs/rainbomizer/playermodels.cfg", g_playerModels);

	IterateDirectoryRecursive("models", g_modelCache);
	IterateDirectoryRecursive("sound", g_soundCache);

	BuildViewModelList();
	BuildSkyNameList();
}

public void OnMapStart()
{
	g_soundReplacements.Clear();
}

public void OnMapInit(const char[] mapName)
{
	if (!rbmz_enabled.BoolValue)
		return;

	// Parse the entity lump and randomize static light colors.
	for (int i = 0; i < EntityLump.Length(); i++)
	{
		EntityLumpEntry entry = EntityLump.Get(i);

		int index = entry.FindKey("classname");
		if (index != -1)
		{
			char classname[64];
			entry.Get(index, _, _, classname, sizeof(classname));

			if (StrEqual(classname, "light") || StrEqual(classname, "light_spot") || StrEqual(classname, "light_environment"))
			{
				RandomizeLightEntryColor(entry, "_light");
				RandomizeLightEntryColor(entry, "_ambient");
			}
		}

		delete entry;
	}
}

public void OnConfigsExecuted()
{
	PSM_TogglePluginState();

	if (PSM_IsEnabled())
		RandomizeSkybox();
}

public void OnClientPutInServer(int client)
{
	if (PSM_IsEnabled())
		PSM_SDKHook(client, SDKHook_WeaponSwitch, CTFPlayer_WeaponSwitch);
}

public void OnEntityCreated(int entity, const char[] classname)
{
	if (!PSM_IsEnabled())
		return;

	// Non-player CBaseAnimating.
	if (entity > MaxClients && HasEntProp(entity, Prop_Send, "m_bClientSideAnimation") && rbmz_randomize_models.BoolValue)
	{
		PSM_SDKHook(entity, SDKHook_SpawnPost, CBaseAnimating_SpawnPost);
	}
	// Static lights.
	else if (StrContains(classname, "light") != -1 || StrEqual(classname, "env_lightglow"))
	{
		PSM_SDKHook(entity, SDKHook_SpawnPost, CBaseEntity_SpawnPost);
	}
	// Colorable entities.
	else if (StrEqual(classname, "env_sprite") || StrEqual(classname, "env_steam") || StrEqual(classname, "env_steamjet") || StrEqual(classname, "env_smokestack") || StrEqual(classname, "env_embers"))
	{
		PSM_SDKHook(entity, SDKHook_SpawnPost, CBaseEntity_SpawnPost);
	}
	else if (StrEqual(classname, "func_dustmotes"))
	{
		PSM_SDKHook(entity, SDKHook_SpawnPost, CFunc_DustMotes_SpawnPost);
	}
	else if (StrEqual(classname, "env_fog_controller"))
	{
		PSM_SDKHook(entity, SDKHook_SpawnPost, CFogController_SpawnPost);
	}
	else if (StrEqual(classname, "env_sun"))
	{
		PSM_SDKHook(entity, SDKHook_SpawnPost, CSun_SpawnPost);
	}
	else if (StrEqual(classname, "shadow_control"))
	{
		PSM_SDKHook(entity, SDKHook_SpawnPost, CShadowControl_SpawnPost);
	}
	else if (StrEqual(classname, "info_particle_system"))
	{
		PSM_SDKHook(entity, SDKHook_SpawnPost, CParticleSystem_SpawnPost);
	}
	else if (StrEqual(classname, "tf_ragdoll"))
	{
		PSM_SDKHook(entity, SDKHook_SpawnPost, CTFRagdoll_SpawnPost);
	}
	else if (StrEqual(classname, "func_precipitation"))
	{
		PSM_SDKHook(entity, SDKHook_SpawnPost, CPrecipitation_SpawnPost);
	}
}

public void OnEntityDestroyed(int entity)
{
	if (!PSM_IsEnabled())
		return;

	if (entity == -1)
		return;

	PSM_SDKUnhook(entity);
}

void RandomizeSkybox()
{
	if (g_skyNames.Length == 0)
		return;

	char skyname[PLATFORM_MAX_PATH];
	if (g_skyNames.GetString(GetRandomInt(0, g_skyNames.Length - 1), skyname, sizeof(skyname)))
		DispatchKeyValue(0, "skyname", skyname);
}

void BuildSkyNameList()
{
	g_skyNames = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));

	StringMap faces = new StringMap();
	ArrayList tops = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));

	DirectoryListing dir = OpenDirectory("materials/skybox", true, NULL_STRING);
	if (dir)
	{
		char file[PLATFORM_MAX_PATH];
		FileType type;
		while (dir.GetNext(file, sizeof(file), type))
		{
			int len = strlen(file);
			if (type != FileType_File || len < 7 || !StrEqual(file[len - 4], ".vmt", false))
				continue;

			char stem[PLATFORM_MAX_PATH];
			strcopy(stem, sizeof(stem), file);
			stem[len - 4] = '\0';
			for (int i = 0; stem[i] != '\0'; i++)
				stem[i] = CharToLower(stem[i]);

			faces.SetValue(stem, 1);

			int slen = strlen(stem);
			if (slen > 2 && StrEqual(stem[slen - 2], "up", false))
			{
				stem[slen - 2] = '\0';
				tops.PushString(stem);
			}
		}
		delete dir;
	}

	for (int i = 0; i < tops.Length; i++)
	{
		char base[PLATFORM_MAX_PATH];
		tops.GetString(i, base, sizeof(base));

		int blen = strlen(base);
		if (blen == 0)
			continue;

		if (blen >= 4 && StrEqual(base[blen - 4], "_hdr", false))
			continue;
		if (blen >= 5 && StrEqual(base[blen - 5], "_dx80", false))
			continue;

		if (HasAllSkyFaces(faces, base) && g_skyNames.FindString(base) == -1)
			g_skyNames.PushString(base);
	}

	delete faces;
	delete tops;
}

bool HasAllSkyFaces(StringMap faces, const char[] base)
{
	char sides[][] = { "rt", "bk", "lf", "ft", "up", "dn" };

	char probe[PLATFORM_MAX_PATH];
	int dummy;
	for (int i = 0; i < sizeof(sides); i++)
	{
		Format(probe, sizeof(probe), "%s%s", base, sides[i]);
		if (!faces.GetValue(probe, dummy))
			return false;
	}

	return true;
}

void RandomizeLightEntryColor(EntityLumpEntry entry, const char[] key)
{
	char value[64];
	int index = entry.GetNextKey(key, value, sizeof(value));
	if (index != -1)
	{
		int color[4];
		StringToColor(value, color);

		char randomColor[32];
		GetRandomColorStringRGBA(randomColor, sizeof(randomColor), color[3]);
		entry.Update(index, NULL_STRING, randomColor);
	}
}

void GetRandomColorStringRGBA(char[] color, int maxlength, int alphaOverride = -1)
{
	int alpha = (alphaOverride != -1) ? alphaOverride : GetRandomInt(0, 255);
	Format(color, maxlength, "%d %d %d %d", GetRandomInt(0, 255), GetRandomInt(0, 255), GetRandomInt(0, 255), alpha);
}

int GetColorAlpha(int color)
{
	return (color >> 24) & 0xFF;
}

void StringToColor(const char[] str, int color[4])
{
	char buffer[4][16];
	ExplodeString(str, " ", buffer, sizeof(buffer), sizeof(buffer[]));

	for (int i = 0; i < sizeof(color); i++)
	{
		color[i] = StringToInt(buffer[i]);
	}
}

// Randomizes an entity color's RGB while preserving its current alpha, applied via its keyvalue.
void RandomizeColor(int entity, const char[] prop, const char[] key)
{
	int alpha = GetColorAlpha(GetEntProp(entity, Prop_Send, prop));

	char color[24];
	Format(color, sizeof(color), "%d %d %d %d", GetRandomInt(0, 255), GetRandomInt(0, 255), GetRandomInt(0, 255), alpha);
	DispatchKeyValue(entity, key, color);
}

bool GetStringTableEntry(int table, int stringIndex, char[] str, int maxlength)
{
	if (ReadStringTable(table, stringIndex, str, maxlength))
	{
		// Ignore empty entries.
		if (!str[0])
			return false;

		// Convert Windows paths to Unix paths.
		ReplaceString(str, maxlength, "\\", "/");
		return true;
	}

	return false;
}

void ReadFilesFromKeyValues(const char[] file, ArrayList &list)
{
	list = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));

	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), file);

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
		LogError("Failed to find configuration file: %s", file);
	}
	delete kv;
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

bool IsSoundChar(char c)
{
	bool b;

	b = (c == CHAR_STREAM || c == CHAR_USERVOX || c == CHAR_SENTENCE || c == CHAR_DRYMIX || c == CHAR_OMNI);
	b = b || (c == CHAR_DOPPLER || c == CHAR_DIRECTIONAL || c == CHAR_DISTVARIANT || c == CHAR_SPATIALSTEREO || c == CHAR_FAST_PITCH);

	return b;
}

void SkipSoundChars(const char[] sound, char[] buffer, int size)
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

void GetBaseSoundPath(const char[] sound, char[] buffer, int length)
{
	// For sounds, we generally just go up one level.
	char[] soundPath = new char[length];
	strcopy(soundPath, length, sound);
	GetPreviousDirectoryPath(soundPath);

	// Remove sound chars and prepend "sound/".
	strcopy(buffer, length, soundPath);
	SkipSoundChars(buffer, buffer, length);
	Format(buffer, length, "sound/%s", buffer);
}

ArrayList IterateDirectoryRecursive(const char[] directory, StringMap cache)
{
	ArrayList subtree = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));

	DirectoryListing directoryListing = OpenDirectory(directory, true, NULL_STRING);
	if (directoryListing)
	{
		char file[PLATFORM_MAX_PATH];
		FileType type;
		while (directoryListing.GetNext(file, sizeof(file), type))
		{
			char path[PLATFORM_MAX_PATH];
			switch (type)
			{
				case FileType_Directory:
				{
					// Don't process special directory names.
					if (file[0] == '.')
						continue;

					Format(path, sizeof(path), "%s/%s", directory, file);

					// Recurse and fold the child's subtree into ours.
					ArrayList child = IterateDirectoryRecursive(path, cache);
					char childPath[PLATFORM_MAX_PATH];
					for (int i = 0; i < child.Length; i++)
					{
						child.GetString(i, childPath, sizeof(childPath));
						subtree.PushString(childPath);
					}
				}
				case FileType_File:
				{
					Format(path, sizeof(path), "%s/%s", directory, file);

					if (IsValidFile(path))
						subtree.PushString(path);
				}
			}
		}

		delete directoryListing;
	}

	cache.SetValue(directory, subtree);
	return subtree;
}

bool IsValidFile(const char[] filename)
{
	char extension[5];
	if (!strcopy(extension, sizeof(extension), filename[strlen(filename) - 4]))
		return false;

	if ((StrEqual(extension, ".mp3") || StrEqual(extension, ".wav")) && g_loopingSounds.FindString(filename) == -1)
		return true;

	// Don't use festivizer models as there are far too many.
	return StrEqual(extension, ".mdl") && StrContains(filename, "festivizer") == -1 && StrContains(filename, "xmas") == -1 && StrContains(filename, "xms") == -1;
}

ArrayList GetApplicablePaths(StringMap map, const char[] base)
{
	ArrayList list;
	if (map.GetValue(base, list))
		return list;

	return null;
}

void RandomizeModelAppearance(int entity)
{
	DispatchKeyValueInt(entity, "skin", GetRandomInt(0, 3));
	DispatchKeyValueInt(entity, "body", GetRandomInt(0, 63));

	if (rbmz_randomize_scale.BoolValue)
		DispatchKeyValueFloat(entity, "modelscale", GetRandomFloat(0.5, 2.0));
}

int SelectRandomModelIndex(ArrayList list)
{
	if (list == null || !list.Length)
		return 0;

	char model[PLATFORM_MAX_PATH];
	if (GetStringTableNumStrings(g_modelPrecacheTable) < rbmz_max_model_precaches.IntValue)
	{
		list.GetString(GetRandomInt(0, list.Length - 1), model, sizeof(model));
	}
	else if (!SelectPrecachedString(list, g_modelPrecacheTable, 0, model, sizeof(model)))
	{
		return 0;
	}

	return PrecacheModel(model);
}

static void CBaseAnimating_SpawnPost(int entity)
{
	if (!rbmz_randomize_models.BoolValue)
		return;

	RandomizeModelAppearance(entity);

	char base[PLATFORM_MAX_PATH];
	if (rbmz_full_random.BoolValue)
	{
		strcopy(base, sizeof(base), "models");
	}
	else
	{
		if (!GetEntPropString(entity, Prop_Data, "m_ModelName", base, sizeof(base)))
			return;

		if (StrContains(base, "weapons/") != -1 || StrContains(base, "player/items/") != -1)
			GetPreviousDirectoryPath(base, 2);
		else
			GetPreviousDirectoryPath(base, 1);
	}

	int index = SelectRandomModelIndex(GetApplicablePaths(g_modelCache, base));
	if (index > 0)
		SetEntProp(entity, Prop_Data, "m_nModelIndexOverrides", index);

	if (HasEntProp(entity, Prop_Send, "m_bValidatedAttachedEntity"))
		SetEntProp(entity, Prop_Send, "m_bValidatedAttachedEntity", true);
}

void BuildViewModelList()
{
	g_viewModels = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));

	ArrayList models = GetApplicablePaths(g_modelCache, "models");
	if (models == null)
		return;

	char path[PLATFORM_MAX_PATH];
	for (int i = 0; i < models.Length; i++)
	{
		models.GetString(i, path, sizeof(path));
		if (StrContains(path, "weapons/c_models/") != -1)
			g_viewModels.PushString(path);
	}
}

void RandomizeViewModel(int weapon)
{
	if (!HasEntProp(weapon, Prop_Send, "m_nCustomViewmodelModelIndex"))
		return;

	int index = SelectRandomModelIndex(g_viewModels);
	if (index > 0)
		SetEntProp(weapon, Prop_Send, "m_nCustomViewmodelModelIndex", index);
}

static Action CTFPlayer_WeaponSwitch(int client, int weapon)
{
	if (rbmz_randomize_viewmodels.BoolValue && IsValidEntity(weapon))
		RandomizeViewModel(weapon);

	return Plugin_Continue;
}

static void CBaseEntity_SpawnPost(int entity)
{
	RandomizeColor(entity, "m_clrRender", "rendercolor");
}

static void CFunc_DustMotes_SpawnPost(int entity)
{
	RandomizeColor(entity, "m_Color", "Color");
}

static void CFogController_SpawnPost(int entity)
{
	RandomizeColor(entity, "m_fog.colorPrimary", "fogcolor");
	RandomizeColor(entity, "m_fog.colorSecondary", "fogcolor2");
	DispatchKeyValueInt(entity, "fogblend", 1);
}

static void CSun_SpawnPost(int entity)
{
	RandomizeColor(entity, "m_clrRender", "rendercolor");
	RandomizeColor(entity, "m_clrOverlay", "overlaycolor");

	DispatchKeyValueInt(entity, "size", GetRandomInt(4, 64));
	DispatchKeyValueInt(entity, "overlaysize", GetRandomInt(4, 64));
}

static void CShadowControl_SpawnPost(int entity)
{
	RandomizeColor(entity, "m_shadowColor", "color");
}

static void CParticleSystem_SpawnPost(int entity)
{
	int num = GetStringTableNumStrings(g_particleEffectNamesTable);
	int stringIndex = GetRandomInt(0, num - 1);

	char effectName[PLATFORM_MAX_PATH];
	if (GetStringTableEntry(g_particleEffectNamesTable, stringIndex, effectName, sizeof(effectName)))
		DispatchKeyValue(entity, "effect_name", effectName);
}

static void CTFRagdoll_SpawnPost(int entity)
{
	RequestFrame(RequestFrame_RandomizeRagdoll, EntIndexToEntRef(entity));
}

static void RequestFrame_RandomizeRagdoll(int ref)
{
	int entity = EntRefToEntIndex(ref);
	if (entity == INVALID_ENT_REFERENCE)
		return;

	SetEntProp(entity, Prop_Send, "m_bGoldRagdoll", false);
	SetEntProp(entity, Prop_Send, "m_bIceRagdoll", false);
	SetEntProp(entity, Prop_Send, "m_bBurning", false);
	SetEntProp(entity, Prop_Send, "m_bElectrocuted", false);

	// Equal chance of a normal ragdoll or a single random special one.
	if (GetRandomInt(0, 1) == 0)
		return;

	switch (GetRandomInt(0, 3))
	{
		case 0: SetEntProp(entity, Prop_Send, "m_bGoldRagdoll", true);
		case 1: SetEntProp(entity, Prop_Send, "m_bIceRagdoll", true);
		case 2: SetEntProp(entity, Prop_Send, "m_bBurning", true);
		case 3: SetEntProp(entity, Prop_Send, "m_bElectrocuted", true);
	}
}

static void CPrecipitation_SpawnPost(int entity)
{
	// 0 = rain, 1 = snow, 2 = ash, 3 = snowfall (NUM_PRECIPITATION_TYPES)
	DispatchKeyValueInt(entity, "preciptype", GetRandomInt(0, 3));
}

bool SelectPrecachedString(ArrayList list, int table, int prefixLen, char[] out, int maxlength)
{
	int count;
	char path[PLATFORM_MAX_PATH];
	for (int i = 0; i < list.Length; i++)
	{
		list.GetString(i, path, sizeof(path));
		if (FindStringIndex(table, path[prefixLen]) == INVALID_STRING_INDEX)
			continue;

		count++;
		if (GetRandomInt(1, count) == 1)
			strcopy(out, maxlength, path[prefixLen]);
	}

	return count > 0;
}

bool SelectSoundReplacement(const char[] sample, char[] replacement, int maxlength)
{
	char base[PLATFORM_MAX_PATH];
	if (rbmz_full_random.BoolValue)
		strcopy(base, sizeof(base), "sound");
	else
		GetBaseSoundPath(sample, base, sizeof(base));

	ArrayList list = GetApplicablePaths(g_soundCache, base);
	if (list == null || !list.Length)
		return false;

	if (GetStringTableNumStrings(g_soundPrecacheTable) < rbmz_max_sound_precaches.IntValue)
	{
		char path[PLATFORM_MAX_PATH];
		list.GetString(GetRandomInt(0, list.Length - 1), path, sizeof(path));
		strcopy(replacement, maxlength, path[strlen("sound/")]);
		PrecacheSound(replacement);
	}
	else if (!SelectPrecachedString(list, g_soundPrecacheTable, strlen("sound/"), replacement, maxlength))
	{
		return false;
	}

	g_soundReplacements.SetString(sample, replacement);
	return true;
}

static Action NormalSoundHook(int clients[MAXPLAYERS], int &numClients, char sample[PLATFORM_MAX_PATH], int &entity, int &channel, float &volume, int &level, int &pitch, int &flags, char soundEntry[PLATFORM_MAX_PATH], int &seed)
{
	bool changed;

	if (rbmz_randomize_sounds.BoolValue)
	{
		char replacement[PLATFORM_MAX_PATH];
		if (g_soundReplacements.GetString(sample, replacement, sizeof(replacement)) || SelectSoundReplacement(sample, replacement, sizeof(replacement)))
		{
			strcopy(sample, sizeof(sample), replacement);
			changed = true;
		}
	}

	return changed ? Plugin_Changed : Plugin_Continue;
}

static void EventHook_PostInventoryApplication(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!client)
		return;

	if (rbmz_randomize_playermodels.BoolValue && g_playerModels.Length > 0)
		RandomizePlayerModel(client);

	if (rbmz_randomize_viewmodels.BoolValue)
	{
		for (int i = 0; i < GetEntPropArraySize(client, Prop_Send, "m_hMyWeapons"); i++)
		{
			int weapon = GetEntPropEnt(client, Prop_Send, "m_hMyWeapons", i);
			if (weapon != -1)
				RandomizeViewModel(weapon);
		}
	}
}

void RandomizePlayerModel(int client)
{
	if (!g_sdkCallEquipWearable)
		return;

	char model[PLATFORM_MAX_PATH];
	g_playerModels.GetString(GetRandomInt(0, g_playerModels.Length - 1), model, sizeof(model));

	int wearable = CreateEntityByName("tf_wearable");
	if (IsValidEntity(wearable) && DispatchSpawn(wearable))
	{
		SDKCall(g_sdkCallEquipWearable, client, wearable);

		SetEntProp(client, Prop_Send, "m_nRenderFX", RENDERFX_FADE_FAST);
		SetEntProp(wearable, Prop_Data, "m_nModelIndexOverrides", PrecacheModel(model));
		SetEntProp(wearable, Prop_Send, "m_bValidatedAttachedEntity", true);
	}
}

static void EventHook_TeamplayRoundStart(Event event, const char[] name, bool dontBroadcast)
{
	if (event.GetBool("full_reset"))
		RandomizeSkybox();
}

static Handle PrepSDKCall_EquipWearable(GameData gamedata)
{
	StartPrepSDKCall(SDKCall_Player);
	PrepSDKCall_SetFromConf(gamedata, SDKConf_Virtual, "CTFPlayer::EquipWearable()");
	PrepSDKCall_AddParameter(SDKType_CBaseEntity, SDKPass_Pointer);

	Handle call = EndPrepSDKCall();
	if (!call)
		LogError("Failed to create SDKCall: CTFPlayer::EquipWearable()");

	return call;
}
