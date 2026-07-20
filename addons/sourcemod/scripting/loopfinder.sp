#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

#define CONFIG_PATH		"configs/rainbomizer/looping_sounds.cfg"

int g_numProcessed;

// NOTE:
// This is not a usable plugin. It is used to generate a list of looping sounds.

// - This plugin requires a SlowScriptTimeout of 0 to work properly
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
	if (ReadChunkId(file, id) && StrEqual(id, "RIFF"))
	{
		file.Seek(4, SEEK_CUR);		// RIFF chunk size
		if (ReadChunkId(file, id) && StrEqual(id, "WAVE"))
		{
			int size;
			while (!looping && ReadChunkId(file, id) && ReadInt32(file, size))
			{
				// Chunks are word-aligned, so an odd size carries a pad byte.
				int next = file.Position + size + (size & 1);

				if (StrEqual(id, "cue "))
				{
					int cueCount;
					if (ReadInt32(file, cueCount) && cueCount > 0)
						looping = true;
				}
				else if (StrEqual(id, "smpl"))
				{
					file.Seek(7 * 4, SEEK_CUR);		// skip to cSampleLoops

					int sampleLoops;
					if (ReadInt32(file, sampleLoops) && sampleLoops > 0)
					{
						file.Seek(2 * 4, SEEK_CUR);	// skip cbSamplerData + Loops[0].dwIdentifier

						int loopType;
						if (ReadInt32(file, loopType) && loopType == 0)
							looping = true;			// only forward loops actually loop
					}
				}

				file.Seek(next, SEEK_SET);
			}
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
