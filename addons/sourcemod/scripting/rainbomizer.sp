#pragma newdecls required
#pragma semicolon 1

#include <sourcemod>
#include <sdkhooks>
#include <sdktools>
#include <tf2utils>

#define PLUGIN_VERSION	"2.0.0"

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

enum struct SoundInfo
{
	float time;
	char replacement[PLATFORM_MAX_PATH];
}

int g_iParticleEffectNamesTableIdx;

bool g_bEnabled;
StringMap g_hModelCache;
StringMap g_hSoundCache;
StringMap g_hRecentlyReplaced;
ArrayList g_hLoopingSounds;
ArrayList g_hSkyNames;
ArrayList g_hPlayerModels;

ConVar sm_rainbomizer_enabled;
ConVar sm_rainbomizer_randomize_models;
ConVar sm_rainbomizer_randomize_sounds;
ConVar sm_rainbomizer_randomize_playermodels;

public void OnPluginStart()
{
	g_iParticleEffectNamesTableIdx = FindStringTable("ParticleEffectNames");
	
	g_hModelCache = new StringMap();
	g_hSoundCache = new StringMap();
	g_hRecentlyReplaced = new StringMap();
	g_hLoopingSounds = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
	g_hSkyNames = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
	g_hPlayerModels = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
	
	sm_rainbomizer_enabled = CreateConVar("sm_rainbomizer_enabled", "1", "Whether to enable the plugin.");
	sm_rainbomizer_enabled.AddChangeHook(ConVarChanged_Enable);
	sm_rainbomizer_randomize_models = CreateConVar("sm_rainbomizer_randomize_models", "1", "Whether to randomize models.");
	sm_rainbomizer_randomize_sounds = CreateConVar("sm_rainbomizer_randomize_sounds", "1", "Whether to randomize sounds.");
	sm_rainbomizer_randomize_playermodels = CreateConVar("sm_rainbomizer_randomize_playermodels", "1", "Whether to randomize playermodels.");
	
	ReadFilesFromKeyValues("configs/rainbomizer/looping_sounds.cfg", g_hLoopingSounds);
	ReadFilesFromKeyValues("configs/rainbomizer/skynames.cfg", g_hSkyNames);
	ReadFilesFromKeyValues("configs/rainbomizer/playermodels.cfg", g_hPlayerModels);
	
	IterateDirectoryRecursive("models", g_hModelCache, new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH)));
	IterateDirectoryRecursive("sound", g_hSoundCache, new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH)));
}

public void OnMapStart()
{
	g_hRecentlyReplaced.Clear();
}

public void OnMapInit(const char[] mapName)
{
	if (!g_bEnabled)
		return;
	
	// Parse entity lump for light data
	for (int i = 0; i < EntityLump.Length(); i++)
	{
		EntityLumpEntry entry = EntityLump.Get(i);
		
		int index = entry.FindKey("classname");
		if (index == 1)
			continue;
		
		char classname[64];
		entry.Get(index, _, _, classname, sizeof(classname));
		
		if (!StrEqual(classname, "light") && !StrEqual(classname, "light_spot") && !StrEqual(classname, "light_environment"))
			continue;
		
		RandomizeLightEntryColor(entry, "_light");
		RandomizeLightEntryColor(entry, "_ambient");
		
		delete entry;
	}
}

public void OnConfigsExecuted()
{
	if (g_bEnabled != sm_rainbomizer_enabled.BoolValue)
	{
		TogglePlugin(sm_rainbomizer_enabled.BoolValue);
	}
}

public void OnEntityCreated(int entity, const char[] classname)
{
	if (!g_bEnabled)
		return;
	
	// Check if this entity is a non-player CBaseAnimating
	if (entity > MaxClients && HasEntProp(entity, Prop_Send, "m_bClientSideAnimation") && sm_rainbomizer_randomize_models.BoolValue)
	{
		SDKHook(entity, SDKHook_SpawnPost, SDKHookCB_ModelEntitySpawnPost);
	}
	
	// Randomize light colors
	if (StrContains(classname, "light") != -1 || StrEqual(classname, "env_lightglow"))
	{
		SDKHook(entity, SDKHook_SpawnPost, SDKHookCB_LightSpawnPost);
	}
	
	if (StrEqual(classname, "env_fog_controller"))
	{
		SDKHook(entity, SDKHook_SpawnPost, SDKHookCB_FogControllerSpawnPost);
	}
	
	if (StrEqual(classname, "env_sun"))
	{
		SDKHook(entity, SDKHook_SpawnPost, SDKHookCB_EnvSunSpawnPost);
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

ArrayList GetApplicablePaths(StringMap map, const char[] base)
{
	ArrayList list = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
	
	StringMapSnapshot snapshot = map.Snapshot();
	for (int i = 0; i < snapshot.Length; i++)
	{
		int size = snapshot.KeyBufferSize(i);
		char[] key = new char[size];
		snapshot.GetKey(i, key, size);
		
		// Check sub-folders and collect their models for randomization
		if (!strncmp(key, base, strlen(base)))
		{
			ArrayList paths;
			if (map.GetValue(key, paths))
			{
				for (int j = 0; j < paths.Length; j++)
				{
					char path[PLATFORM_MAX_PATH];
					if (paths.GetString(j, path, sizeof(path)))
						list.PushString(path);
				}
			}
		}
	}
	delete snapshot;
	
	return list;
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
		entry.Update(index, "_light", strColor);
	}
}

void GetRandomColorStringRGBA(char[] color, int maxlength, int alpha_override = -1)
{
	int r, g, b, a;
	GetRandomColorRGBA(r, g, b, a);
	
	if (alpha_override != -1)
		a = alpha_override;
	
	Format(color, maxlength, "%d %d %d %d", r, g, b, a);
}

void GetRandomColorRGBA(int &r, int &g, int &b, int &a = 255)
{
	r = GetRandomInt(0, 255);
	g = GetRandomInt(0, 255);
	b = GetRandomInt(0, 255);
	a = GetRandomInt(0, 255);
}

int GetRandomColorInt(int alpha)
{
	int r, g, b;
	GetRandomColorRGBA(r, g, b);
	return Color32ToInt(r, g, b, alpha);
}

int Color32ToInt(int r, int g, int b, int a)
{
	return (r << 24) | (g << 16) | (b << 8) | (a);
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

bool GetStringTableEntry(int tableidx, int stringidx, char[] str, int maxlength)
{
	if (ReadStringTable(tableidx, stringidx, str, maxlength))
	{
		// Ignore empty entries
		if (!str[0])
			return false;
		
		// Fix up Windows paths
		ReplaceString(str, maxlength, "\\", "/");
		return true;
	}
	
	return false;
}

static void SDKHookCB_ModelEntitySpawnPost(int entity)
{
	char m_ModelName[PLATFORM_MAX_PATH];
	if (!GetEntPropString(entity, Prop_Data, "m_ModelName", m_ModelName, sizeof(m_ModelName)))
		return;
	
	if (StrContains(m_ModelName, "weapons/") != -1 || StrContains(m_ModelName, "player/items/") != -1)
		GetPreviousDirectoryPath(m_ModelName, 2);
	else
		GetPreviousDirectoryPath(m_ModelName, 1);
	
	ArrayList list = GetApplicablePaths(g_hModelCache, m_ModelName);
	
	if (list.Length == 0)
	{
		delete list;
		return;
	}
	
	char model[PLATFORM_MAX_PATH];
	if (list.GetString(GetRandomInt(0, list.Length - 1), model, sizeof(model)))
		SetEntProp(entity, Prop_Data, "m_nModelIndexOverrides", PrecacheModel(model));
	
	// Make attachments visible
	if (HasEntProp(entity, Prop_Send, "m_bValidatedAttachedEntity"))
		SetEntProp(entity, Prop_Send, "m_bValidatedAttachedEntity", true);
	
	delete list;
}

static void SDKHookCB_LightSpawnPost(int entity)
{
	SetEntProp(entity, Prop_Send, "m_clrRender", GetRandomColorInt(GetColorAlpha(GetEntProp(entity, Prop_Send, "m_clrRender"))));
}

static void SDKHookCB_FogControllerSpawnPost(int entity)
{
	SetEntProp(entity, Prop_Data, "m_fog.colorPrimary", GetRandomColorInt(GetColorAlpha(GetEntProp(entity, Prop_Send, "m_fog.colorPrimary"))));
	SetEntProp(entity, Prop_Data, "m_fog.colorSecondary", GetRandomColorInt(GetColorAlpha(GetEntProp(entity, Prop_Send, "m_fog.colorSecondary"))));
	SetEntProp(entity, Prop_Data, "m_fog.blend", true);
}

static void SDKHookCB_EnvSunSpawnPost(int entity)
{
	SetEntProp(entity, Prop_Send, "m_clrRender", GetRandomColorInt(GetColorAlpha(GetEntProp(entity, Prop_Send, "m_clrRender"))));
	SetEntProp(entity, Prop_Send, "m_clrOverlay", GetRandomColorInt(GetColorAlpha(GetEntProp(entity, Prop_Send, "m_clrOverlay"))));
}

static void SDKHookCB_ShadowControlSpawnPost(int entity)
{
	SetEntProp(entity, Prop_Data, "m_shadowColor", GetRandomColorInt(GetColorAlpha(GetEntProp(entity, Prop_Send, "m_shadowColor"))));
}

static void SDKHookCB_ParticleSystemSpawnPost(int entity)
{
	int num = GetStringTableNumStrings(g_iParticleEffectNamesTableIdx);
	int stringidx = GetRandomInt(0, num - 1);
	
	char effectName[PLATFORM_MAX_PATH];
	if (GetStringTableEntry(g_iParticleEffectNamesTableIdx, stringidx, effectName, sizeof(effectName)))
		SetEntPropString(entity, Prop_Data, "m_iszEffectName", effectName);
}

static Action NormalSoundHook(int clients[MAXPLAYERS], int &numClients, char sample[PLATFORM_MAX_PATH], int &entity, int &channel, float &volume, int &level, int &pitch, int &flags, char soundEntry[PLATFORM_MAX_PATH], int &seed)
{
	if (!sm_rainbomizer_randomize_sounds.BoolValue)
		return Plugin_Continue;
	
	char filePath[PLATFORM_MAX_PATH];
	GetBaseSoundPath(sample, filePath, sizeof(filePath));
	
	// Voice lines like to call this hook once for every player.
	// To avoid mass-precaching and everyone hearing a different sound, cache sound info for a short time.
	SoundInfo info;
	if (!strncmp(sample, "vo/", 3) && g_hRecentlyReplaced.GetArray(sample, info, sizeof(info)) && info.time + 0.1 > GetGameTime())
	{
		ReplaceString(sample, sizeof(sample), sample, info.replacement[6]);
		return Plugin_Changed;
	}
	else
	{
		ArrayList list = GetApplicablePaths(g_hSoundCache, filePath);
		
		char replacement[PLATFORM_MAX_PATH];
		if (list.Length && list.GetString(GetRandomInt(0, list.Length - 1), replacement, sizeof(replacement)))
		{
			info.time = GetGameTime();
			strcopy(info.replacement, sizeof(info.replacement), replacement);
			g_hRecentlyReplaced.SetArray(sample, info, sizeof(info));
			
			ReplaceString(sample, sizeof(sample), sample, replacement[6]);
			PrecacheSound(sample);
			
			delete list;
			return Plugin_Changed;
		}
		
		delete list;
	}
	
	return Plugin_Continue;
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

void ReadFilesFromKeyValues(const char[] file, ArrayList &list)
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
	// For sounds, we generally just go up one level
	char[] soundPath = new char[length];
	strcopy(soundPath, length, sound);
	GetPreviousDirectoryPath(soundPath);
	
	// Remove sound chars and prepend "sound/"
	strcopy(buffer, length, soundPath);
	SkipSoundChars(buffer, buffer, length);
	Format(buffer, length, "sound/%s", buffer);
}

void IterateDirectoryRecursive(const char[] directory, StringMap cache, ArrayList list)
{
	// Search the directory we are trying to randomize
	DirectoryListing directoryListing = OpenDirectory(directory, true, NULL_STRING);
	if (!directoryListing)
		return;
	
	char file[PLATFORM_MAX_PATH];
	FileType type;
	while (directoryListing.GetNext(file, sizeof(file), type))
	{
		switch (type)
		{
			case FileType_Directory:
			{
				// Don't process special directory names
				if (file[0] == '.')
					continue;
				
				Format(file, sizeof(file), "%s/%s", directory, file);
				
				if (!cache.GetValue(file, list))
					list = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
				
				cache.SetValue(file, list);
				
				IterateDirectoryRecursive(file, cache, list);
			}
			case FileType_File:
			{
				Format(file, sizeof(file), "%s/%s", directory, file);
				
				if (IsValidFile(file))
					list.PushString(file);
			}
		}
	}
	
	delete directoryListing;
}

bool IsValidFile(const char[] filename)
{
	char extension[5];
	if (!strcopy(extension, sizeof(extension), filename[strlen(filename) - 4]))
		return false;
	
	if (StrEqual(extension, ".mp3") || StrEqual(extension, ".wav") && g_hLoopingSounds.FindString(filename) == -1)
		return true;
	
	// Don't use festivizer models as there are far too many
	return StrEqual(extension, ".mdl") && StrContains(filename, "festivizer") == -1 && StrContains(filename, "xmas") == -1 && StrContains(filename, "xms") == -1;
}

void TogglePlugin(bool bEnable)
{
	g_bEnabled = bEnable;
	
	if (bEnable)
	{
		HookEvent("post_inventory_application", EventHook_PostInventoryApplication);
		AddNormalSoundHook(NormalSoundHook);
		
		if (g_hSkyNames.Length != 0)
		{
			char skyname[PLATFORM_MAX_PATH];
			if (g_hSkyNames.GetString(GetRandomInt(0, g_hSkyNames.Length - 1), skyname, sizeof(skyname)))
				DispatchKeyValue(0, "skyname", skyname);
		}
	}
	else
	{
		UnhookEvent("post_inventory_application", EventHook_PostInventoryApplication);
		RemoveNormalSoundHook(NormalSoundHook);
	}
}
