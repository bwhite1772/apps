"""
Applet: GCal Meetings
Summary: Today's remaining meetings
Description: Shows upcoming and ongoing meetings from Google Calendar for the rest of today using a private ICS URL.
Author: bwhite1772
"""

load("animation.star", "animation")
load("encoding/json.star", "json")
load("http.star", "http")
load("render.star", "render")
load("schema.star", "schema")
load("time.star", "time")

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
                id = "ics_url",
                name = "Google Calendar ICS URL",
                desc = "Google Calendar → three dots next to calendar → Settings and sharing → Secret address in iCal format",
                icon = "calendar",
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
    ics_url = config.get("ics_url", "")
    if not ics_url:
        return render_message("Add your Google Calendar ICS URL in settings", "#FF8800")

    location = config.get("location")
    loc = json.decode(location) if location else {}
    timezone = loc.get("timezone", "America/New_York")
    now = time.now()
    now_local = now.in_location(timezone)

    resp = http.get(ics_url, ttl_seconds = 300)
    if resp.status_code != 200:
        return render_message("Could not fetch calendar", "#FF3333")

    events = parse_ical(resp.body(), timezone, now.unix, now_local)
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

# ── iCal parser ──────────────────────────────────────────────────────────────

def parse_ical(body, timezone, now_unix, now_local):
    # Unfold RFC 5545 line continuations (CRLF + space or tab)
    body = body.replace("\r\n ", "").replace("\r\n\t", "")
    body = body.replace("\r\n", "\n").replace("\r", "\n")

    today_start_unix = time.time(
        year = now_local.year, month = now_local.month, day = now_local.day,
        hour = 0, minute = 0, second = 0, location = timezone,
    ).unix
    today_end_unix = time.time(
        year = now_local.year, month = now_local.month, day = now_local.day,
        hour = 23, minute = 59, second = 59, location = timezone,
    ).unix

    events = []
    in_event = False
    props = {}

    for line in body.split("\n"):
        line = line.rstrip("\r")
        if line == "BEGIN:VEVENT":
            in_event = True
            props = {}
        elif line == "END:VEVENT":
            in_event = False
            event = process_event(props, timezone, now_unix, today_start_unix, today_end_unix)
            if event:
                events.append(event)
        elif in_event and ":" in line:
            colon = line.find(":")
            semi = line.find(";")
            if 0 < semi < colon:
                name = line[:semi]
                params = line[semi + 1:colon]
                value = line[colon + 1:]
            else:
                name = line[:colon]
                params = ""
                value = line[colon + 1:]
            props[name] = (value, params)

    def sort_key(e):
        return e["start_unix"]

    return sorted(events, key = sort_key)

def process_event(props, timezone, now_unix, today_start_unix, today_end_unix):
    status = props.get("STATUS", ("", ""))[0].upper()
    if status == "CANCELLED":
        return None

    dtstart = props.get("DTSTART")
    dtend = props.get("DTEND")
    if not dtstart or not dtend:
        return None

    start_t = parse_dt(dtstart[0], dtstart[1], timezone)
    end_t = parse_dt(dtend[0], dtend[1], timezone)
    if not start_t or not end_t:
        return None  # all-day or unparseable

    # Keep events that end after now and start before end of today
    if end_t.unix <= now_unix:
        return None
    if start_t.unix > today_end_unix:
        return None

    summary = unescape(props.get("SUMMARY", ("(No title)", ""))[0])
    start_local = start_t.in_location(timezone)

    return {
        "title": summary,
        "time_str": fmt_time(start_local),
        "start_unix": start_t.unix,
        "ongoing": start_t.unix <= now_unix,
    }

def parse_dt(value, params, fallback_tz):
    # All-day events have no time component
    if "T" not in value:
        return None

    if value.endswith("Z"):
        tz = "UTC"
        value = value[:-1]
    elif "TZID=" in params:
        idx = params.find("TZID=")
        tz = params[idx + 5:]
        semi = tz.find(";")
        if semi >= 0:
            tz = tz[:semi]
    else:
        tz = fallback_tz

    if len(value) < 13:
        return None

    year = int(value[0:4])
    month = int(value[4:6])
    day = int(value[6:8])
    hour = int(value[9:11])
    minute = int(value[11:13])
    second = int(value[13:15]) if len(value) >= 15 else 0

    return time.time(
        year = year, month = month, day = day,
        hour = hour, minute = minute, second = second,
        location = tz,
    )

def unescape(s):
    return s.replace("\\,", ",").replace("\\;", ";").replace("\\n", " ").replace("\\N", " ")

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
