#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <CFNetwork/CFProxySupport.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <net/if_dl.h>
#import <net/route.h>
#import <os/lock.h>
#import <string.h>
#import <sys/sysctl.h>

#ifndef DYLD_INTERPOSE
#define DYLD_INTERPOSE(_replacement, _replacee) \
    __attribute__((used)) static struct { const void *replacement; const void *replacee; } _interpose_##_replacee \
    __attribute__((section("__DATA,__interpose"))) = { \
        (const void *)(unsigned long)&_replacement, \
        (const void *)(unsigned long)&_replacee \
    };
#endif

// Hand Catalyst apps the iOS view of the host network: un-VPN'd iOS devices do
// not expose macOS HTTP/SOCKS system proxies or desktop tunnel interfaces
// (utun*, ppp*, ipsec*, etc.), which third-party risk-control SDKs inspect.
static BOOL shouldHideInterface(const char *name, size_t maxLen) {
    if (!name || maxLen == 0) return NO;
    char buf[32];
    size_t n = maxLen < sizeof(buf) - 1 ? maxLen : sizeof(buf) - 1;
    memcpy(buf, name, n);
    buf[n] = '\0';
    return strncmp(buf, "utun", 4) == 0 ||
           strncmp(buf, "ppp", 3) == 0 ||
           strncmp(buf, "ipsec", 5) == 0 ||
           strncmp(buf, "tap", 3) == 0 ||
           strncmp(buf, "tun", 3) == 0 ||
           strncmp(buf, "gpd", 3) == 0;
}

#pragma mark - System Proxy Shield

static CFDictionaryRef pt_CFNetworkCopySystemProxySettings(void) {
    return CFDictionaryCreate(kCFAllocatorDefault, NULL, NULL, 0,
                              &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
}

static CFArrayRef pt_CFNetworkCopyProxiesForURL(CFURLRef url, CFDictionaryRef proxySettings) {
    (void)url;
    (void)proxySettings;
    const void *keys[] = { kCFProxyTypeKey };
    const void *values[] = { kCFProxyTypeNone };
    CFDictionaryRef direct = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1,
                                                &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFArrayRef result = CFArrayCreate(kCFAllocatorDefault, (const void **)&direct, 1, &kCFTypeArrayCallBacks);
    CFRelease(direct);
    return result;
}

#pragma mark - Virtual Tunnel Interface Filter (sysctl & getifaddrs/freeifaddrs)

typedef struct {
    struct ifaddrs *returnedHead;
    struct ifaddrs *realHead;
} IfaddrsAllocEntry;

static os_unfair_lock gIfaddrsLock = OS_UNFAIR_LOCK_INIT;
static IfaddrsAllocEntry gIfaddrsMap[64];

static void recordIfaddrsHead(struct ifaddrs *returnedHead, struct ifaddrs *realHead) {
    if (returnedHead == realHead) return;
    os_unfair_lock_lock(&gIfaddrsLock);
    for (int i = 0; i < 64; i++) {
        if (gIfaddrsMap[i].returnedHead == NULL) {
            gIfaddrsMap[i].returnedHead = returnedHead;
            gIfaddrsMap[i].realHead = realHead;
            break;
        }
    }
    os_unfair_lock_unlock(&gIfaddrsLock);
}

static struct ifaddrs *consumeRealIfaddrsHead(struct ifaddrs *returnedHead) {
    struct ifaddrs *realHead = returnedHead;
    os_unfair_lock_lock(&gIfaddrsLock);
    for (int i = 0; i < 64; i++) {
        if (gIfaddrsMap[i].returnedHead == returnedHead) {
            realHead = gIfaddrsMap[i].realHead;
            gIfaddrsMap[i].returnedHead = NULL;
            gIfaddrsMap[i].realHead = NULL;
            break;
        }
    }
    os_unfair_lock_unlock(&gIfaddrsLock);
    return realHead;
}

static int pt_sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    int r = sysctl(name, namelen, oldp, oldlenp, newp, newlen);
    if (r != 0 || oldp == NULL || name == NULL || oldlenp == NULL) return r;
    if (!(namelen >= 5 && name[0] == CTL_NET && name[1] == PF_ROUTE && name[4] == NET_RT_IFLIST2)) return r;

    uint8_t *base = (uint8_t *)oldp;
    size_t total = *oldlenp;
    size_t out = 0;
    size_t off = 0;
    BOOL hideCurrentIf = NO;
    while (off + sizeof(struct if_msghdr) <= total) {
        struct if_msghdr *hdr = (struct if_msghdr *)(base + off);
        if (hdr->ifm_msglen == 0 || off + hdr->ifm_msglen > total) break;
        if (hdr->ifm_type == RTM_IFINFO2 && hdr->ifm_msglen >= sizeof(struct if_msghdr2) + sizeof(struct sockaddr_dl)) {
            struct sockaddr_dl *sdl = (struct sockaddr_dl *)((uint8_t *)hdr + sizeof(struct if_msghdr2));
            hideCurrentIf = shouldHideInterface(sdl->sdl_data, sdl->sdl_nlen);
        }
        if (hideCurrentIf) {
            off += hdr->ifm_msglen;
            continue;
        }
        if (out != off) memmove(base + out, base + off, hdr->ifm_msglen);
        out += hdr->ifm_msglen;
        off += hdr->ifm_msglen;
    }
    *oldlenp = out;
    return r;
}

static int pt_getifaddrs(struct ifaddrs **ifap) {
    int r = getifaddrs(ifap);
    if (r != 0 || ifap == NULL || *ifap == NULL) return r;

    struct ifaddrs *realHead = *ifap;
    struct ifaddrs *newHead = realHead;
    struct ifaddrs *prev = NULL;
    struct ifaddrs *cur = realHead;
    while (cur) {
        struct ifaddrs *next = cur->ifa_next;
        if (cur->ifa_name && shouldHideInterface(cur->ifa_name, strlen(cur->ifa_name))) {
            if (prev) {
                prev->ifa_next = next;
            } else {
                newHead = next;
            }
            cur->ifa_next = NULL;
        } else {
            prev = cur;
        }
        cur = next;
    }
    *ifap = newHead;
    if (newHead != NULL && newHead != realHead) {
        recordIfaddrsHead(newHead, realHead);
    } else if (newHead == NULL && realHead != NULL) {
        freeifaddrs(realHead);
    }
    return r;
}

static void pt_freeifaddrs(struct ifaddrs *ifa) {
    if (!ifa) return;
    struct ifaddrs *realHead = consumeRealIfaddrsHead(ifa);
    freeifaddrs(realHead);
}

DYLD_INTERPOSE(pt_CFNetworkCopySystemProxySettings, CFNetworkCopySystemProxySettings)
DYLD_INTERPOSE(pt_CFNetworkCopyProxiesForURL, CFNetworkCopyProxiesForURL)
DYLD_INTERPOSE(pt_sysctl, sysctl)
DYLD_INTERPOSE(pt_getifaddrs, getifaddrs)
DYLD_INTERPOSE(pt_freeifaddrs, freeifaddrs)

__attribute__((constructor)) static void shield_init(void) {
    NSLog(@"[ProxyShield] active pid=%d", getpid());
}
