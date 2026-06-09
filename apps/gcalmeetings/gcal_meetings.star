"""
Applet: GCal Meetings
Summary: Today's remaining meetings
Description: Shows upcoming and ongoing meetings from Google Calendar for the rest of today.
Author: bwhite1772
"""

load("animation.star", "animation")
load("cache.star", "cache")
load("encoding/json.star", "json")
load("http.star", "http")
load("render.star", "render")
load("schema.star", "schema")
load("time.star", "time")

TOKEN_URL = "https://oauth2.googleapis.com/token"
EVENTS_URL = "https://www.googleapis.com/calendar/v3/calendars/primary/events"
RFC3339 = "2006-01-02T15:04:05Z07:00"

COLOR_TIME = "#4FC3F7"
COLOR_TIME_NOW = "#FFDD00"
COLOR_TITLE = "#FFFFFF"
COLOR_DIM = "#888888"

ROWS_PER_PAGE = 4
PAGE_FRAMES = 150  # 7.5s per page

def get_schema():
    return schema.Schema(
        version = "1",
        fields = [
            schema.Text(
                id = "client_id",
                name = "Google Client ID",
                desc = "OAuth2 Client ID from Google Cloud Console (Web app or Desktop type).",
                icon = "key",
                default = "",
            ),
            schema.Text(
                id = "client_secret",
                name = "Google Client Secret",
                desc = "OAuth2 Client Secret from Google Cloud Console.",
                icon = "lock",
                default = "",
            ),
            schema.Text(
                id = "refresh_token",
                name = "Refresh Token",
                desc = "One-time setup: get from https://developers.google.com/oauthplayground using scope https://www.googleapis.com/auth/calendar.readonly",
                icon = "arrowsRotate",
                default = "",
            ),
            schema.Location(
                id = "location",
                name = "Location",
                desc = "Your location (used for timezone).",
                icon = "locationDot",
            ),
        ],
    )

def main(config):
    client_id = config.get("client_id", "")
    client_secret = config.get("client_secret", "")
    refresh_token = config.get("refresh_token", "")

    if not client_id or not client_secret or not refresh_token:
        return render_message("Configure Google Calendar in app settings", "#FF8800")

    # Cache access token (valid 1 hour); key on last 12 chars of refresh token
    cache_key = "gcal_tok_" + refresh_token[-12:]
    access_token = cache.get(cache_key)
    if not access_token:
        access_token = refresh_access_token(client_id, client_secret, refresh_token)
        if not access_token:
            return render_message("Auth failed — check credentials", "#FF3333")
        cache.set(cache_key, access_token, ttl_seconds = 3000)

    location = config.get("location")
    loc = json.decode(location) if location else {}
    timezone = loc.get("timezone", "America/New_York")
    now = time.now().in_location(timezone)

    events = fetch_events(access_token, timezone, now)
    if not events:
        return render_message("No meetings today", COLOR_DIM)

    pages = []
    for i in range(0, len(events), ROWS_PER_PAGE):
        chunk = events[i:i + ROWS_PER_PAGE]
        pages.append(render_page(chunk))

    return render.Root(
        child = render.Sequence(children = pages),
        show_full_animation = True,
    )

def render_page(events):
    rows = [render_row(e) for e in events]
    while len(rows) < ROWS_PER_PAGE:
        rows.append(render.Box(width = 64, height = 8))
    return animation.Transformation(
        child = render.Column(children = rows, expanded = True),
        duration = PAGE_FRAMES,
        keyframes = [],
        wait_for_child = True,
    )

def render_row(event):
    time_color = COLOR_TIME_NOW if event["ongoing"] else COLOR_TIME
    return render.Row(
        children = [
            render.Box(
                width = 24,
                height = 8,
                child = render.Text(event["time_str"], color = time_color, font = "tom-thumb"),
            ),
            render.Box(
                width = 40,
                height = 8,
                child = render.Marquee(
                    child = render.Text(event["title"], color = COLOR_TITLE, font = "tom-thumb"),
                    width = 40,
                    scroll_direction = "horizontal",
                ),
            ),
        ],
    )

def render_message(msg, color):
    return render.Root(
        child = render.Box(
            width = 64,
            height = 32,
            child = render.WrappedText(
                content = msg,
                color = color,
                width = 62,
                align = "center",
                font = "tom-thumb",
            ),
        ),
    )

def refresh_access_token(client_id, client_secret, refresh_token):
    resp = http.post(
        TOKEN_URL,
        headers = {"Content-Type": "application/x-www-form-urlencoded"},
        body = "grant_type=refresh_token&refresh_token=%s&client_id=%s&client_secret=%s" % (
            refresh_token,
            client_id,
            client_secret,
        ),
    )
    if resp.status_code != 200:
        return None
    return json.decode(resp.body()).get("access_token")

def fetch_events(access_token, timezone, now):
    now_utc = time.now()
    end_of_day = time.time(
        year = now.year,
        month = now.month,
        day = now.day,
        hour = 23,
        minute = 59,
        second = 59,
        location = timezone,
    )

    # timeMin (lower bound on end time) = now → returns ongoing + upcoming events
    # timeMax (upper bound on start time) = end of local day → only today
    resp = http.get(
        EVENTS_URL,
        headers = {"Authorization": "Bearer " + access_token},
        params = {
            "timeMin": now_utc.format(RFC3339),
            "timeMax": end_of_day.format(RFC3339),
            "singleEvents": "true",
            "orderBy": "startTime",
            "maxResults": "20",
        },
        ttl_seconds = 60,
    )
    if resp.status_code != 200:
        return []

    items = json.decode(resp.body()).get("items", [])
    now_unix = now_utc.unix
    result = []

    for item in items:
        if item.get("status") == "cancelled":
            continue

        start_raw = item.get("start", {})
        end_raw = item.get("end", {})

        # Skip all-day events (they have "date", not "dateTime")
        if "dateTime" not in start_raw:
            continue

        start_t = time.parse_time(start_raw["dateTime"], format = RFC3339)
        end_t = time.parse_time(end_raw["dateTime"], format = RFC3339)

        ongoing = start_t.unix <= now_unix and now_unix < end_t.unix
        start_local = start_t.in_location(timezone)

        result.append({
            "title": item.get("summary", "(No title)"),
            "time_str": fmt_time(start_local),
            "ongoing": ongoing,
        })

    return result

# Formats a local time as "9a", "9:30a", "12p", "1:30p"
def fmt_time(t):
    h = t.hour
    m = t.minute
    suffix = "a" if h < 12 else "p"
    if h == 0:
        h = 12
    elif h > 12:
        h = h - 12
    if m == 0:
        return "%d%s" % (h, suffix)
    return "%d:%02d%s" % (h, m, suffix)
