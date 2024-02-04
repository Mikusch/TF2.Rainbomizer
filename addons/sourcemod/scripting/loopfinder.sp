#pragma semicolon 1
#pragma newdecls required

#define CONFIG_PATH	"configs/rainbomizer/looping_sounds.cfg"

int g_numProcessed;

// NOTE:
// This is not a usable plugin. It is used to generate a list of looping sounds.

// - This plugin requires a SlowScriptTimeout of 0 to work properly
// - By default, HL2 sounds are not processed as the sound data is not present in the server VPKs
//   - You can fix this by copying hl2_sound_misc VPKs from the base game to the server

public Plugin myInfo =
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
				
				if (StrEqual(fileExt, "wav"))
				{
					File file = OpenFile(fileName, "rb", true, NULL_STRING);
					if (file)
					{
						int items[4];
						while (file.Read(items, sizeof(items), 1))
						{
							char[] chunkId = new char[4];
							for (int i = 0; i < sizeof(items); i++)
							{
								chunkId[i] = items[i];
							}
							
							// "cue " and "smpl" chunks usually indicate loops
							if (StrEqual(chunkId, "cue ") || StrEqual(chunkId, "smpl"))
							{
								LogMessage("Found looping file: %s", fileName);
								
								char key[8];
								if (IntToString(g_numProcessed++, key, sizeof(key)))
								{
									kv.JumpToKey(key, true);
									kv.SetString(NULL_STRING, fileName);
									kv.GoBack();
								}
								
								delete file;
								break;
							}
						}
					}
					delete file;
				}
			}
		}
	}
	
	delete directoryListing;
}
