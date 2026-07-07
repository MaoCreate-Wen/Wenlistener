# Netease Cloud Music (网易云音乐) — API Contract Spec for Dart

> Source: `Spider/WYmusic/{encrypt,songinfo,login,search,loginQRcode}.py`, `cookies.json`.
> All endpoints are **weapi** (the only scheme used). Port directly to Dart.

## Request envelope (every endpoint)
```
POST https://music.163.com/weapi/<path>?csrf_token=<__csrf cookie>
Content-Type: application/x-www-form-urlencoded
Body: params=<weapi base64>&encSecKey=<weapi hex>
```
`csrf_token` appears in 3 places consistently: URL query, payload field, and == `__csrf` cookie.

### Common headers
| Header | Value |
|---|---|
| content-type | application/x-www-form-urlencoded |
| origin | https://music.163.com |
| referer | https://music.163.com/ (search: .../search/) |
| user-agent | `pan.baidu.com` (enough for data APIs); login uses full Chrome UA |
| nm-gcore-status | 1 |

Login extra headers: `x-os: web`, `x-loginmethod: QrCode`, `x-login-chain-id: <chainId>`,
full Chrome UA.

## Endpoints
| # | Endpoint | Auth | Key payload fields |
|---|---|---|---|
| 1 | `/weapi/cloudsearch/pc` | no | s, type, limit, offset, total, csrf_token |
| 2 | `/weapi/v3/song/detail` | optional | c=`[{"id":"..."}]` (JSON string), csrf_token |
| 3 | `/weapi/song/enhance/player/url/v1` | **MUSIC_U** | ids=`[id]` (string), level, encodeType, csrf_token |
| 4 | `/weapi/song/enhance/download/url` | **MUSIC_U** | id, br, csrf_token |
| 5 | `/weapi/login/qrcode/unikey` | no | type=1 |
| 6 | `/weapi/login/qrcode/client/login` | no | type=1, noCheckToken, key, ydDeviceToken |
| 7 | `/weapi/song/lyric` | no | id, lv:-1, kv:-1, tv:-1, csrf_token |
| 8 | `/weapi/w/nuser/account/get` | yes | csrf_token |

### 1. Search → `result.songs[i]`: `.id .name .ar[].name .al.{name,picUrl} .dt(ms) .fee .privilege`
`type`: 1=song 10=album 100=artist 1000=playlist 1006=lyric 1018=综合. `limit`/`offset` paginate.
**Note:** use `/weapi/cloudsearch/pc` — the older `/weapi/cloudsearch/get/web` now returns
risk-control code `50000005` for anonymous callers. `/pc` serves the identical rich shape.

### 2. Song detail → `songs[0]`: `.id .name .ar[].name .al.{name,picUrl} .dt`; `privileges[0].{fee,maxbr,st}`.
**Gotcha:** `c = jsonEncode([{"id": songId.toString()}])` — a JSON **string** nested inside the payload map.

### 3. Play URL → `data[0]`: `.url (null if not entitled) .br .type .size .md5`
`level`: standard|higher|exhigh|lossless|hires. `encodeType` = "flac" if level∈{lossless,hires} else "aac".
`ids` = `"[$songId]"` (a bracketed **string**, not a JSON array). BR_MAP: standard128k/higher192k/exhigh320k/lossless+hires999k.

### 4. Download URL → `data`: `.url .br .size .type .md5 .expi(seconds) .sr`
`id` = string, `br` = int (128000/192000/320000/999000).

### 5/6. QR Login
- Create: payload `{type:1}` → `unikey` (or `data.unikey`).
- QR content the user scans: `https://music.163.com/st/platform/scanlogin?codekey=<unikey>&chainId=<chainId>&hdw_device=web&hdw_appid=web&hitExp=1`
  where `chainId = "v1_${sDeviceId}_web_login_${epochMs}"`.
- Poll: payload `{type:1, noCheckToken:true, key:<unikey>, ydDeviceToken:base64(24 random bytes)}`,
  every 2s, timeout 180s. **No csrf_token** in this payload.
- **Status codes (canonical — source map is mislabeled):**
  - 800 = QR expired/not exist
  - 801 = waiting for scan
  - 802 = scanned, waiting for phone confirm
  - **803 = ✅ AUTHORIZED (success)** — auth cookies arrive via **Set-Cookie response headers**, NOT JSON body.
    Capture `MUSIC_U` + `__csrf` from Set-Cookie.
  - 860 = QR invalidated

### 7. Lyric → `lrc.lyric` (plain LRC), `tlyric.lyric` (translation), `klyric.lyric` (word-by-word karaoke).
Not in crawler but standard weapi; needed for the AMLL lyric view (klyric drives word-by-word).

## Encryption — weapi (`encrypt.py`)
Constants (exact):
```
FIXED_AES_KEY = "0CoJUm6Qyw8W8jud"   (16 bytes, AES-128-CBC)
AES_IV        = "0102030405060708"   (16 bytes)
RSA_PUB_EXP   = 0x10001
RSA_MODULUS (1024-bit hex):
00e0b509f6259df8642dbc35662901477df22677ec152b5ff68ace615bb7b725152b3ab17a876aea8a5aa76d2e417629ec4ee341f56135fccf695280104e0312ecbda92557c93870114af6c9d05c4f7f0c3685b7a46bee255932575cce10b424d813cfe4875d3e82047b97ddef52741d546b8e289dc6935b3ece0462db0a22b8e7
random key charset: base62 (a-zA-Z0-9), length 16
```
Algorithm:
1. `text = jsonEncode(payload)`
2. `randKey` = 16 random base62 chars
3. `e1 = base64(AES-128-CBC(text, key=FIXED_AES_KEY, iv=AES_IV, PKCS7))`
4. `params = base64(AES-128-CBC(e1, key=randKey, iv=AES_IV, PKCS7))`  (same IV)
5. `encSecKey = rsaNoPad(randKey)`:
   - `rev = randKey reversed`
   - `m = BigInt from UTF-8 bytes of rev (big-endian)`
   - `c = m.modPow(0x10001, RSA_MODULUS)`
   - `encSecKey = c.toRadixString(16).padLeft(256, '0')`  (lowercase hex)
6. Form body: `{params, encSecKey}`.

`params` = base64, `encSecKey` = lowercase hex padded to 256. RSA is **textbook/no-padding** on
the **reversed** key bytes. Recommended Dart libs: `pointycastle` (AES + BigInt modPow) or `encrypt`.

## Auth / cookies
- **`MUSIC_U`** = login session token. Required for play-url/download to return real (non-trial) URLs.
  VIP/Hi-Res additionally requires a VIP account.
- **`__csrf`** = CSRF token; must equal `csrf_token` in query + payload.
- After QR success (803): read Set-Cookie → store `MUSIC_U`, `__csrf` in a cookie jar → reuse on all calls.
- Anonymous browsing (search, detail, free-song play) works without login.

## Port gotchas
1. Double JSON encoding for `c` (song detail); `ids`/`[id]` are **strings**, not arrays.
2. `params` base64 vs `encSecKey` hex — different encodings.
3. RSA textbook no-padding on reversed key; 1024-bit modulus.
4. QR success = 803 via Set-Cookie (not 802/JSON).
5. UA `pan.baidu.com` suffices for data APIs.
