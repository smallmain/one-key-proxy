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
LOCAL_SS_METHOD = "aes-128-gcm"
LOCAL_SS_GROUP = "SM"
LOCAL_SS_TAGS = "稳定"
SINGBOX_INBOUND = {"type": "shadowsocks", "listen": "127.0.0.1"}
SINGBOX_OUTBOUND = {"type": "vless"}
