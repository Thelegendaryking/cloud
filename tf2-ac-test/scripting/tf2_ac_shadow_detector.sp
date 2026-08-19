#include <sourcemod>
#include <sdktools>
#include <sdktools_hooks>

#pragma semicolon 1
#pragma newdecls required

public Plugin myinfo =
{
    name = "TF2 AC Shadow Detector",
    author = "OpenAI",
    description = "Independent shadow-mode detector for hard snap, hidden lock and fast target switch calibration.",
    version = "2.1.0",
    url = ""
};

ConVar g_Enabled;
ConVar g_BotsOnly;
ConVar g_SnapDegrees;
ConVar g_SnapHitWindow;
ConVar g_SnapScore;
ConVar g_WallCone;
ConVar g_WallHold;
ConVar g_WallScore;
ConVar g_WallScanInterval;
ConVar g_SwitchWindow;
ConVar g_SwitchScore;
ConVar g_Threshold;
ConVar g_AdminAlerts;

float g_LastAngles[MAXPLAYERS + 1][3];
bool g_HaveAngles[MAXPLAYERS + 1];
float g_LastSnapAt[MAXPLAYERS + 1];
float g_LastSnapDegrees[MAXPLAYERS + 1];
int g_HiddenTarget[MAXPLAYERS + 1];
float g_HiddenLockStarted[MAXPLAYERS + 1];
bool g_HiddenLockFlagged[MAXPLAYERS + 1];
float g_NextWallScan[MAXPLAYERS + 1];
float g_LastKillAt[MAXPLAYERS + 1];
int g_LastKilledVictim[MAXPLAYERS + 1];
int g_Score[MAXPLAYERS + 1];
bool g_ThresholdAnnounced[MAXPLAYERS + 1];
char g_LogPath[PLATFORM_MAX_PATH];

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int errMax)
{
    char game[32];
    GetGameFolderName(game, sizeof(game));
    if (!StrEqual(game, "tf", false))
    {
        strcopy(error, errMax, "TF2 AC Shadow Detector supports Team Fortress 2 only.");
        return APLRes_Failure;
    }
    return APLRes_Success;
}

public void OnPluginStart()
{
    g_Enabled = CreateConVar("sm_acdet_enabled", "1", "Master switch.", FCVAR_NONE, true, 0.0, true, 1.0);
    g_BotsOnly = CreateConVar("sm_acdet_bots_only", "1", "Score fake clients only during calibration.", FCVAR_NONE, true, 0.0, true, 1.0);
    g_SnapDegrees = CreateConVar("sm_acdet_snap_degrees", "7.5", "Minimum single-tick angle delta for a snap candidate.", FCVAR_NONE, true, 1.0, true, 180.0);
    g_SnapHitWindow = CreateConVar("sm_acdet_snap_hit_window", "0.30", "Hit correlation window after a hard snap.", FCVAR_NONE, true, 0.01, true, 1.0);
    g_SnapScore = CreateConVar("sm_acdet_snap_score", "45", "Score for snap then hit.", FCVAR_NONE, true, 1.0, true, 100.0);
    g_WallCone = CreateConVar("sm_acdet_wall_cone", "1.75", "Crosshair cone for hidden-target lock.", FCVAR_NONE, true, 0.10, true, 10.0);
    g_WallHold = CreateConVar("sm_acdet_wall_hold", "0.45", "Continuous hidden lock duration required.", FCVAR_NONE, true, 0.05, true, 3.0);
    g_WallScore = CreateConVar("sm_acdet_wall_score", "60", "Score for one hidden lock.", FCVAR_NONE, true, 1.0, true, 100.0);
    g_WallScanInterval = CreateConVar("sm_acdet_wall_scan_interval", "0.05", "Hidden-target scan interval.", FCVAR_NONE, true, 0.01, true, 0.25);
    g_SwitchWindow = CreateConVar("sm_acdet_switch_window", "0.45", "Damage-to-new-target window after a kill.", FCVAR_NONE, true, 0.05, true, 2.0);
    g_SwitchScore = CreateConVar("sm_acdet_switch_score", "30", "Score for a fast post-kill switch.", FCVAR_NONE, true, 1.0, true, 100.0);
    g_Threshold = CreateConVar("sm_acdet_threshold", "100", "Shadow WOULD-BAN threshold.", FCVAR_NONE, true, 1.0, true, 1000.0);
    g_AdminAlerts = CreateConVar("sm_acdet_admin_alerts", "1", "Show flags to online admins.", FCVAR_NONE, true, 0.0, true, 1.0);

    RegAdminCmd("sm_acdetstatus", Command_Status, ADMFLAG_GENERIC, "sm_acdetstatus [target]");
    RegAdminCmd("sm_acdetreset", Command_Reset, ADMFLAG_ROOT, "sm_acdetreset <target>");
    RegAdminCmd("sm_acdetmode", Command_Mode, ADMFLAG_ROOT, "sm_acdetmode <bots|all>");

    HookEvent("player_hurt", Event_PlayerHurt, EventHookMode_Post);
    HookEvent("player_death", Event_PlayerDeath, EventHookMode_Post);
    BuildPath(Path_SM, g_LogPath, sizeof(g_LogPath), "logs/tf2_ac_shadow_detector.log");
    AutoExecConfig(true, "tf2_ac_shadow_detector");

    for (int i = 1; i <= MaxClients; i++)
    {
        ResetClient(i, true);
    }
}

public void OnMapStart()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        ResetClient(i, true);
    }
}

public void OnClientPutInServer(int client)
{
    ResetClient(client, true);
}

public void OnClientDisconnect(int client)
{
    ResetClient(client, true);
}

void ResetClient(int client, bool resetScore)
{
    g_HaveAngles[client] = false;
    g_LastAngles[client][0] = 0.0;
    g_LastAngles[client][1] = 0.0;
    g_LastAngles[client][2] = 0.0;
    g_LastSnapAt[client] = 0.0;
    g_LastSnapDegrees[client] = 0.0;
    g_HiddenTarget[client] = 0;
    g_HiddenLockStarted[client] = 0.0;
    g_HiddenLockFlagged[client] = false;
    g_NextWallScan[client] = 0.0;
    g_LastKillAt[client] = 0.0;
    g_LastKilledVictim[client] = 0;
    if (resetScore)
    {
        g_Score[client] = 0;
        g_ThresholdAnnounced[client] = false;
    }
}

public void OnPlayerRunCmdPost(int client, int buttons, int impulse, const float vel[3], const float angles[3], int weapon, int subtype, int cmdnum, int tickcount, int seed, const int mouse[2])
{
    if (!ShouldObserve(client) || !IsPlayerAlive(client)) return;

    float now = GetEngineTime();
    if (g_HaveAngles[client])
    {
        float delta = AngleDistance(g_LastAngles[client], angles);
        if (delta >= g_SnapDegrees.FloatValue)
        {
            g_LastSnapAt[client] = now;
            g_LastSnapDegrees[client] = delta;
        }
    }

    g_LastAngles[client][0] = angles[0];
    g_LastAngles[client][1] = angles[1];
    g_LastAngles[client][2] = 0.0;
    g_HaveAngles[client] = true;

    if (now >= g_NextWallScan[client])
    {
        UpdateHiddenLock(client, angles, now);
        g_NextWallScan[client] = now + g_WallScanInterval.FloatValue;
    }
}

void UpdateHiddenLock(int client, const float viewAngles[3], float now)
{
    int hidden = FindHiddenTargetNearAim(client, viewAngles, g_WallCone.FloatValue);
    if (hidden == 0)
    {
        g_HiddenTarget[client] = 0;
        g_HiddenLockStarted[client] = 0.0;
        g_HiddenLockFlagged[client] = false;
        return;
    }

    if (g_HiddenTarget[client] != hidden)
    {
        g_HiddenTarget[client] = hidden;
        g_HiddenLockStarted[client] = now;
        g_HiddenLockFlagged[client] = false;
        return;
    }

    if (!g_HiddenLockFlagged[client] && now - g_HiddenLockStarted[client] >= g_WallHold.FloatValue)
    {
        char detail[192];
        Format(detail, sizeof(detail), "hidden_lock target=\"%N\" duration=%.3fs cone<=%.2fdeg", hidden, now - g_HiddenLockStarted[client], g_WallCone.FloatValue);
        AddFlag(client, g_WallScore.IntValue, "wall_lock", detail);
        g_HiddenLockFlagged[client] = true;
    }
}

public void Event_PlayerHurt(Event event, const char[] name, bool dontBroadcast)
{
    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    int victim = GetClientOfUserId(event.GetInt("userid"));
    if (!ShouldObserve(attacker) || attacker == victim) return;

    float now = GetEngineTime();
    float sinceSnap = now - g_LastSnapAt[attacker];
    if (g_LastSnapAt[attacker] > 0.0 && sinceSnap >= 0.0 && sinceSnap <= g_SnapHitWindow.FloatValue)
    {
        char detail[192];
        Format(detail, sizeof(detail), "snap_hit victim=\"%N\" snap=%.2fdeg delay=%.3fs", victim, g_LastSnapDegrees[attacker], sinceSnap);
        AddFlag(attacker, g_SnapScore.IntValue, "snap_hit", detail);
        g_LastSnapAt[attacker] = 0.0;
        g_LastSnapDegrees[attacker] = 0.0;
    }

    float sinceKill = now - g_LastKillAt[attacker];
    if (g_LastKillAt[attacker] > 0.0 && victim != g_LastKilledVictim[attacker] && sinceKill >= 0.0 && sinceKill <= g_SwitchWindow.FloatValue)
    {
        char detail[192];
        Format(detail, sizeof(detail), "fast_switch previous_victim_index=%d new_target=\"%N\" delay=%.3fs", g_LastKilledVictim[attacker], victim, sinceKill);
        AddFlag(attacker, g_SwitchScore.IntValue, "fast_switch", detail);
        g_LastKillAt[attacker] = 0.0;
        g_LastKilledVictim[attacker] = 0;
    }
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    int victim = GetClientOfUserId(event.GetInt("userid"));
    if (!ShouldObserve(attacker) || attacker == victim) return;
    g_LastKillAt[attacker] = GetEngineTime();
    g_LastKilledVictim[attacker] = victim;
}

void AddFlag(int client, int amount, const char[] flagName, const char[] detail)
{
    g_Score[client] += amount;

    LogToFileEx(g_LogPath, "observed=1 player=\"%N\" userid=%d fake=%d flag=%s amount=%d score=%d detail={%s}", client, GetClientUserId(client), IsFakeClient(client) ? 1 : 0, flagName, amount, g_Score[client], detail);
    PrintToServer("[AC-DETECT] %N | %s | +%d | score=%d | %s", client, flagName, amount, g_Score[client], detail);

    if (g_AdminAlerts.BoolValue)
    {
        for (int admin = 1; admin <= MaxClients; admin++)
        {
            if (!IsClientInGame(admin) || IsFakeClient(admin)) continue;
            if (CheckCommandAccess(admin, "tf2_ac_detector_alerts", ADMFLAG_GENERIC, true))
            {
                PrintToChat(admin, "[AC-DETECT] %N: %s (+%d), score=%d", client, flagName, amount, g_Score[client]);
            }
        }
    }

    if (!g_ThresholdAnnounced[client] && g_Score[client] >= g_Threshold.IntValue)
    {
        g_ThresholdAnnounced[client] = true;
        LogToFileEx(g_LogPath, "decision=WOULD-BAN player=\"%N\" userid=%d score=%d threshold=%d real_ban=0", client, GetClientUserId(client), g_Score[client], g_Threshold.IntValue);
        PrintToServer("[AC-DETECT] WOULD-BAN %N | score=%d | real ban disabled.", client, g_Score[client]);

        if (g_AdminAlerts.BoolValue)
        {
            for (int admin = 1; admin <= MaxClients; admin++)
            {
                if (IsClientInGame(admin) && !IsFakeClient(admin) && CheckCommandAccess(admin, "tf2_ac_detector_alerts", ADMFLAG_GENERIC, true))
                {
                    PrintToChat(admin, "[AC-DETECT] WOULD-BAN: %N score=%d. Real ban is disabled.", client, g_Score[client]);
                }
            }
        }
    }
}

public Action Command_Status(int client, int args)
{
    if (args < 1)
    {
        ReplyToCommand(client, "[AC-DETECT] mode=%s threshold=%d", g_BotsOnly.BoolValue ? "bots" : "all", g_Threshold.IntValue);
        for (int target = 1; target <= MaxClients; target++)
        {
            if (IsClientInGame(target) && g_Score[target] > 0)
            {
                ReplyToCommand(client, "  %N score=%d", target, g_Score[target]);
            }
        }
        return Plugin_Handled;
    }

    char pattern[64];
    GetCmdArg(1, pattern, sizeof(pattern));
    int targets[MAXPLAYERS];
    char targetName[MAX_TARGET_LENGTH];
    bool targetNameIsML;
    int count = ProcessTargetString(pattern, client, targets, sizeof(targets), COMMAND_FILTER_CONNECTED, targetName, sizeof(targetName), targetNameIsML);
    if (count <= 0)
    {
        ReplyToTargetError(client, count);
        return Plugin_Handled;
    }

    for (int i = 0; i < count; i++)
    {
        ReplyToCommand(client, "[AC-DETECT] %N score=%d", targets[i], g_Score[targets[i]]);
    }
    return Plugin_Handled;
}

public Action Command_Reset(int client, int args)
{
    if (args < 1)
    {
        ReplyToCommand(client, "[AC-DETECT] Usage: sm_acdetreset <target>");
        return Plugin_Handled;
    }

    char pattern[64];
    GetCmdArg(1, pattern, sizeof(pattern));
    int targets[MAXPLAYERS];
    char targetName[MAX_TARGET_LENGTH];
    bool targetNameIsML;
    int count = ProcessTargetString(pattern, client, targets, sizeof(targets), COMMAND_FILTER_CONNECTED, targetName, sizeof(targetName), targetNameIsML);
    if (count <= 0)
    {
        ReplyToTargetError(client, count);
        return Plugin_Handled;
    }

    for (int i = 0; i < count; i++) ResetClient(targets[i], true);
    ReplyToCommand(client, "[AC-DETECT] %s reset.", targetName);
    return Plugin_Handled;
}

public Action Command_Mode(int client, int args)
{
    if (args < 1)
    {
        ReplyToCommand(client, "[AC-DETECT] Usage: sm_acdetmode <bots|all>");
        return Plugin_Handled;
    }

    char mode[16];
    GetCmdArg(1, mode, sizeof(mode));
    if (StrEqual(mode, "bots", false))
    {
        g_BotsOnly.BoolValue = true;
        ReplyToCommand(client, "[AC-DETECT] Calibration scope: bots only.");
    }
    else if (StrEqual(mode, "all", false))
    {
        g_BotsOnly.BoolValue = false;
        ReplyToCommand(client, "[AC-DETECT] Shadow scope: all players. Real ban remains disabled.");
    }
    else
    {
        ReplyToCommand(client, "[AC-DETECT] Mode must be bots or all.");
    }
    return Plugin_Handled;
}

bool ShouldObserve(int client)
{
    if (!g_Enabled.BoolValue || client < 1 || client > MaxClients || !IsClientInGame(client)) return false;
    if (g_BotsOnly.BoolValue && !IsFakeClient(client)) return false;
    return true;
}

int FindHiddenTargetNearAim(int client, const float viewAngles[3], float cone)
{
    int best = 0;
    float bestAngle = cone + 1.0;
    for (int target = 1; target <= MaxClients; target++)
    {
        if (!IsValidEnemy(client, target) || IsWorldVisible(client, target)) continue;
        float aim[3];
        GetAimAngles(client, target, aim);
        float angle = AngleDistance(viewAngles, aim);
        if (angle <= cone && angle < bestAngle)
        {
            best = target;
            bestAngle = angle;
        }
    }
    return best;
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

float ClampF(float value, float minValue, float maxValue)
{
    if (value < minValue) return minValue;
    if (value > maxValue) return maxValue;
    return value;
}
