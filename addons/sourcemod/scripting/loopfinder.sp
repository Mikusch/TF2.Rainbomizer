#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

#define CONFIG_PATH		"configs/rainbomizer/looping_sounds.cfg"

int g_numProcessed;

// NOTE:
// This is not a usable plugin. It is used to generate a list of looping sounds.

// - By default, HL2 sounds are not processed as the sound data is not present in the server VPKs
//   - You can fix this by copying hl2_sound_misc VPKs from the base game to the server

public Plugin myinfo =
{
	name = "Looping Sound Finder",
	author = "Mikusch",
	description = "Finds and creates a list of looping sounds.",
	version = "1.0.0",
	url = "https://github.com/Mikusch/TF2.Rainbomizer"
};

public void OnPluginStart()
{
	KeyValues kv = new KeyValues("sounds");
	IterateDirectoryRecursive("sound", kv);
	
	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), CONFIG_PATH);
	
	kv.Rewind();
	if (kv.ExportToFile(path))
	{
		LogMessage("Wrote to path '%s'", path);
	}
	else
	{
		LogError("Failed to write to path '%s'", path);
	}
	
	delete kv;
}

void IterateDirectoryRecursive(const char[] directory, KeyValues kv)
{
	DirectoryListing directoryListing = OpenDirectory(directory, true, NULL_STRING);
	if (!directoryListing)
		return;
	
	char fileName[PLATFORM_MAX_PATH];
	FileType type;
	while (directoryListing.GetNext(fileName, sizeof(fileName), type))
	{
		switch (type)
		{
			case FileType_Directory:
			{
				if (fileName[0] == '.')
					continue;
				
				Format(fileName, sizeof(fileName), "%s/%s", directory, fileName);
				
				IterateDirectoryRecursive(fileName, kv);
			}
			case FileType_File:
			{
				Format(fileName, sizeof(fileName), "%s/%s", directory, fileName);
				
				char fileExt[4];
				if (!strcopy(fileExt, sizeof(fileExt), fileName[strlen(fileName) - 3]))
					continue;
				
				if (StrEqual(fileExt, "wav") && IsLoopingWav(fileName))
				{
					LogMessage("Found looping file: %s", fileName);

					char key[8];
					if (IntToString(g_numProcessed++, key, sizeof(key)))
					{
						kv.JumpToKey(key, true);
						kv.SetString(NULL_STRING, fileName);
						kv.GoBack();
					}
				}
			}
		}
	}
	
	delete directoryListing;
}

bool IsLoopingWav(const char[] fileName)
{
	File file = OpenFile(fileName, "rb", true, NULL_STRING);
	if (!file)
		return false;

	bool looping = false;

	char id[5];
	int size;
	if (ReadChunkId(file, id) && StrEqual(id, "RIFF") && ReadInt32(file, size) && ReadChunkId(file, id) && StrEqual(id, "WAVE"))
	{
		while (!looping && ReadChunkId(file, id) && ReadInt32(file, size))
		{
			int pos = file.Position;
			int next = pos + size + (size & 1);

			if (StrEqual(id, "cue "))
			{
				int cueCount;
				if (ReadInt32(file, cueCount) && cueCount > 0)
					looping = true;
			}
			else if (StrEqual(id, "smpl"))
			{
				// smpl body dwords: 0-6 header, 7 = cSampleLoops, 8 = cbSamplerData,
				// then the loop records (9 = dwIdentifier, 10 = dwType, ...).
				// A dwType of 0 is a forward loop.
				int sampleLoops;
				if (file.Seek(pos + 7 * 4, SEEK_SET) && ReadInt32(file, sampleLoops) && sampleLoops > 0)
				{
					int loopType;
					if (file.Seek(pos + 10 * 4, SEEK_SET) && ReadInt32(file, loopType) && loopType == 0)
						looping = true;
				}
			}

			if (!file.Seek(next, SEEK_SET))
				break;
		}
	}

	delete file;
	return looping;
}

bool ReadChunkId(File file, char id[5])
{
	int bytes[4];
	if (file.Read(bytes, 4, 1) != 4)
		return false;

	id[0] = bytes[0];
	id[1] = bytes[1];
	id[2] = bytes[2];
	id[3] = bytes[3];
	id[4] = '\0';
	return true;
}

bool ReadInt32(File file, int &value)
{
	int buffer[1];
	if (file.Read(buffer, 1, 4) != 1)
		return false;

	value = buffer[0];
	return true;
}
