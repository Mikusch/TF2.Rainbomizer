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
#include <tf2utils>

#define PLUGIN_VERSION	"2.1.0"

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

public Plugin myInfo =
{
	name = "[TF2] Rainbomizer",
	author = "Mikusch",
	description = "A visual and auditory randomizer for Team Fortress 2",
	version = PLUGIN_VERSION,
	url = "https://github.com/Mikusch/TF2.Rainbomizer"
};

int g_iParticleEffectNamesTableIdx;
int g_iSoundPrecacheTableIdx;
int g_iModelPrecacheTableIdx;

bool g_bEnabled;
StringMap g_hModelCache;
StringMap g_hSoundCache;
StringMap g_hSoundReplacements;
ArrayList g_hLoopingSounds;
ArrayList g_hSkyNames;
ArrayList g_hPlayerModels;

ConVar sm_rainbomizer_enabled;
ConVar sm_rainbomizer_randomize_models;
ConVar sm_rainbomizer_randomize_sounds;
ConVar sm_rainbomizer_randomize_playermodels;
ConVar sm_rainbomizer_randomize_scale;
ConVar sm_rainbomizer_max_sound_precaches;
ConVar sm_rainbomizer_max_model_precaches;

public void OnPluginStart()
{
	g_iParticleEffectNamesTableIdx = FindStringTable("ParticleEffectNames");
	g_iSoundPrecacheTableIdx = FindStringTable("soundprecache");
	g_iModelPrecacheTableIdx = FindStringTable("modelprecache");

	g_hModelCache = new StringMap();
	g_hSoundCache = new StringMap();
	g_hSoundReplacements = new StringMap();

	CreateConVar("sm_rainbomizer_version", PLUGIN_VERSION, "Rainbomizer plugin version.", FCVAR_NOTIFY | FCVAR_DONTRECORD);
	sm_rainbomizer_enabled = CreateConVar("sm_rainbomizer_enabled", "1", "When set, the plugin will be enabled.", FCVAR_NOTIFY);
	sm_rainbomizer_enabled.AddChangeHook(ConVarChanged_Enable);
	sm_rainbomizer_randomize_models = CreateConVar("sm_rainbomizer_randomize_models", "1", "When set, models (and their skins/bodygroups) will be randomized.", FCVAR_NOTIFY);
	sm_rainbomizer_randomize_sounds = CreateConVar("sm_rainbomizer_randomize_sounds", "1", "When set, sounds will be randomized.", FCVAR_NOTIFY);
	sm_rainbomizer_randomize_playermodels = CreateConVar("sm_rainbomizer_randomize_playermodels", "1", "When set, player models will be randomized.", FCVAR_NOTIFY);
	sm_rainbomizer_randomize_scale = CreateConVar("sm_rainbomizer_randomize_scale", "0", "When set, the model scale of props/weapons is randomized.", FCVAR_NOTIFY);
	sm_rainbomizer_max_sound_precaches = CreateConVar("sm_rainbomizer_max_sound_precaches", "8000", "Stop precaching new randomized sounds once the engine 'soundprecache' string table reaches this many total entries.", _, true, 0.0, true, 16384.0);
	sm_rainbomizer_max_model_precaches = CreateConVar("sm_rainbomizer_max_model_precaches", "3000", "Stop precaching new randomized models once the engine 'modelprecache' string table reaches this many total entries.", _, true, 0.0, true, 4096.0);

	ReadFilesFromKeyValues("configs/rainbomizer/looping_sounds.cfg", g_hLoopingSounds);
	ReadFilesFromKeyValues("configs/rainbomizer/playermodels.cfg", g_hPlayerModels);

	BuildSkyNameList();

	IterateDirectoryRecursive("models", g_hModelCache);
	IterateDirectoryRecursive("sound", g_hSoundCache);
}

public void OnMapStart()
{
	g_hSoundReplacements.Clear();
}

public void OnMapInit(const char[] mapName)
{
	if (!sm_rainbomizer_enabled.BoolValue)
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
	if (g_bEnabled != sm_rainbomizer_enabled.BoolValue)
	{
		TogglePlugin(sm_rainbomizer_enabled.BoolValue);
	}

	if (g_bEnabled)
	{
		RandomizeSkybox();
	}
}

public void OnEntityCreated(int entity, const char[] classname)
{
	if (!g_bEnabled)
		return;

	// Non-player CBaseAnimating.
	if (entity > MaxClients && HasEntProp(entity, Prop_Send, "m_bClientSideAnimation") && sm_rainbomizer_randomize_models.BoolValue)
	{
		SDKHook(entity, SDKHook_SpawnPost, SDKHookCB_ModelEntitySpawnPost);
	}
	// Static lights.
	else if (StrContains(classname, "light") != -1 || StrEqual(classname, "env_lightglow"))
	{
		SDKHook(entity, SDKHook_SpawnPost, SDKHookCB_RenderEntitySpawnPost);
	}
	// Colorable entities.
	else if (StrEqual(classname, "env_sprite") || StrEqual(classname, "env_steam") || StrEqual(classname, "env_steamjet") || StrEqual(classname, "env_smokestack") || StrEqual(classname, "env_embers") || StrEqual(classname, "func_dustmotes"))
	{
		SDKHook(entity, SDKHook_SpawnPost, SDKHookCB_RenderEntitySpawnPost);
	}
	else if (StrEqual(classname, "env_fog_controller"))
	{
		SDKHook(entity, SDKHook_SpawnPost, SDKHookCB_FogControllerSpawnPost);
	}
	else if (StrEqual(classname, "env_sun"))
	{
		SDKHook(entity, SDKHook_SpawnPost, SDKHookCB_EnvSunSpawnPost);
	}
	else if (StrEqual(classname, "shadow_control"))
	{
		SDKHook(entity, SDKHook_SpawnPost, SDKHookCB_ShadowControlSpawnPost);
	}
	else if (StrEqual(classname, "info_particle_system"))
	{
		SDKHook(entity, SDKHook_SpawnPost, SDKHookCB_ParticleSystemSpawnPost);
	}
	else if (StrEqual(classname, "tf_ragdoll"))
	{
		SDKHook(entity, SDKHook_SpawnPost, SDKHookCB_RagdollSpawnPost);
	}
	else if (StrEqual(classname, "func_precipitation"))
	{
		SDKHook(entity, SDKHook_SpawnPost, SDKHookCB_PrecipitationSpawnPost);
	}
}

ArrayList GetApplicablePaths(StringMap map, const char[] base)
{
	ArrayList list;
	if (map.GetValue(base, list))
		return list;

	return null;
}

void RandomizeSkybox()
{
	if (g_hSkyNames.Length == 0)
		return;

	char skyname[PLATFORM_MAX_PATH];
	if (g_hSkyNames.GetString(GetRandomInt(0, g_hSkyNames.Length - 1), skyname, sizeof(skyname)))
		DispatchKeyValue(0, "skyname", skyname);
}

void BuildSkyNameList()
{
	g_hSkyNames = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));

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

		if (HasAllSkyFaces(faces, base) && g_hSkyNames.FindString(base) == -1)
			g_hSkyNames.PushString(base);
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
		int colorInt[4];
		StringToColor(value, colorInt);

		char strColor[32];
		GetRandomColorStringRGBA(strColor, sizeof(strColor), colorInt[3]);
		entry.Update(index, NULL_STRING, strColor);
	}
}

void GetRandomColorStringRGBA(char[] color, int maxlength, int alpha_override = -1)
{
	int a = (alpha_override != -1) ? alpha_override : GetRandomInt(0, 255);
	Format(color, maxlength, "%d %d %d %d", GetRandomInt(0, 255), GetRandomInt(0, 255), GetRandomInt(0, 255), a);
}

int GetRandomColorInt(int alpha)
{
	return GetRandomInt(0, 255) | (GetRandomInt(0, 255) << 8) | (GetRandomInt(0, 255) << 16) | (alpha << 24);
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

void RandomizeEntityColor(int entity, PropType type, const char[] prop)
{
	SetEntProp(entity, type, prop, GetRandomColorInt(GetColorAlpha(GetEntProp(entity, type, prop))));
}

bool GetStringTableEntry(int tableidx, int stringidx, char[] str, int maxlength)
{
	if (ReadStringTable(tableidx, stringidx, str, maxlength))
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
		LogError("Failed to find configuration file %s", file);
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

	if ((StrEqual(extension, ".mp3") || StrEqual(extension, ".wav")) && g_hLoopingSounds.FindString(filename) == -1)
		return true;

	// Don't use festivizer models as there are far too many.
	return StrEqual(extension, ".mdl") && StrContains(filename, "festivizer") == -1 && StrContains(filename, "xmas") == -1 && StrContains(filename, "xms") == -1;
}

void TogglePlugin(bool bEnable)
{
	g_bEnabled = bEnable;

	if (bEnable)
	{
		HookEvent("post_inventory_application", EventHook_PostInventoryApplication);
		AddNormalSoundHook(NormalSoundHook);
	}
	else
	{
		UnhookEvent("post_inventory_application", EventHook_PostInventoryApplication);
		RemoveNormalSoundHook(NormalSoundHook);
	}
}

void RandomizeModelAppearance(int entity)
{
	SetEntProp(entity, Prop_Send, "m_nSkin", GetRandomInt(0, 3));
	SetEntProp(entity, Prop_Send, "m_nBody", GetRandomInt(0, 63));

	if (sm_rainbomizer_randomize_scale.BoolValue)
		SetEntPropFloat(entity, Prop_Send, "m_flModelScale", GetRandomFloat(0.5, 2.0));
}

static void SDKHookCB_ModelEntitySpawnPost(int entity)
{
	if (!sm_rainbomizer_randomize_models.BoolValue)
		return;

	RandomizeModelAppearance(entity);

	char m_ModelName[PLATFORM_MAX_PATH];
	if (!GetEntPropString(entity, Prop_Data, "m_ModelName", m_ModelName, sizeof(m_ModelName)))
		return;

	if (StrContains(m_ModelName, "weapons/") != -1 || StrContains(m_ModelName, "player/items/") != -1)
		GetPreviousDirectoryPath(m_ModelName, 2);
	else
		GetPreviousDirectoryPath(m_ModelName, 1);

	ArrayList list = GetApplicablePaths(g_hModelCache, m_ModelName);
	if (list == null || !list.Length)
		return;

	char model[PLATFORM_MAX_PATH];
	bool chosen;
	if (GetStringTableNumStrings(g_iModelPrecacheTableIdx) < sm_rainbomizer_max_model_precaches.IntValue)
	{
		list.GetString(GetRandomInt(0, list.Length - 1), model, sizeof(model));
		chosen = true;
	}
	else
	{
		chosen = SelectPrecachedString(list, g_iModelPrecacheTableIdx, 0, model, sizeof(model));
	}

	if (chosen)
		SetEntProp(entity, Prop_Data, "m_nModelIndexOverrides", PrecacheModel(model));

	if (HasEntProp(entity, Prop_Send, "m_bValidatedAttachedEntity"))
		SetEntProp(entity, Prop_Send, "m_bValidatedAttachedEntity", true);
}

static void SDKHookCB_RenderEntitySpawnPost(int entity)
{
	RandomizeEntityColor(entity, Prop_Send, "m_clrRender");
}

static void SDKHookCB_FogControllerSpawnPost(int entity)
{
	RandomizeEntityColor(entity, Prop_Send, "m_fog.colorPrimary");
	RandomizeEntityColor(entity, Prop_Send, "m_fog.colorSecondary");
	SetEntProp(entity, Prop_Send, "m_fog.blend", true);
}

static void SDKHookCB_EnvSunSpawnPost(int entity)
{
	RandomizeEntityColor(entity, Prop_Send, "m_clrRender");
	RandomizeEntityColor(entity, Prop_Send, "m_clrOverlay");

	SetEntProp(entity, Prop_Send, "m_nSize", GetRandomInt(4, 64));
	SetEntProp(entity, Prop_Send, "m_nOverlaySize", GetRandomInt(4, 64));
}

static void SDKHookCB_ShadowControlSpawnPost(int entity)
{
	RandomizeEntityColor(entity, Prop_Send, "m_shadowColor");
}

static void SDKHookCB_ParticleSystemSpawnPost(int entity)
{
	int num = GetStringTableNumStrings(g_iParticleEffectNamesTableIdx);
	int stringidx = GetRandomInt(0, num - 1);

	char effectName[PLATFORM_MAX_PATH];
	if (GetStringTableEntry(g_iParticleEffectNamesTableIdx, stringidx, effectName, sizeof(effectName)))
		SetEntPropString(entity, Prop_Data, "m_iszEffectName", effectName);
}

static void SDKHookCB_RagdollSpawnPost(int entity)
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

	switch (GetRandomInt(0, 3))
	{
		case 0: SetEntProp(entity, Prop_Send, "m_bGoldRagdoll", true);
		case 1: SetEntProp(entity, Prop_Send, "m_bIceRagdoll", true);
		case 2: SetEntProp(entity, Prop_Send, "m_bBurning", true);
		case 3: SetEntProp(entity, Prop_Send, "m_bElectrocuted", true);
	}
}

static void SDKHookCB_PrecipitationSpawnPost(int entity)
{
	// 0 = rain, 1 = snow, 2 = ash, 3 = snowfall (NUM_PRECIPITATION_TYPES)
	SetEntProp(entity, Prop_Send, "m_nPrecipType", GetRandomInt(0, 3));
}

bool SelectPrecachedString(ArrayList list, int tableidx, int prefixLen, char[] out, int maxlength)
{
	int count;
	char path[PLATFORM_MAX_PATH];
	for (int i = 0; i < list.Length; i++)
	{
		list.GetString(i, path, sizeof(path));
		if (FindStringIndex(tableidx, path[prefixLen]) == INVALID_STRING_INDEX)
			continue;

		count++;
		if (GetRandomInt(1, count) == 1)
			strcopy(out, maxlength, path[prefixLen]);
	}

	return count > 0;
}

bool SelectSoundReplacement(const char[] sample, char[] replacement, int maxlength)
{
	char filePath[PLATFORM_MAX_PATH];
	GetBaseSoundPath(sample, filePath, sizeof(filePath));

	ArrayList list = GetApplicablePaths(g_hSoundCache, filePath);
	if (list == null || !list.Length)
		return false;

	if (GetStringTableNumStrings(g_iSoundPrecacheTableIdx) < sm_rainbomizer_max_sound_precaches.IntValue)
	{
		char path[PLATFORM_MAX_PATH];
		list.GetString(GetRandomInt(0, list.Length - 1), path, sizeof(path));
		strcopy(replacement, maxlength, path[strlen("sound/")]);
		PrecacheSound(replacement);
	}
	else if (!SelectPrecachedString(list, g_iSoundPrecacheTableIdx, strlen("sound/"), replacement, maxlength))
	{
		return false;
	}

	g_hSoundReplacements.SetString(sample, replacement);
	return true;
}

static Action NormalSoundHook(int clients[MAXPLAYERS], int &numClients, char sample[PLATFORM_MAX_PATH], int &entity, int &channel, float &volume, int &level, int &pitch, int &flags, char soundEntry[PLATFORM_MAX_PATH], int &seed)
{
	bool changed;

	if (sm_rainbomizer_randomize_sounds.BoolValue)
	{
		char replacement[PLATFORM_MAX_PATH];
		if (g_hSoundReplacements.GetString(sample, replacement, sizeof(replacement)) || SelectSoundReplacement(sample, replacement, sizeof(replacement)))
		{
			strcopy(sample, sizeof(sample), replacement);
			changed = true;
		}
	}

	return changed ? Plugin_Changed : Plugin_Continue;
}

static void EventHook_PostInventoryApplication(Event event, const char[] name, bool dontBroadcast)
{
	if (!sm_rainbomizer_randomize_playermodels.BoolValue || g_hPlayerModels.Length == 0)
		return;

	int client = GetClientOfUserId(event.GetInt("userid"));

	char model[PLATFORM_MAX_PATH];
	g_hPlayerModels.GetString(GetRandomInt(0, g_hPlayerModels.Length - 1), model, sizeof(model));

	int wearable = CreateEntityByName("tf_wearable");
	if (IsValidEntity(wearable) && DispatchSpawn(wearable))
	{
		TF2Util_EquipPlayerWearable(client, wearable);

		SetEntProp(client, Prop_Send, "m_nRenderFX", RENDERFX_FADE_FAST);
		SetEntProp(wearable, Prop_Data, "m_nModelIndexOverrides", PrecacheModel(model));
		SetEntProp(wearable, Prop_Send, "m_bValidatedAttachedEntity", true);
	}
}

static void ConVarChanged_Enable(ConVar convar, const char[] oldValue, const char[] newValue)
{
	if (g_bEnabled != convar.BoolValue)
	{
		TogglePlugin(convar.BoolValue);
	}
}
