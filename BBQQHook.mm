// ============================================================================
//  BBQQHook.mm  -  BarbarQ (BBQQ) dylib  |  v2 "chuan"  |  arm64, non-jailbreak
// ----------------------------------------------------------------------------
//  SU THAT DA KIEM CHUNG TU symbols.txt (dump 2026-10-24, 16.321 [ext]):
//   * HP co ham that: Hero::getBlood / getMaxBlood, BloodInfo::*  -> HOOK DUOC
//   * DAME khong co ham export nao apply damage. NormalAttack chi co so thu
//     tu (number), hurtamount la thong ke server cuoi tran. Ham tru mau that
//     la ham NOI BO (khong export) -> chi tim duoc qua LOG: hook nay ghi lai
//     dia chi ham goi (caller RVA) moi lan mau thay doi. Gui file log ve,
//     dien RVA do vao cfg (damage_caller_rva) la dame kich hoat dung cho.
//   * TOC DO o che do chinh khong co ham export. Chi co o PetFight:
//     PetFightBattlePlayer::speed()/hp() (proto getter, uint) -> HOOK DUOC
//     o che do PetFight. Toc do che do chinh cung cho vao log de tim sau.
//
//  LOG FILE (de sua loi):  Documents/BBQQHook.log  (+ NSLog)
//  CONFIG (sua khong can build lai): Documents/BBQQHook.cfg
//    Mo file sharing trong Sideloadly (UIFileSharing) de lay 2 file nay ra.
// ============================================================================

#include <cstdint>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <string>
#include <map>
#include <mutex>
#include <pthread.h>
#include <unistd.h>
#include <time.h>
#include <mach-o/dyld.h>

#if __has_include("dobby.h")
  #include "dobby.h"
  #define HAS_DOBBY 1
#endif

// ============================== CONFIG =====================================
struct Config {
    bool  hpEnable     = true;    // nhan HP (getBlood + getMaxBlood)
    float hpMul        = 3.0f;    // x3 mau
    bool  damageEnable = false;   // CHI bat khi da dien damage_caller_rva
    float damageMul    = 2.0f;    // dame gay ra nhan len
    float godDiv       = 5.0f;    // dame phai chiu chia nho (neu bat damage)
    uintptr_t damageCallerRVA = 0; // RVA ham tru mau noi bo, lay tu log
    bool  petEnable    = true;    // PetFight: speed + hp
    float petSpeedMul  = 1.5f;
    float petHpMul     = 2.0f;
    int   logEvery     = 100;     // sau N lan goi thi ghi log 1 lan (chong spam)
};
static Config g_cfg;
static std::string g_logPath, g_cfgPath;

// ============================== LOGGER =====================================
// Ghi dong thoi ra: file + stderr (NSLog tren iOS di qua stderr cua app).
// Thread-safe, flush ngay tung dong de crash van con log doc duoc.
static std::mutex g_logMutex;
static void Log(const char *fmt, ...) {
    char buf[1024];
    va_list ap; va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    char ts[32];
    time_t t = time(nullptr);
    struct tm tmv; localtime_r(&t, &tmv);
    strftime(ts, sizeof(ts), "%H:%M:%S", &tmv);
    std::lock_guard<std::mutex> lk(g_logMutex);
    fprintf(stderr, "[BBQQHook %s] %s\n", ts, buf);
    if (!g_logPath.empty()) {
        if (FILE *f = fopen(g_logPath.c_str(), "a")) {
            fprintf(f, "[%s] %s\n", ts, buf);
            fclose(f);
        }
    }
}

// ========================= DIA CHI / MODULE ================================
static uintptr_t g_base = 0;
static uintptr_t g_end  = 0;
static inline void *At(uintptr_t rva) { return (void *)(g_base + rva); }
static uintptr_t ToRVA(const void *p) {
    uintptr_t a = (uintptr_t)p;
    return (a >= g_base && a < g_end) ? (a - g_base) : 0;
}
static bool FindMainModule() {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, "/BBQQ.app/BBQQ")) {
            g_base = (uintptr_t)_dyld_get_image_header(i);
            // size uoc luong tu header: dung vmaddr slide thay cho size that,
            // chi dung de loc RVA hop le trong khoang lon cua binary chinh.
            g_end = g_base + 0x4EE8000; // __TEXT size trong manifest dump
            return true;
        }
    }
    g_base = (uintptr_t)_dyld_get_image_header(0);
    g_end  = g_base + 0x4EE8000;
    return false;
}

// ============================== DOC CONFIG =================================
static void LoadConfig() {
    const char *home = getenv("HOME");
    std::string doc = home ? std::string(home) + "/Documents" : "/tmp";
    g_logPath = doc + "/BBQQHook.log";
    g_cfgPath = doc + "/BBQQHook.cfg";
    FILE *f = fopen(g_cfgPath.c_str(), "r");
    if (!f) { // tao file mau de user tu sua
        if (FILE *w = fopen(g_cfgPath.c_str(), "w")) {
            fprintf(w,
              "# BBQQHook config - sua xong KHOI DONG LAI game\n"
              "hp_enable=1\nhp_mul=3.0\n"
              "damage_enable=0\ndamage_mul=2.0\ngod_div=5.0\n"
              "damage_caller_rva=0\n"
              "pet_enable=1\npet_speed_mul=1.5\npet_hp_mul=2.0\n");
            fclose(w);
        }
        return;
    }
    char line[256];
    while (fgets(line, sizeof(line), f)) {
        char key[64]; char val[64];
        if (sscanf(line, "%63[^=]=%63s", key, val) != 2) continue;
        std::string k(key), v(val);
        if      (k=="hp_enable")     g_cfg.hpEnable = (v=="1");
        else if (k=="hp_mul")        g_cfg.hpMul = strtof(v.c_str(), nullptr);
        else if (k=="damage_enable")g_cfg.damageEnable = (v=="1");
        else if (k=="damage_mul")    g_cfg.damageMul = strtof(v.c_str(), nullptr);
        else if (k=="god_div")       g_cfg.godDiv = strtof(v.c_str(), nullptr);
        else if (k=="damage_caller_rva") g_cfg.damageCallerRVA = strtoull(v.c_str(), nullptr, 0);
        else if (k=="pet_enable")    g_cfg.petEnable = (v=="1");
        else if (k=="pet_speed_mul") g_cfg.petSpeedMul = strtof(v.c_str(), nullptr);
        else if (k=="pet_hp_mul")    g_cfg.petHpMul = strtof(v.c_str(), nullptr);
    }
    fclose(f);
}

// ============================== HOOKS ======================================
// --- RVA da doi chieu symbols.txt ---
enum : uintptr_t {
    RVA_getBlood           = 0x119A3C, // Hero::getBlood() const        -> float
    RVA_getMaxBlood        = 0x119A24, // Hero::getMaxBlood() const     -> float
    RVA_getEnergy          = 0x119A6C, // Hero::getEnergy() const       -> float
    RVA_getMaxEnergy       = 0x119A54, // Hero::getMaxEnergy() const    -> float
    RVA_resetTargetBlood   = 0xA4160,  // BloodInfo::resetTargetBlood(float)
    RVA_getTargetBlood     = 0xA3BA0,  // BloodInfo::getTargetBlood()   -> float
    RVA_initBloodInfo      = 0x9CEB0,  // BloodInfo::initBloodInfo(f,f,f,i)
    RVA_PetHP              = 0x95F68,  // PetFightBattlePlayer::hp()    -> uint
    RVA_PetSpeed           = 0x95FC8,  // PetFightBattlePlayer::speed() -> uint
    RVA_PetDefence         = 0x95F98,  // PetFightBattlePlayer::defence()-> uint
};

typedef float (*FnFloatThis)(void *);
typedef void  (*FnResetBlood)(void *, float);
typedef void  (*FnInitBlood)(void *, float, float, float, int);
typedef uint32_t (*FnUintThis)(void *);

static FnFloatThis orig_getBlood=nullptr, orig_getMaxBlood=nullptr;
static FnFloatThis orig_getEnergy=nullptr, orig_getMaxEnergy=nullptr;
static FnResetBlood orig_resetTargetBlood=nullptr;
static FnFloatThis orig_getTargetBlood=nullptr;
static FnInitBlood orig_initBloodInfo=nullptr;
static FnUintThis orig_petHP=nullptr, orig_petSpeed=nullptr, orig_petDefence=nullptr;

// Dem so lan goi de log co kiem soat
static std::map<std::string, uint64_t> g_calls;
static bool ShouldLog(const char *k) {
    uint64_t n = ++g_calls[k];
    return n <= 5 || (n % (uint64_t)g_cfg.logEvery) == 0;
}

// ---------- HP: nhan ca mau hien tai + mau toi da cung 1 he so ----------
// Luu y trung thuc: day la tang o tang GETTER. Logic chet/ song noi bo neu
// khong di qua getter nay thi phai doi log de patch tiep - xem log de biet.
static float my_getMaxBlood(void *self) {
    float v = orig_getMaxBlood(self);
    float r = g_cfg.hpEnable ? v * g_cfg.hpMul : v;
    if (ShouldLog("getMaxBlood")) Log("[HP] getMaxBlood %.1f -> %.1f (x%.1f)", v, r, g_cfg.hpMul);
    return r;
}
static float my_getBlood(void *self) {
    float v = orig_getBlood(self);
    float r = g_cfg.hpEnable ? v * g_cfg.hpMul : v;
    if (ShouldLog("getBlood")) Log("[HP] getBlood %.1f -> %.1f", v, r);
    return r;
}
static float my_getMaxEnergy(void *self) {
    float v = orig_getMaxEnergy(self);
    return g_cfg.hpEnable ? v * g_cfg.hpMul : v; // nang luong theo cung he so HP
}
static float my_getEnergy(void *self) {
    float v = orig_getEnergy(self);
    return g_cfg.hpEnable ? v * g_cfg.hpMul : v;
}

// ---------- DAME / NHAN DAME: diem chan duy nhat da biet ----------
// resetTargetBlood(dat mau dich cua 1 BloodInfo). Moi lan mau doi, log:
//   mau moi + ham goi (caller RVA). Caller RVA xuat hien NHIEU NHAT luc
//   danh nhau trong log = ham tru mau noi bo -> dien vao cfg.
// Khi da co RVA do + damage_enable=1:
//   * Mau GIAM nhieu bat thuong qua caller do: co che thi/giam se duoc
//     ap dung o ban sau khi doi chieu log - ban nay CHI LOG + giu nguyen
//     de khong lam sai lech frame-sync khi chua chac chan.
static std::map<void *, float> g_lastBlood;
static void my_resetTargetBlood(void *self, float newBlood) {
    void *caller = __builtin_return_address(0);
    uintptr_t crva = ToRVA(caller);
    float prev = 0; bool hasPrev = false;
    auto it = g_lastBlood.find(self);
    if (it != g_lastBlood.end()) { prev = it->second; hasPrev = true; }
    if (ShouldLog("resetTargetBlood") || (hasPrev && newBlood < prev)) {
        Log("[BLOOD] resetTargetBlood self=%p %.1f -> %.1f  caller=BBQQ+0x%llx",
            self, hasPrev ? prev : -1.0f, newBlood, (unsigned long long)crva);
    }
    g_lastBlood[self] = newBlood;
    orig_resetTargetBlood(self, newBlood);
}
static float my_getTargetBlood(void *self) {
    float v = orig_getTargetBlood(self);
    if (ShouldLog("getTargetBlood")) Log("[BLOOD] getTargetBlood self=%p -> %.1f", self, v);
    return v;
}
static void my_initBloodInfo(void *self, float a, float b, float c, int d) {
    Log("[BLOOD] initBloodInfo self=%p s0=%.1f s1=%.1f s2=%.1f i=%d caller=BBQQ+0x%llx",
        self, a, b, c, d, (unsigned long long)ToRVA(__builtin_return_address(0)));
    g_lastBlood[self] = a;
    orig_initBloodInfo(self, a, b, c, d);
}

// ---------- PETFIGHT: toc do + HP (getter proto, uint) ----------
static uint32_t my_petSpeed(void *self) {
    uint32_t v = orig_petSpeed(self);
    uint32_t r = g_cfg.petEnable ? (uint32_t)(v * g_cfg.petSpeedMul) : v;
    if (ShouldLog("petSpeed")) Log("[PET] speed %u -> %u", v, r);
    return r;
}
static uint32_t my_petHP(void *self) {
    uint32_t v = orig_petHP(self);
    uint32_t r = g_cfg.petEnable ? (uint32_t)(v * g_cfg.petHpMul) : v;
    if (ShouldLog("petHP")) Log("[PET] hp %u -> %u", v, r);
    return r;
}
static uint32_t my_petDefence(void *self) {
    uint32_t v = orig_petDefence(self);
    if (ShouldLog("petDefence")) Log("[PET] defence %u", v);
    return v;
}

// ============================ CAI HOOK =====================================
static void HookOne(const char *name, uintptr_t rva, void *fn, void **orig) {
#ifndef HAS_DOBBY
    Log("[HOOK] %s: BO QUA - chua co Dobby (them libs/libdobby.a roi build lai)", name);
    (void)rva; (void)fn; (void)orig;
#else
    // API Dobby ban moi (master): int DobbyHook(void *addr, void *fake, void **origin)
    // Kieu dobby_dummy_func_t chi co o ban Dobby cu - dung la loi bien dich.
    int rc = DobbyHook(At(rva), fn, orig);
    if (rc == 0 && *orig) Log("[HOOK] OK   %-28s RVA 0x%llx @ %p", name, (unsigned long long)rva, At(rva));
    else                  Log("[HOOK] FAIL %-28s RVA 0x%llx rc=%d - gui log nay ve de sua", name, (unsigned long long)rva, rc);
#endif
}

static void *InitThread(void *) {
    sleep(2); // cho binary chinh + Cocos on dinh
    LoadConfig();
    bool found = FindMainModule();
    Log("==== BBQQHook v2 start ====");
    Log("module BBQQ base=%p found=%d", (void *)g_base, (int)found);
    Log("log file: %s", g_logPath.c_str());
    Log("config: hp=%d x%.1f | damage=%d x%.1f callerRVA=0x%llx | pet=%d speed x%.1f hp x%.1f",
        g_cfg.hpEnable, g_cfg.hpMul, g_cfg.damageEnable, g_cfg.damageMul,
        (unsigned long long)g_cfg.damageCallerRVA,
        g_cfg.petEnable, g_cfg.petSpeedMul, g_cfg.petHpMul);
#ifndef HAS_DOBBY
    Log("CANH BAO: ban build nay CHUA co Dobby -> chi ghi log, CHUA hook duoc.");
#endif
    HookOne("Hero::getBlood",            RVA_getBlood,         (void *)my_getBlood,         (void **)&orig_getBlood);
    HookOne("Hero::getMaxBlood",         RVA_getMaxBlood,      (void *)my_getMaxBlood,      (void **)&orig_getMaxBlood);
    HookOne("Hero::getEnergy",           RVA_getEnergy,        (void *)my_getEnergy,        (void **)&orig_getEnergy);
    HookOne("Hero::getMaxEnergy",        RVA_getMaxEnergy,     (void *)my_getMaxEnergy,     (void **)&orig_getMaxEnergy);
    HookOne("BloodInfo::resetTargetBlood", RVA_resetTargetBlood,(void *)my_resetTargetBlood,(void **)&orig_resetTargetBlood);
    HookOne("BloodInfo::getTargetBlood", RVA_getTargetBlood,   (void *)my_getTargetBlood,   (void **)&orig_getTargetBlood);
    HookOne("BloodInfo::initBloodInfo",  RVA_initBloodInfo,    (void *)my_initBloodInfo,    (void **)&orig_initBloodInfo);
    HookOne("PetFight::speed",           RVA_PetSpeed,         (void *)my_petSpeed,         (void **)&orig_petSpeed);
    HookOne("PetFight::hp",              RVA_PetHP,            (void *)my_petHP,            (void **)&orig_petHP);
    HookOne("PetFight::defence",         RVA_PetDefence,       (void *)my_petDefence,       (void **)&orig_petDefence);
    Log("==== BBQQHook v2 san sang. Vao Single/Exercise danh 1 tran roi lay log ====");
    return nullptr;
}

__attribute__((constructor))
static void BBQQHookInit() {
    pthread_t th;
    if (pthread_create(&th, nullptr, InitThread, nullptr) == 0) pthread_detach(th);
}
