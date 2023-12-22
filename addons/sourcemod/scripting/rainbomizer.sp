#pragma newdecls required
#pragma semicolon 1

#include <sourcemod>
#include <sdkhooks>
#include <sdktools>
#include <tf2utils>

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
	version = "1.0.0", 
	url = "https://github.com/Mikusch/TF2.Rainbomizer"
};

enum struct SoundInfo
{
	float time;
	char replacement[PLATFORM_MAX_PATH];
}

StringMap g_hModelCache;
StringMap g_hSoundCache;
StringMap g_hRecentlyReplaced;

ArrayList blacklistedSounds;

public void OnPluginStart()
{
	g_hModelCache = new StringMap();
	g_hSoundCache = new StringMap();
	g_hRecentlyReplaced = new StringMap();
	
	IterateDirectoryRecursive("models", g_hModelCache, new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH)));
	IterateDirectoryRecursive("sound", g_hSoundCache, new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH)));
	
	AddNormalSoundHook(NormalSoundHook);
	
	
}

public void OnMapStart()
{
	g_hRecentlyReplaced.Clear();
}

public void OnEntityCreated(int entity, const char[] classname)
{
	// Check if this entity is a non-player CBaseAnimating
	if (entity > MaxClients && HasEntProp(entity, Prop_Send, "m_bClientSideAnimation"))
	{
		SDKHook(entity, SDKHook_SpawnPost, SDKHookCB_ModelEntitySpawnPost);
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

public void SDKHookCB_ModelEntitySpawnPost(int entity)
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
	{
		SetEntProp(entity, Prop_Data, "m_nModelIndexOverrides", PrecacheModel(model));
	}
	
	delete list;
}

static Action NormalSoundHook(int clients[MAXPLAYERS], int &numClients, char sample[PLATFORM_MAX_PATH], int &entity, int &channel, float &volume, int &level, int &pitch, int &flags, char soundEntry[PLATFORM_MAX_PATH], int &seed)
{
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
		if (GetReplacementFile(list, replacement, sizeof(replacement)))
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

bool GetReplacementFile(ArrayList list, char[] replacement, int maxlength)
{
	if (list.Length == 0 || !list.GetString(GetRandomInt(0, list.Length - 1), replacement, maxlength))
		return false;
	
	return true;
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
	
	if (StrEqual(extension, ".mp3") || StrEqual(extension, ".wav") && StrContains(filename, "loop") == -1)
		return true;
	
	return StrEqual(extension, ".mdl") && StrContains(filename, "festivizer") == -1 && StrContains(filename, "xmas") == -1 && StrContains(filename, "xms") == -1;
}
