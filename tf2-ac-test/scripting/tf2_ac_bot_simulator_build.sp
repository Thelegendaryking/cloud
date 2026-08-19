#include <sourcemod>
#include <sdktools>
#include <sdktools_hooks>

// SourceMod already owns a FindTarget symbol. Load its includes first, then
// remap only the implementation helper while compiling this test plugin.
#define FindTarget FindSimTarget
#include "tf2_ac_bot_simulator.sp"
