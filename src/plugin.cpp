// LovenseHaptics -- REFramework native plugin.
//
// REFramework's Lua sandbox has no networking (no sockets, io.popen and
// os.execute are removed), so Lua alone cannot talk to the Lovense Remote app.
// This plugin runs as native code inside the game and exposes a `lovense`
// global table to Lua, doing the HTTP work on its own worker thread.
//
// Talks to Lovense Remote's Game Mode / local API:
//   https://developer.lovense.com/docs/standard-solutions/standard-api.html
// No developer token, no Lovense SDK and no internet connection required.
//
// Lua API:
//   lovense.configure{ address = "127.0.0.1", port = 20010, ssl = false, toy = "Lush" }
//   lovense.set_level(level, ttl_ms)   -- level 0..20
//   lovense.stop()
//   lovense.status()                   -- table of connection info
//
// SAFETY: commands are sent with a bounded timeSec and continuously refreshed,
// so if the game crashes (taking this plugin with it) the Lovense Remote app
// stops the toy on its own within a couple of seconds. Never send timeSec = 0
// here -- that means "run indefinitely" and would leave the toy running after
// a crash.

#include <windows.h>
#include <winhttp.h>

#include <atomic>
#include <chrono>
#include <cctype>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

extern "C" {
#include <lauxlib.h>
#include <lua.h>
#include <lualib.h>
}

#include "reframework/API.h"

namespace {

constexpr const wchar_t* kPlatformName = L"REFramework-Lovense";

// Lovense requires timeSec > 1. Each command is told to run for this long and
// is refreshed well before it lapses, so a crash stops the toy automatically.
constexpr int kCommandSeconds = 2;
constexpr long long kKeepAliveMs = 800;

const REFrameworkPluginInitializeParam* g_param = nullptr;

void LogInfo(const char* fmt, ...) {
    if (g_param == nullptr) return;
    char buffer[512];
    va_list args;
    va_start(args, fmt);
    vsnprintf(buffer, sizeof(buffer), fmt, args);
    va_end(args);
    g_param->functions->log_info("[Lovense] %s", buffer);
}

long long NowMs() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(
               std::chrono::steady_clock::now().time_since_epoch())
        .count();
}

std::string ToLower(std::string s) {
    for (char& c : s) c = static_cast<char>(tolower(static_cast<unsigned char>(c)));
    return s;
}

std::wstring Widen(const std::string& s) {
    if (s.empty()) return {};
    const int len = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), static_cast<int>(s.size()), nullptr, 0);
    std::wstring out(static_cast<size_t>(len), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.c_str(), static_cast<int>(s.size()), out.data(), len);
    return out;
}

std::string Narrow(const std::wstring& s) {
    if (s.empty()) return {};
    const int len = WideCharToMultiByte(CP_UTF8, 0, s.c_str(), static_cast<int>(s.size()),
                                        nullptr, 0, nullptr, nullptr);
    std::string out(static_cast<size_t>(len), '\0');
    WideCharToMultiByte(CP_UTF8, 0, s.c_str(), static_cast<int>(s.size()), out.data(), len,
                        nullptr, nullptr);
    return out;
}

std::string JsonEscape(const std::string& in) {
    std::string out;
    out.reserve(in.size() + 8);
    for (char c : in) {
        if (c == '"' || c == '\\') { out += '\\'; out += c; }
        else if (static_cast<unsigned char>(c) >= 0x20) out += c;
    }
    return out;
}

// Extracts a value from flat-ish JSON. Copes with the escaped inner JSON that
// GetToys returns, without pulling in a full parser.
std::string FindJsonString(const std::string& json, const std::string& key) {
    for (const std::string& quote : {std::string("\""), std::string("\\\"")}) {
        const std::string needle = quote + key + quote;
        size_t pos = json.find(needle);
        if (pos == std::string::npos) continue;
        pos = json.find(':', pos + needle.size());
        if (pos == std::string::npos) continue;
        ++pos;
        while (pos < json.size() && (json[pos] == ' ' || json[pos] == '\\' || json[pos] == '"')) ++pos;
        size_t end = pos;
        while (end < json.size() && json[end] != '"' && json[end] != '\\' &&
               json[end] != ',' && json[end] != '}') {
            ++end;
        }
        return json.substr(pos, end - pos);
    }
    return {};
}

int FindJsonInt(const std::string& json, const std::string& key, int fallback) {
    const std::string raw = FindJsonString(json, key);
    if (raw.empty()) return fallback;
    char* end = nullptr;
    const long value = strtol(raw.c_str(), &end, 10);
    return (end == raw.c_str()) ? fallback : static_cast<int>(value);
}

const char* DescribeApiCode(int code) {
    switch (code) {
        case 200: return "OK";
        case 400: return "invalid command";
        case 401: return "toy not found";
        case 402: return "toy not connected";
        case 403: return "toy doesn't support this command";
        case 404: return "invalid parameter";
        case 500: return "HTTP server not started - enable Game Mode / LAN in Lovense Remote";
        case 506: return "server error - restart Lovense Remote";

        // The two hurdles a first-time user hits. Neither is fatal: the worker
        // keeps polling, so the mod starts working the moment they fix it.
        case 501: return "Lovense Remote rejected this app";
        case 502: return "not approved yet - in Lovense Remote turn on "
                         "Settings > External control > Allow Control, then accept the prompt";
        case 503: return "Lovense Remote is busy";
        case 507: return "toy is offline";

        default:  return "unknown error";
    }
}

// True for codes that mean "the user has to do something in the Lovense app",
// as opposed to a transient fault we should just keep retrying quietly.
bool CodeNeedsUserAction(int code) {
    return code == 500 || code == 501 || code == 502;
}

// ---------------------------------------------------------------------------
// Lovense Remote local API client (worker thread only)
// ---------------------------------------------------------------------------

class RemoteClient {
public:
    ~RemoteClient() { Close(); }

    bool Open(const std::string& address, int port, bool ssl) {
        Close();
        m_secure = ssl;
        m_port = port > 0 ? port : (ssl ? 30010 : 20010);

        if (m_secure) {
            std::string host = address;
            for (char& c : host) {
                if (c == '.') c = '-';
            }
            m_host = Widen(host + ".lovense.club");
        } else {
            m_host = Widen(address);
        }

        m_session = WinHttpOpen(kPlatformName, WINHTTP_ACCESS_TYPE_NO_PROXY,
                                WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
        if (m_session == nullptr) return false;

        WinHttpSetTimeouts(m_session, 1500, 1500, 1500, 1500);
        m_connection = WinHttpConnect(m_session, m_host.c_str(),
                                      static_cast<INTERNET_PORT>(m_port), 0);
        if (m_connection == nullptr) { Close(); return false; }
        return true;
    }

    void Close() {
        if (m_connection != nullptr) { WinHttpCloseHandle(m_connection); m_connection = nullptr; }
        if (m_session != nullptr) { WinHttpCloseHandle(m_session); m_session = nullptr; }
    }

    std::string Endpoint() const {
        return (m_secure ? "https://" : "http://") + Narrow(m_host) + ":" +
               std::to_string(m_port) + "/command";
    }

    bool Post(const std::string& body, std::string* response) {
        response->clear();
        if (m_connection == nullptr) return false;

        const DWORD flags = m_secure ? WINHTTP_FLAG_SECURE : 0;
        HINTERNET request = WinHttpOpenRequest(m_connection, L"POST", L"/command", nullptr,
                                               WINHTTP_NO_REFERER,
                                               WINHTTP_DEFAULT_ACCEPT_TYPES, flags);
        if (request == nullptr) return false;

        const std::wstring headers =
            std::wstring(L"Content-Type: application/json\r\nX-platform: ") + kPlatformName;

        bool ok = false;
        if (WinHttpSendRequest(request, headers.c_str(), static_cast<DWORD>(-1),
                               const_cast<char*>(body.data()), static_cast<DWORD>(body.size()),
                               static_cast<DWORD>(body.size()), 0) &&
            WinHttpReceiveResponse(request, nullptr)) {
            DWORD available = 0;
            while (WinHttpQueryDataAvailable(request, &available) && available > 0) {
                std::vector<char> chunk(available + 1, '\0');
                DWORD read = 0;
                if (!WinHttpReadData(request, chunk.data(), available, &read)) break;
                response->append(chunk.data(), read);
            }
            ok = true;
        }

        WinHttpCloseHandle(request);
        return ok;
    }

private:
    HINTERNET m_session = nullptr;
    HINTERNET m_connection = nullptr;
    std::wstring m_host;
    int m_port = 20010;
    bool m_secure = false;
};

// ---------------------------------------------------------------------------
// shared state between the Lua/game thread and the worker
// ---------------------------------------------------------------------------

struct Shared {
    std::mutex mutex;

    // Written by Lua, read by the worker.
    std::string address = "127.0.0.1";
    int port = 0;
    bool ssl = false;
    std::string toyFilter;
    bool reopenRequested = true;

    // Written by the worker, read by Lua.
    bool connected = false;
    bool needsUserAction = false;
    std::string toyId;
    std::string toyName;
    std::string battery;
    std::string lastError;
    std::string endpoint;
    long long commandsSent = 0;
};

Shared g_shared;
std::atomic<int> g_desiredLevel{0};
std::atomic<long long> g_levelSetAtMs{0};
std::atomic<int> g_ttlMs{2000};
std::atomic<bool> g_workerRunning{false};
std::thread g_worker;

bool RefreshToys(RemoteClient* client) {
    std::string response;
    if (!client->Post("{\"command\":\"GetToys\"}", &response)) {
        // Verified behaviour: switching off Settings > External control >
        // Allow Control makes Lovense Remote close the local HTTP server
        // outright, so this shows up as a refused connection rather than an
        // API error code. Same symptom as the app simply not running.
        std::lock_guard<std::mutex> lock(g_shared.mutex);
        g_shared.connected = false;
        g_shared.needsUserAction = true;
        g_shared.lastError = "no Lovense Remote server at " + g_shared.endpoint +
                             " - check the app is running, Game Mode / LAN is on, "
                             "and External control > Allow Control is enabled";
        return false;
    }

    const int code = FindJsonInt(response, "code", 0);
    if (code != 200) {
        std::lock_guard<std::mutex> lock(g_shared.mutex);
        g_shared.connected = false;
        g_shared.needsUserAction = CodeNeedsUserAction(code);
        g_shared.lastError = "GetToys " + std::to_string(code) + ": " + DescribeApiCode(code);
        return false;
    }

    const std::string name = FindJsonString(response, "name");
    const std::string id = FindJsonString(response, "id");
    const std::string battery = FindJsonString(response, "battery");

    std::string filter;
    {
        std::lock_guard<std::mutex> lock(g_shared.mutex);
        filter = g_shared.toyFilter;
    }

    if (id.empty() && name.empty()) {
        std::lock_guard<std::mutex> lock(g_shared.mutex);
        g_shared.connected = false;
        g_shared.needsUserAction = true;
        g_shared.lastError = "Lovense Remote is running but has no toy connected";
        return false;
    }

    if (!filter.empty()) {
        const std::string lowered = ToLower(filter);
        if (ToLower(name).find(lowered) == std::string::npos &&
            ToLower(id).find(lowered) == std::string::npos) {
            std::lock_guard<std::mutex> lock(g_shared.mutex);
            g_shared.connected = false;
            g_shared.lastError = "no toy matching '" + filter + "' (found '" + name + "')";
            return false;
        }
    }

    bool wasConnected;
    {
        std::lock_guard<std::mutex> lock(g_shared.mutex);
        wasConnected = g_shared.connected;
        g_shared.connected = true;
        g_shared.needsUserAction = false;
        g_shared.toyId = id;
        g_shared.toyName = name;
        g_shared.battery = battery;
        g_shared.lastError.clear();
    }

    if (!wasConnected) {
        LogInfo("connected to '%s' (%s), battery %s", name.c_str(), id.c_str(),
                battery.empty() ? "?" : battery.c_str());
    }
    return true;
}

bool SendLevel(RemoteClient* client, int level) {
    std::string toyId;
    {
        std::lock_guard<std::mutex> lock(g_shared.mutex);
        toyId = g_shared.toyId;
    }

    std::ostringstream body;
    body << "{\"command\":\"Function\",\"action\":\"";
    if (level <= 0) body << "Stop";
    else body << "Vibrate:" << level;
    // Bounded runtime, refreshed by the keep-alive. If we die, Remote stops it.
    body << "\",\"timeSec\":" << (level <= 0 ? 0 : kCommandSeconds);
    if (!toyId.empty()) body << ",\"toy\":\"" << JsonEscape(toyId) << "\"";
    body << ",\"apiVer\":1}";

    std::string response;
    if (!client->Post(body.str(), &response)) {
        std::lock_guard<std::mutex> lock(g_shared.mutex);
        g_shared.connected = false;
        g_shared.lastError = "send failed - lost contact with Lovense Remote";
        return false;
    }

    const int code = FindJsonInt(response, "code", 0);
    if (code != 200) {
        std::lock_guard<std::mutex> lock(g_shared.mutex);
        g_shared.lastError = "Function " + std::to_string(code) + ": " + DescribeApiCode(code);
        if (code == 401 || code == 402 || code == 500) g_shared.connected = false;
        return false;
    }

    std::lock_guard<std::mutex> lock(g_shared.mutex);
    ++g_shared.commandsSent;
    return true;
}

void WorkerLoop() {
    RemoteClient client;
    bool opened = false;
    int appliedLevel = -1;
    long long lastSendMs = 0;
    long long lastToyPollMs = 0;

    while (g_workerRunning) {
        const long long nowMs = NowMs();

        bool needReopen;
        std::string address;
        int port;
        bool ssl;
        {
            std::lock_guard<std::mutex> lock(g_shared.mutex);
            needReopen = g_shared.reopenRequested;
            g_shared.reopenRequested = false;
            address = g_shared.address;
            port = g_shared.port;
            ssl = g_shared.ssl;
        }

        if (needReopen || !opened) {
            opened = client.Open(address, port, ssl);
            appliedLevel = -1;
            std::lock_guard<std::mutex> lock(g_shared.mutex);
            g_shared.endpoint = client.Endpoint();
            g_shared.connected = false;
            if (!opened) g_shared.lastError = "WinHTTP initialisation failed";
        }

        if (!opened) {
            std::this_thread::sleep_for(std::chrono::milliseconds(1000));
            continue;
        }

        bool connected;
        {
            std::lock_guard<std::mutex> lock(g_shared.mutex);
            connected = g_shared.connected;
        }

        const long long toyPollInterval = connected ? 30000 : 3000;
        if ((nowMs - lastToyPollMs) > toyPollInterval) {
            lastToyPollMs = nowMs;
            if (!RefreshToys(&client)) appliedLevel = -1;
            std::lock_guard<std::mutex> lock(g_shared.mutex);
            connected = g_shared.connected;
        }

        int level = g_desiredLevel.load();

        // Watchdog: Lua stopped updating us, so stop the toy.
        if (level != 0 && (nowMs - g_levelSetAtMs.load()) > g_ttlMs.load()) {
            g_desiredLevel = 0;
            level = 0;
        }

        if (connected) {
            const bool changed = (level != appliedLevel);
            const bool keepAliveDue = (level > 0) && ((nowMs - lastSendMs) >= kKeepAliveMs);
            if (changed || keepAliveDue) {
                if (SendLevel(&client, level)) {
                    appliedLevel = level;
                    lastSendMs = nowMs;
                } else {
                    lastSendMs = nowMs;
                    appliedLevel = -1;
                }
            }
        } else {
            appliedLevel = -1;
        }

        // 5 ms rather than 20 ms so that short pattern steps (a fanfare pulse is
        // ~120 ms) are not quantised badly. This does not increase the command
        // rate: we only transmit when the level actually changes.
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }

    // Best-effort stop on the way out.
    if (opened) SendLevel(&client, 0);
    client.Close();
}

// An exception escaping a std::thread calls std::terminate, which would take
// the whole game down. Nothing in here is worth crashing a user's session over,
// so the worker is allowed to fail and retry instead. The most likely causes
// are the user not having enabled external control yet, or not having accepted
// the approval prompt -- both of which just mean "retry in a moment".
void WorkerMain() {
    while (g_workerRunning) {
        try {
            WorkerLoop();
            return;  // clean exit, g_workerRunning went false
        } catch (const std::exception& e) {
            {
                std::lock_guard<std::mutex> lock(g_shared.mutex);
                g_shared.connected = false;
                g_shared.lastError = std::string("internal error, retrying: ") + e.what();
            }
            LogInfo("worker exception (recovering): %s", e.what());
        } catch (...) {
            {
                std::lock_guard<std::mutex> lock(g_shared.mutex);
                g_shared.connected = false;
                g_shared.lastError = "internal error, retrying";
            }
            LogInfo("worker exception (recovering): unknown");
        }

        g_desiredLevel = 0;
        std::this_thread::sleep_for(std::chrono::milliseconds(2000));
    }
}

void StartWorker() {
    if (g_workerRunning.exchange(true)) return;
    try {
        g_worker = std::thread(WorkerMain);
    } catch (...) {
        // Could not spawn the worker (very unlikely). Stay inert rather than
        // letting the failure propagate into REFramework's plugin loader.
        g_workerRunning = false;
        LogInfo("failed to start worker thread; plugin is inactive");
    }
}

void StopWorker() {
    if (!g_workerRunning.exchange(false)) return;
    if (g_worker.joinable()) g_worker.join();
}

// ---------------------------------------------------------------------------
// Lua bindings -- these run on the game thread and must never block.
//
// Lua is compiled as C, so letting a C++ exception unwind through a lua_CFunction
// frame is undefined behaviour. Every binding therefore swallows exceptions and
// degrades instead of throwing. A haptics mod failing quietly is always better
// than it taking the game down.
// ---------------------------------------------------------------------------

void CopyTo(char* dest, size_t destSize, const std::string& src) {
    const size_t n = (src.size() < destSize - 1) ? src.size() : destSize - 1;
    memcpy(dest, src.data(), n);
    dest[n] = '\0';
}

int Lua_Configure(lua_State* L) {
    luaL_checktype(L, 1, LUA_TTABLE);

    // Read the Lua values first; these cannot throw C++ exceptions.
    const char* address = nullptr;
    const char* toy = nullptr;
    int port = 0;
    bool ssl = false;
    bool hasPort = false;
    bool hasSsl = false;

    lua_getfield(L, 1, "address");
    if (lua_isstring(L, -1)) address = lua_tostring(L, -1);
    lua_pop(L, 1);

    lua_getfield(L, 1, "port");
    if (lua_isnumber(L, -1)) { port = static_cast<int>(lua_tointeger(L, -1)); hasPort = true; }
    lua_pop(L, 1);

    lua_getfield(L, 1, "ssl");
    if (lua_isboolean(L, -1)) { ssl = lua_toboolean(L, -1) != 0; hasSsl = true; }
    lua_pop(L, 1);

    lua_getfield(L, 1, "toy");
    if (lua_isstring(L, -1)) toy = lua_tostring(L, -1);
    lua_pop(L, 1);

    try {
        std::lock_guard<std::mutex> lock(g_shared.mutex);
        if (address != nullptr) g_shared.address = address;
        if (toy != nullptr) g_shared.toyFilter = toy;
        if (hasPort) g_shared.port = port;
        if (hasSsl) g_shared.ssl = ssl;
        g_shared.reopenRequested = true;
    } catch (...) {
        // Keep the previous configuration; the worker carries on regardless.
    }
    return 0;
}

int Lua_SetLevel(lua_State* L) {
    int level = static_cast<int>(luaL_checkinteger(L, 1));
    if (level < 0) level = 0;
    if (level > 20) level = 20;

    int ttl = static_cast<int>(luaL_optinteger(L, 2, 2000));
    if (ttl < 250) ttl = 250;

    g_ttlMs = ttl;
    g_levelSetAtMs = NowMs();
    g_desiredLevel = level;
    return 0;
}

int Lua_Stop(lua_State* L) {
    (void)L;
    g_desiredLevel = 0;
    g_levelSetAtMs = NowMs();
    return 0;
}

int Lua_Status(lua_State* L) {
    // Snapshot into plain buffers under the lock, so that by the time we start
    // pushing to Lua there are no live C++ objects a Lua error could skip over.
    bool connected = false;
    bool needsAction = true;
    long long commandsSent = 0;
    char toyId[64] = {0};
    char toyName[64] = {0};
    char battery[16] = {0};
    char lastError[256] = {0};
    char endpoint[256] = {0};

    try {
        std::lock_guard<std::mutex> lock(g_shared.mutex);
        connected = g_shared.connected;
        needsAction = g_shared.needsUserAction;
        commandsSent = g_shared.commandsSent;
        CopyTo(toyId, sizeof(toyId), g_shared.toyId);
        CopyTo(toyName, sizeof(toyName), g_shared.toyName);
        CopyTo(battery, sizeof(battery), g_shared.battery);
        CopyTo(lastError, sizeof(lastError), g_shared.lastError);
        CopyTo(endpoint, sizeof(endpoint), g_shared.endpoint);
    } catch (...) {
        CopyTo(lastError, sizeof(lastError), std::string("status unavailable"));
    }

    lua_newtable(L);
    lua_pushboolean(L, connected);              lua_setfield(L, -2, "connected");
    lua_pushboolean(L, needsAction);            lua_setfield(L, -2, "needs_attention");
    lua_pushstring(L, toyId);                   lua_setfield(L, -2, "toy_id");
    lua_pushstring(L, toyName);                 lua_setfield(L, -2, "toy_name");
    lua_pushstring(L, battery);                 lua_setfield(L, -2, "battery");
    lua_pushstring(L, lastError);               lua_setfield(L, -2, "last_error");
    lua_pushstring(L, endpoint);                lua_setfield(L, -2, "endpoint");
    lua_pushinteger(L, g_desiredLevel.load());  lua_setfield(L, -2, "level");
    lua_pushinteger(L, commandsSent);           lua_setfield(L, -2, "commands_sent");
    lua_pushstring(L, "plugin");                lua_setfield(L, -2, "transport");
    return 1;
}

const luaL_Reg kLovenseFuncs[] = {
    {"configure", Lua_Configure},
    {"set_level", Lua_SetLevel},
    {"stop",      Lua_Stop},
    {"status",    Lua_Status},
    {nullptr,     nullptr},
};

void OnLuaStateCreated(lua_State* L) {
    lua_newtable(L);
    luaL_setfuncs(L, kLovenseFuncs, 0);
    lua_setglobal(L, "lovense");
    LogInfo("lovense table registered on new Lua state");
}

void OnLuaStateDestroyed(lua_State* L) {
    (void)L;
    // Scripts are being reset; make sure nothing is left running.
    g_desiredLevel = 0;
}

}  // namespace

extern "C" __declspec(dllexport) void reframework_plugin_required_version(
    REFrameworkPluginVersion* version) {
    version->major = REFRAMEWORK_PLUGIN_VERSION_MAJOR;
    version->minor = REFRAMEWORK_PLUGIN_VERSION_MINOR;
    version->patch = REFRAMEWORK_PLUGIN_VERSION_PATCH;
}

extern "C" __declspec(dllexport) bool reframework_plugin_initialize(
    const REFrameworkPluginInitializeParam* param) {
    g_param = param;

    param->functions->on_lua_state_created(OnLuaStateCreated);
    param->functions->on_lua_state_destroyed(OnLuaStateDestroyed);

    StartWorker();
    LogInfo("plugin initialised (Lovense Remote Game Mode transport)");
    return true;
}

BOOL APIENTRY DllMain(HMODULE module, DWORD reason, LPVOID reserved) {
    (void)module;
    (void)reserved;
    if (reason == DLL_PROCESS_DETACH) {
        // Don't join here -- joining inside the loader lock can deadlock.
        g_desiredLevel = 0;
        g_workerRunning = false;
    }
    return TRUE;
}
