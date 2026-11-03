"""Built-in defaults for new configurations; never include connection credentials."""

AIRPORT_DEFAULTS = {
    "cronExpr": "0 0 * * *", "enabled": True, "group": "SM",
    "downloadWithProxy": False, "proxyLink": "", "userAgent": "", "requestHeaders": [],
    "fetchUsageInfo": True, "skipTLSVerify": False, "updateAfterDetect": True,
    "updateAfterDetectProfileId": 1, "updateAfterDetectChangedOnly": True,
    "remark": "", "logo": "", "nodeNameWhitelist": "", "nodeNameBlacklist": "",
    "protocolWhitelist": "", "protocolBlacklist": "", "nodeNamePreprocess": "",
    "deduplicationRule": "", "nodeNameUniquify": True, "nodeNamePrefix": "[SM]",
    "nodeNameIntraUniquify": False, "autoFillCountry": False, "backfillExistingCountry": False,
}
LOCAL_NODE_PORT_START = 7896
LOCAL_NODE_GROUP = "SM"
LOCAL_NODE_TAGS = "稳定"
RESIDENTIAL_TAG = "家宽"


def residential_tags(tags, residential):
    if residential is None:
        return list(dict.fromkeys(tags))
    values = set(tags)
    if residential is True:
        values.add(RESIDENTIAL_TAG)
    elif residential is False:
        values.discard(RESIDENTIAL_TAG)
    return sorted(values)


SINGBOX_INBOUND = {"type": "socks", "listen": "127.0.0.1"}
SINGBOX_OUTBOUND = {"type": "vless"}
