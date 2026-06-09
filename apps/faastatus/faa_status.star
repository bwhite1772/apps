"""
Applet: FAA Status
Summary: FAA airport status board
Description: Compact 4-row display of airport closures, ground stops, and delays, color-coded by severity.
Author: bwhite1772
"""

load("animation.star", "animation")
load("http.star", "http")
load("render.star", "render")
load("schema.star", "schema")
load("xpath.star", "xpath")

API_URL = "https://nasstatus.faa.gov/api/airport-status-information"

COLOR_CLOSURE = "#FF3333"
COLOR_GROUND_STOP = "#FF8800"
COLOR_DELAY = "#FFDD00"
COLOR_TYPE = "#777777"
COLOR_INFO = "#CCCCCC"

ROWS_PER_PAGE = 4
PAGE_FRAMES = 120  # 120 * 50ms = 6 seconds per page

def get_schema():
    return schema.Schema(
        version = "1",
        fields = [
            schema.Text(
                id = "airports",
                name = "Airports",
                desc = "Comma-separated airport codes to monitor (e.g. ATL,ORD). Leave empty for all.",
                icon = "plane",
                default = "",
            ),
        ],
    )

def main(config):
    airports_str = config.get("airports", "")
    filter_list = [s.strip().upper() for s in airports_str.split(",") if s.strip()]

    entries = load_entries(filter_list)
    if not entries:
        return []

    pages = []
    for i in range(0, len(entries), ROWS_PER_PAGE):
        chunk = entries[i:i + ROWS_PER_PAGE]
        pages.append(render_page(chunk))

    return render.Root(
        child = render.Sequence(children = pages),
        show_full_animation = True,
    )

def render_page(entries):
    rows = [render_row(e) for e in entries]
    while len(rows) < ROWS_PER_PAGE:
        rows.append(render.Box(width = 64, height = 8))

    return animation.Transformation(
        child = render.Column(children = rows, expanded = True),
        duration = PAGE_FRAMES,
        keyframes = [],
        wait_for_child = True,
    )

def render_row(entry):
    t = entry["type"]

    if t == "closure":
        color = COLOR_CLOSURE
        label = "CLSD"
    elif t == "ground_stop":
        color = COLOR_GROUND_STOP
        label = "GS"
    elif t == "ground_delay":
        color = COLOR_DELAY
        label = "GD"
    elif t == "arrival_delay":
        color = COLOR_DELAY
        label = "ARR"
    else:
        color = COLOR_DELAY
        label = "DEP"

    return render.Row(
        children = [
            render.Box(
                width = 18,
                height = 8,
                child = render.Text(entry["airport"], color = color, font = "tom-thumb"),
            ),
            render.Box(
                width = 16,
                height = 8,
                child = render.Text(label, color = COLOR_TYPE, font = "tom-thumb"),
            ),
            render.Box(
                width = 30,
                height = 8,
                child = render.Marquee(
                    child = render.Text(entry["info"], color = COLOR_INFO, font = "tom-thumb"),
                    width = 30,
                    scroll_direction = "horizontal",
                ),
            ),
        ],
    )

def load_entries(filter_airports):
    resp = http.get(API_URL, ttl_seconds = 60)
    if resp.status_code != 200:
        return []

    xp = xpath.loads(resp.body())
    closures = []
    ground_stops = []
    delays = []

    # Closures — skip GA aircraft restrictions
    for node in xp.query_all_nodes("/AIRPORT_STATUS_INFORMATION/Delay_type/Airport_Closure_List/Airport"):
        airport = node.query("/ARPT")
        reason = node.query("/Reason")
        if "GA ACFT" in reason.upper():
            continue
        if filter_airports and airport.upper() not in filter_airports:
            continue
        reopen = node.query("/Reopen")
        info = compact_time(reopen) if reopen else "CLSD"
        closures.append({"type": "closure", "airport": airport, "info": info})

    # Ground stops
    for node in xp.query_all_nodes("/AIRPORT_STATUS_INFORMATION/Delay_type/Ground_Stop_List/Program"):
        airport = node.query("/ARPT")
        if filter_airports and airport.upper() not in filter_airports:
            continue
        end_time = compact_time(node.query("/End_Time"))
        ground_stops.append({"type": "ground_stop", "airport": airport, "info": "til " + end_time})

    # Ground delays
    for node in xp.query_all_nodes("/AIRPORT_STATUS_INFORMATION/Delay_type/Ground_Delay_List/Ground_Delay"):
        airport = node.query("/ARPT")
        if filter_airports and airport.upper() not in filter_airports:
            continue
        avg = parse_duration(node.query("/Avg"))
        delays.append({"type": "ground_delay", "airport": airport, "info": fmt_duration(avg)})

    # Arrival/departure delays
    for node in xp.query_all_nodes("/AIRPORT_STATUS_INFORMATION/Delay_type/Arrival_Departure_Delay_List/Delay"):
        airport = node.query("/ARPT")
        if filter_airports and airport.upper() not in filter_airports:
            continue
        kind = node.query("/Arrival_Departure/@Type").lower()
        lo = parse_duration(node.query("/Arrival_Departure/Min"))
        hi = parse_duration(node.query("/Arrival_Departure/Max"))
        info = fmt_range(lo, hi)
        delays.append({"type": kind + "_delay", "airport": airport, "info": info})

    return closures + ground_stops + delays

# Strips timezone label and spaces from time strings like "4:00 PM EDT"
def compact_time(s):
    s = s.lower().strip()
    digits = "0123456789"
    result = []
    for part in s.split(" "):
        if len(part) == 0:
            continue
        if part[0] in digits or part in ["am", "pm"]:
            result.append(part)
    return "".join(result)

# Parses "1 hour and 30 minutes" → 90
def parse_duration(s):
    parts = s.split()
    total = 0
    for i in range(len(parts)):
        v = to_int(parts[i])
        if v < 0:
            continue
        if i + 1 >= len(parts):
            return -1
        unit = parts[i + 1].lower()
        if "hour" in unit:
            total += v * 60
        elif "minute" in unit:
            total += v
        else:
            return -1
    return total

def fmt_duration(minutes):
    if minutes < 0:
        return "?"
    if minutes < 60:
        return "%dm" % minutes
    h = minutes // 60
    m = minutes % 60
    if m == 0:
        return "%dh" % h
    return "%dh%dm" % (h, m)

def fmt_range(lo, hi):
    if lo < 0 and hi < 0:
        return "?"
    if lo < 0:
        return fmt_duration(hi)
    if hi < 0:
        return fmt_duration(lo)
    return "%s-%s" % (fmt_duration(lo), fmt_duration(hi))

def to_int(s):
    if not s:
        return -1
    for c in s.elems():
        if c not in "0123456789":
            return -1
    return int(s)
