#include <sourcemod>
#include <sdktools>
#include <sdktools_hooks>

#pragma semicolon 1
#pragma newdecls required

public Plugin myinfo =
{
    name = "TF2 AC Bot Simulator",
    author = "OpenAI",
    description = "Bot-only synthetic hard-snap and wall-track generator for private anti-cheat calibration.",
    version = "2.1.0",
    url = ""
};

enum SimState
{
    Sim_Idle = 0,
    Sim_Snap,
    Sim_FireHold,
    Sim_WallTrack
};

enum ForcedEvent
{
    Event_Auto = 0,
    Event_Snap,
    Event_Wall
};

ConVar g_Enabled;
ConVar g_TargetHumansOnly;
ConVar g_SnapFovMin;
ConVar g_SnapFovMax;
ConVar g_SnapTicksMin;
ConVar g_SnapTicksMax;
ConVar g_FireTicks;
ConVar g_EventMin;
ConVar g_EventMax;
ConVar g_WallEnabled;
ConVar g_WallFov;
ConVar g_WallDuration;
ConVar g_GroundTruth;

bool g_BotEnabled[MAXPLAYERS + 1];
SimState g_State[MAXPLAYERS + 1];
ForcedEvent g_Forced[MAXPLAYERS + 1];
int g_Target[MAXPLAYERS + 1];
int g_LastTarget[MAXPLAYERS + 1];
int g_SnapTick[MAXPLAYERS + 1];
int g_SnapTicksTotal[MAXPLAYERS + 1];
int g_FireTicksLeft[MAXPLAYERS + 1];
float g_SnapStart[MAXPLAYERS + 1][3];
float g_NextEvent[MAXPLAYERS + 1];
float g_WallEnds[MAXPLAYERS + 1];
char g_LogPath[PLATFORM_MAX_PATH];

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int errMax)
{
    char game[32];
    GetGameFolderName(game, sizeof(game));
    if (!StrEqual(game, "tf", false))
    {
        strcopy(error, errMax, "TF2 AC Bot Simulator supports Team Fortress 2 only.");
        return APLRes_Failure;
    }
    return APLRes_Success;
}

public void OnPluginStart()
{
    g_Enabled = CreateConVar("sm_acsim_enabled", "1", "Master switch.", FCVAR_NONE, true, 0.0, true, 1.0);
    g_TargetHumansOnly = CreateConVar("sm_acsim_target_humans_only", "1", "Test bots target real players only.", FCVAR_NONE, true, 0.0, true, 1.0);
    g_SnapFovMin = CreateConVar("sm_acsim_snap_fov_min", "24.0", "Minimum angle for a snap target.", FCVAR_NONE, true, 1.0, true, 90.0);
    g_SnapFovMax = CreateConVar("sm_acsim_snap_fov_max", "40.0", "Maximum angle for a snap target.", FCVAR_NONE, true, 2.0, true, 120.0);
    g_SnapTicksMin = CreateConVar("sm_acsim_snap_ticks_min", "1", "Minimum snap duration in ticks.", FCVAR_NONE, true, 1.0, true, 8.0);
    g_SnapTicksMax = CreateConVar("sm_acsim_snap_ticks_max", "3", "Maximum snap duration in ticks.", FCVAR_NONE, true, 1.0, true, 8.0);
    g_FireTicks = CreateConVar("sm_acsim_fire_ticks", "2", "Ticks to hold primary attack after snap.", FCVAR_NONE, true, 1.0, true, 12.0);
    g_EventMin = CreateConVar("sm_acsim_event_interval_min", "45.0", "Minimum normal-behavior interval.", FCVAR_NONE, true, 1.0, true, 600.0);
    g_EventMax = CreateConVar("sm_acsim_event_interval_max", "90.0", "Maximum normal-behavior interval.", FCVAR_NONE, true, 1.0, true, 900.0);
    g_WallEnabled = CreateConVar("sm_acsim_wall_enabled", "1", "Enable bot-only hidden-target tracking scenario.", FCVAR_NONE, true, 0.0, true, 1.0);
    g_WallFov = CreateConVar("sm_acsim_wall_fov", "45.0", "Maximum angle for a hidden target.", FCVAR_NONE, true, 1.0, true, 120.0);
    g_WallDuration = CreateConVar("sm_acsim_wall_duration", "0.75", "Hidden-target tracking duration.", FCVAR_NONE, true, 0.10, true, 3.0);
    g_GroundTruth = CreateConVar("sm_acsim_groundtruth_log", "1", "Write synthetic ground-truth log.", FCVAR_NONE, true, 0.0, true, 1.0);

    RegAdminCmd("sm_acsimbot", Command_SimBot, ADMFLAG_ROOT, "sm_acsimbot <bot> <on|off>");
    RegAdminCmd("sm_acsimtrigger", Command_Trigger, ADMFLAG_ROOT, "sm_acsimtrigger <bot> <auto|snap|wall>");
    RegAdminCmd("sm_acsimstatus", Command_Status, ADMFLAG_GENERIC, "Show controlled test bots.");
    RegAdminCmd("sm_acsimalloff", Command_AllOff, ADMFLAG_ROOT, "Disable simulation on every bot.");

    HookEvent("player_death", Event_PlayerDeath, EventHookMode_Post);
    BuildPath(Path_SM, g_LogPath, sizeof(g_LogPath), "logs/tf2_ac_sim_groundtruth.log");
    AutoExecConfig(true, "tf2_ac_bot_simulator");

    for (int i = 1; i <= MaxClients; i++)
    {
        ResetClient(i);
    }
}

public void OnMapStart()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        ResetClient(i);
    }
}

public void OnClientPutInServer(int client)
{
    ResetClient(client);
}

public void OnClientDisconnect(int client)
{
    ResetClient(client);
}

void ResetClient(int client)
{
    g_BotEnabled[client] = false;
    g_State[client] = Sim_Idle;
    g_Forced[client] = Event_Auto;
    g_Target[client] = 0;
    g_LastTarget[client] = 0;
    g_SnapTick[client] = 0;
    g_SnapTicksTotal[client] = 0;
    g_FireTicksLeft[client] = 0;
    g_NextEvent[client] = 0.0;
    g_WallEnds[client] = 0.0;
    g_SnapStart[client][0] = 0.0;
    g_SnapStart[client][1] = 0.0;
    g_SnapStart[client][2] = 0.0;
}

public Action Command_SimBot(int client, int args)
{
    if (args < 2)
    {
        ReplyToCommand(client, "[AC-SIM] Usage: sm_acsimbot <bot> <on|off>");
        return Plugin_Handled;
    }

    char pattern[64], mode[16];
    GetCmdArg(1, pattern, sizeof(pattern));
    GetCmdArg(2, mode, sizeof(mode));

    bool enable;
    if (StrEqual(mode, "on", false) || StrEqual(mode, "1"))
    {
        enable = true;
    }
    else if (StrEqual(mode, "off", false) || StrEqual(mode, "0"))
    {
        enable = false;
    }
    else
    {
        ReplyToCommand(client, "[AC-SIM] Mode must be on or off.");
        return Plugin_Handled;
    }

    int targets[MAXPLAYERS];
    char targetName[MAX_TARGET_LENGTH];
    bool targetNameIsML;
    int count = ProcessTargetString(pattern, client, targets, sizeof(targets), COMMAND_FILTER_CONNECTED, targetName, sizeof(targetName), targetNameIsML);
    if (count <= 0)
    {
        ReplyToTargetError(client, count);
        return Plugin_Handled;
    }

    int changed = 0;
    for (int i = 0; i < count; i++)
    {
        int bot = targets[i];
        if (!IsClientInGame(bot) || !IsFakeClient(bot))
        {
            ReplyToCommand(client, "[AC-SIM] %N skipped: fake clients only.", bot);
            continue;
        }
        SetBotEnabled(bot, enable);
        changed++;
    }

    ReplyToCommand(client, "[AC-SIM] %d bot(s) updated.", changed);
    return Plugin_Handled;
}

public Action Command_Trigger(int client, int args)
{
    if (args < 1)
    {
        ReplyToCommand(client, "[AC-SIM] Usage: sm_acsimtrigger <bot> <auto|snap|wall>");
        return Plugin_Handled;
    }

    char pattern[64], kindText[16];
    GetCmdArg(1, pattern, sizeof(pattern));
    strcopy(kindText, sizeof(kindText), "auto");
    if (args >= 2)
    {
        GetCmdArg(2, kindText, sizeof(kindText));
    }

    ForcedEvent kind = Event_Auto;
    if (StrEqual(kindText, "snap", false)) kind = Event_Snap;
    else if (StrEqual(kindText, "wall", false)) kind = Event_Wall;
    else if (!StrEqual(kindText, "auto", false))
    {
        ReplyToCommand(client, "[AC-SIM] Type must be auto, snap or wall.");
        return Plugin_Handled;
    }

    int targets[MAXPLAYERS];
    char targetName[MAX_TARGET_LENGTH];
    bool targetNameIsML;
    int count = ProcessTargetString(pattern, client, targets, sizeof(targets), COMMAND_FILTER_CONNECTED, targetName, sizeof(targetName), targetNameIsML);
    if (count <= 0)
    {
        ReplyToTargetError(client, count);
        return Plugin_Handled;
    }

    int queued = 0;
    for (int i = 0; i < count; i++)
    {
        int bot = targets[i];
        if (!IsControlledBot(bot))
        {
            continue;
        }
        g_Forced[bot] = kind;
        g_State[bot] = Sim_Idle;
        g_Target[bot] = 0;
        g_NextEvent[bot] = GetEngineTime();
        queued++;
    }

    ReplyToCommand(client, "[AC-SIM] %d event(s) queued.", queued);
    return Plugin_Handled;
}

public Action Command_Status(int client, int args)
{
    ReplyToCommand(client, "[AC-SIM] Controlled bots:");
    int found = 0;
    for (int bot = 1; bot <= MaxClients; bot++)
    {
        if (!IsControlledBot(bot)) continue;
        ReplyToCommand(client, "  %N state=%d target=%d next=%.1fs", bot, view_as<int>(g_State[bot]), g_Target[bot], MaxF(0.0, g_NextEvent[bot] - GetEngineTime()));
        found++;
    }
    if (found == 0) ReplyToCommand(client, "  none");
    return Plugin_Handled;
}

public Action Command_AllOff(int client, int args)
{
    int changed = 0;
    for (int bot = 1; bot <= MaxClients; bot++)
    {
        if (g_BotEnabled[bot])
        {
            SetBotEnabled(bot, false);
            changed++;
        }
    }
    ReplyToCommand(client, "[AC-SIM] Disabled on %d bot(s).", changed);
    return Plugin_Handled;
}

void SetBotEnabled(int bot, bool enable)
{
    g_BotEnabled[bot] = enable;
    g_State[bot] = Sim_Idle;
    g_Forced[bot] = Event_Auto;
    g_Target[bot] = 0;
    g_LastTarget[bot] = 0;
    if (enable)
    {
        ScheduleNext(bot);
        LogTruth(bot, "sim_enabled", 0, 0.0, 0);
    }
    else
    {
        g_NextEvent[bot] = 0.0;
        LogTruth(bot, "sim_disabled", 0, 0.0, 0);
    }
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    int victim = GetClientOfUserId(event.GetInt("userid"));
    if (!IsControlledBot(attacker) || attacker == victim) return;

    g_LastTarget[attacker] = victim;
    g_Forced[attacker] = Event_Snap;
    g_State[attacker] = Sim_Idle;
    g_Target[attacker] = 0;
    g_NextEvent[attacker] = GetEngineTime();
    LogTruth(attacker, "kill_switch_queued", victim, 0.0, 0);
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2])
{
    if (!g_Enabled.BoolValue || !IsControlledBot(client) || !IsPlayerAlive(client))
    {
        return Plugin_Continue;
    }

    float now = GetEngineTime();
    bool changed = false;

    if (g_State[client] == Sim_Idle && now >= g_NextEvent[client])
    {
        if (!TryBeginEvent(client, angles))
        {
            g_NextEvent[client] = now + 1.0;
        }
    }

    if (g_State[client] == Sim_Snap)
    {
        int target = g_Target[client];
        if (!IsValidEnemy(client, target) || !IsWorldVisible(client, target))
        {
            EndEvent(client, "snap_target_lost");
            return Plugin_Continue;
        }

        float aim[3];
        GetAimAngles(client, target, aim);
        g_SnapTick[client]++;
        float fraction = float(g_SnapTick[client]) / float(g_SnapTicksTotal[client]);
        if (fraction > 1.0) fraction = 1.0;

        angles[0] = LerpAngle(g_SnapStart[client][0], aim[0], fraction);
        angles[1] = LerpAngle(g_SnapStart[client][1], aim[1], fraction);
        angles[2] = 0.0;
        changed = true;

        if (g_SnapTick[client] >= g_SnapTicksTotal[client])
        {
            buttons |= IN_ATTACK;
            changed = true;
            g_State[client] = Sim_FireHold;
            g_FireTicksLeft[client] = ClampInt(g_FireTicks.IntValue, 1, 12);
            LogTruth(client, "snap_commit", target, AngleDistance(g_SnapStart[client], aim), g_SnapTicksTotal[client]);
        }
    }
    else if (g_State[client] == Sim_FireHold)
    {
        int target = g_Target[client];
        if (!IsValidEnemy(client, target) || !IsWorldVisible(client, target))
        {
            EndEvent(client, "fire_target_lost");
            return Plugin_Continue;
        }

        float aim[3];
        GetAimAngles(client, target, aim);
        angles[0] = aim[0];
        angles[1] = aim[1];
        angles[2] = 0.0;
        buttons |= IN_ATTACK;
        changed = true;

        g_FireTicksLeft[client]--;
        if (g_FireTicksLeft[client] <= 0)
        {
            EndEvent(client, "snap_complete");
        }
    }
    else if (g_State[client] == Sim_WallTrack)
    {
        int target = g_Target[client];
        if (!IsValidEnemy(client, target) || IsWorldVisible(client, target) || now >= g_WallEnds[client])
        {
            EndEvent(client, "wall_complete");
            return Plugin_Continue;
        }

        float aim[3];
        GetAimAngles(client, target, aim);
        angles[0] = aim[0];
        angles[1] = aim[1];
        angles[2] = 0.0;
        buttons &= ~IN_ATTACK;
        changed = true;
    }

    return changed ? Plugin_Changed : Plugin_Continue;
}

bool TryBeginEvent(int client, const float currentAngles[3])
{
    ForcedEvent kind = g_Forced[client];
    g_Forced[client] = Event_Auto;

    if (kind == Event_Auto)
    {
        if (g_WallEnabled.BoolValue && GetRandomInt(0, 1) == 1)
            kind = Event_Wall;
        else
            kind = Event_Snap;
    }

    if (kind == Event_Wall && g_WallEnabled.BoolValue)
    {
        int target = FindTarget(client, currentAngles, 0.0, g_WallFov.FloatValue, false, true);
        if (target != 0)
        {
            g_Target[client] = target;
            g_State[client] = Sim_WallTrack;
            g_WallEnds[client] = GetEngineTime() + g_WallDuration.FloatValue;
            LogTruth(client, "wall_begin", target, AngleToTarget(client, target, currentAngles), 0);
            return true;
        }
    }

    int target = FindTarget(client, currentAngles, g_SnapFovMin.FloatValue, g_SnapFovMax.FloatValue, true, false);
    if (target == 0) return false;

    g_Target[client] = target;
    g_State[client] = Sim_Snap;
    g_SnapTick[client] = 0;
    g_SnapTicksTotal[client] = RandomIntRange(g_SnapTicksMin.IntValue, g_SnapTicksMax.IntValue);
    g_SnapStart[client][0] = currentAngles[0];
    g_SnapStart[client][1] = currentAngles[1];
    g_SnapStart[client][2] = 0.0;
    LogTruth(client, "snap_begin", target, AngleToTarget(client, target, currentAngles), g_SnapTicksTotal[client]);
    return true;
}

void EndEvent(int client, const char[] reason)
{
    LogTruth(client, reason, g_Target[client], 0.0, 0);
    g_State[client] = Sim_Idle;
    g_Target[client] = 0;
    g_SnapTick[client] = 0;
    g_FireTicksLeft[client] = 0;
    g_WallEnds[client] = 0.0;
    ScheduleNext(client);
}

void ScheduleNext(int client)
{
    float minDelay = g_EventMin.FloatValue;
    float maxDelay = g_EventMax.FloatValue;
    if (maxDelay < minDelay)
    {
        float temp = minDelay;
        minDelay = maxDelay;
        maxDelay = temp;
    }
    g_NextEvent[client] = GetEngineTime() + GetRandomFloat(minDelay, maxDelay);
}

int FindTarget(int client, const float viewAngles[3], float minAngle, float maxAngle, bool requireVisible, bool requireHidden)
{
    int best = 0;
    float bestAngle = maxAngle + 1.0;

    for (int target = 1; target <= MaxClients; target++)
    {
        if (!IsValidEnemy(client, target) || target == g_LastTarget[client]) continue;
        if (g_TargetHumansOnly.BoolValue && IsFakeClient(target)) continue;

        bool visible = IsWorldVisible(client, target);
        if (requireVisible && !visible) continue;
        if (requireHidden && visible) continue;

        float aim[3];
        GetAimAngles(client, target, aim);
        float angle = AngleDistance(viewAngles, aim);
        if (angle < minAngle || angle > maxAngle) continue;
        if (angle < bestAngle)
        {
            best = target;
            bestAngle = angle;
        }
    }

    if (best == 0 && g_LastTarget[client] != 0)
    {
        g_LastTarget[client] = 0;
        return FindTarget(client, viewAngles, minAngle, maxAngle, requireVisible, requireHidden);
    }

    return best;
}

bool IsControlledBot(int client)
{
    return client >= 1 && client <= MaxClients && g_BotEnabled[client] && IsClientInGame(client) && IsFakeClient(client);
}

bool IsValidEnemy(int client, int target)
{
    if (target < 1 || target > MaxClients || !IsClientInGame(target) || !IsPlayerAlive(target)) return false;
    int a = GetClientTeam(client);
    int b = GetClientTeam(target);
    return a >= 2 && b >= 2 && a != b;
}

void GetAimAngles(int client, int target, float output[3])
{
    float start[3], end[3], direction[3];
    GetClientEyePosition(client, start);
    GetClientEyePosition(target, end);
    end[2] -= 4.0;
    MakeVectorFromPoints(start, end, direction);
    GetVectorAngles(direction, output);
    output[0] = ClampF(NormalizeAngle(output[0]), -89.0, 89.0);
    output[1] = NormalizeAngle(output[1]);
    output[2] = 0.0;
}

bool IsWorldVisible(int client, int target)
{
    float start[3], end[3];
    GetClientEyePosition(client, start);
    GetClientEyePosition(target, end);
    end[2] -= 4.0;

    Handle trace = TR_TraceRayFilterEx(start, end, MASK_SHOT, RayType_EndPoint, TraceFilter_IgnorePlayers, client);
    bool visible = TR_GetFraction(trace) > 0.97;
    delete trace;
    return visible;
}

public bool TraceFilter_IgnorePlayers(int entity, int contentsMask, any data)
{
    if (entity >= 1 && entity <= MaxClients) return false;
    return true;
}

float AngleToTarget(int client, int target, const float currentAngles[3])
{
    float aim[3];
    GetAimAngles(client, target, aim);
    return AngleDistance(currentAngles, aim);
}

float AngleDistance(const float a[3], const float b[3])
{
    float pitch = NormalizeAngle(b[0] - a[0]);
    float yaw = NormalizeAngle(b[1] - a[1]);
    return SquareRoot((pitch * pitch) + (yaw * yaw));
}

float NormalizeAngle(float angle)
{
    while (angle > 180.0) angle -= 360.0;
    while (angle < -180.0) angle += 360.0;
    return angle;
}

float LerpAngle(float start, float target, float fraction)
{
    return NormalizeAngle(start + NormalizeAngle(target - start) * fraction);
}

int RandomIntRange(int a, int b)
{
    if (b < a)
    {
        int temp = a;
        a = b;
        b = temp;
    }
    return GetRandomInt(ClampInt(a, 1, 8), ClampInt(b, 1, 8));
}

int ClampInt(int value, int minValue, int maxValue)
{
    if (value < minValue) return minValue;
    if (value > maxValue) return maxValue;
    return value;
}

float ClampF(float value, float minValue, float maxValue)
{
    if (value < minValue) return minValue;
    if (value > maxValue) return maxValue;
    return value;
}

float MaxF(float a, float b)
{
    return a > b ? a : b;
}

void LogTruth(int client, const char[] eventName, int target, float angle, int ticks)
{
    if (!g_GroundTruth.BoolValue) return;
    LogToFileEx(g_LogPath, "synthetic=1 actor=\"%N\" userid=%d event=%s target=%d angle=%.2f ticks=%d", client, GetClientUserId(client), eventName, target, angle, ticks);
}
