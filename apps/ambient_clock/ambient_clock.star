"""
Applet: Ambient Clock
Summary: Time, temp, humidity & date from your Ambient Weather station
Description: Displays the time alongside live temperature and humidity from your Ambient Weather personal weather station, with a small calendar icon showing today's date.
Author: bwhite1772
Version: 1.0
"""

load("encoding/json.star", "json")
load("http.star", "http")
load("render.star", "render")
load("schema.star", "schema")
load("time.star", "time")

API_BASE = "https://rt.ambientweather.net/v1"

DEFAULT_LOCATION = """
{
	"lat": "40.6781784",
	"lng": "-73.9441579",
	"description": "Brooklyn, NY, USA",
	"locality": "Brooklyn",
	"place_id": "ChIJCSF8lBZEwokRhngABHRcdoI",
	"timezone": "America/New_York"
}
"""

TEMP_COLOR_DEFAULT = "#FFFFFF"
TIME_NIGHT_COLOR = "#333333"
HUMIDITY_COLOR = "#848fEE"
CAL_HEADER_COLOR = "#990000"

def get_ambient_latest(api_key, app_key, mac):
    auth = "apiKey=%s&applicationKey=%s" % (api_key, app_key)

    if not mac:
        rep = http.get("%s/devices?%s" % (API_BASE, auth), ttl_seconds = 300)
        if rep.status_code != 200:
            return None
        devices = rep.json()
        if not devices:
            return None
        mac = (devices[0].get("macAddress") or "").strip()
        if not mac:
            return None

    rep = http.get(
        "%s/devices/%s?%s&limit=1" % (API_BASE, mac, auth),
        ttl_seconds = 300,
    )
    if rep.status_code != 200:
        return None

    records = rep.json()
    if not records:
        return None
    return records[0]

def calendar_icon(now):
    month = now.format("Jan").upper()
    day = str(now.day)
    return render.Column(
        children = [
            render.Box(
                width = 16,
                height = 6,
                color = CAL_HEADER_COLOR,
                child = render.Text(content = month, font = "tom-thumb", color = "#FFFFFF"),
            ),
            render.Box(
                width = 16,
                height = 10,
                color = "#FFFFFF",
                child = render.Text(content = day, font = "tb-8", color = "#000000"),
            ),
        ],
    )

def night_screen(now, config):
    use_24_hour = config.bool("24hour_format", False)
    time_color = TIME_NIGHT_COLOR

    if config.bool("blink", True):
        blink_vec = [render.Text(":", font = "6x13", color = time_color)] * 5
        blink_vec.extend([render.Text(":", font = "6x13", color = "#000")] * 5)
        blink_text = render.Animation(blink_vec)
    else:
        blink_text = render.Text(":", font = "6x13", color = time_color)

    if use_24_hour:
        hour_text = now.format("15")
        minute_text = now.format("04")
    else:
        if now.hour == 0:
            hour_text = "12"
        elif now.hour > 12:
            hour_text = str(now.hour - 12)
        else:
            hour_text = str(now.hour)
        minute_text = now.format("04 PM")

    return render.Root(
        delay = 500,
        max_age = 120,
        child = render.Padding(
            pad = (0, 8, 0, 0),
            child = render.Column(
                expanded = True,
                cross_align = "center",
                children = [
                    render.Box(width = 64, height = 1),
                    render.Row(
                        children = [
                            render.Text(content = hour_text, font = "6x13", color = time_color),
                            blink_text,
                            render.Text(content = minute_text, font = "6x13", color = time_color),
                        ],
                    ),
                ],
            ),
        ),
    )

def main(config):
    location_info = json.decode(config.get("location", DEFAULT_LOCATION))
    timezone = location_info["timezone"]

    now = time.now().in_location(timezone)

    night_mode_start_str = config.get("nightModeStart")
    if not night_mode_start_str:
        night_mode_start_hr = 23
        night_mode_start_min = 0
    else:
        night_mode_start_hr = int(night_mode_start_str[0:2])
        if night_mode_start_hr >= 24:
            night_mode_start_hr = 0
        night_mode_start_min = int(night_mode_start_str[2:4])

    night_mode_end_str = config.get("nightModeEnd")
    if not night_mode_end_str:
        night_mode_end_hr = 7
        night_mode_end_min = 0
    else:
        night_mode_end_hr = int(night_mode_end_str[0:2])
        night_mode_end_min = int(night_mode_end_str[2:4])

    start_total = night_mode_start_hr * 60 + night_mode_start_min
    end_total = night_mode_end_hr * 60 + night_mode_end_min

    if config.bool("night_mode", False):
        current_total = now.hour * 60 + now.minute
        if start_total > end_total:
            in_night_mode = current_total >= start_total or current_total < end_total
        else:
            in_night_mode = current_total >= start_total and current_total < end_total

        if in_night_mode:
            return night_screen(now, config)

    use_24_hour = config.bool("24hour_format", False)
    time_color = config.get("time_color", "fff")

    if config.bool("blink", True):
        blink_vec = [render.Text(":", font = "6x13", color = time_color)] * 5
        blink_vec.extend([render.Text(":", font = "6x13", color = "#000")] * 5)
        blink_text = render.Animation(blink_vec)
    else:
        blink_text = render.Text(":", font = "6x13", color = time_color)

    if use_24_hour:
        hour_text = now.format("15")
        minute_text = now.format("04")
    else:
        if now.hour == 0:
            hour_text = "12"
        elif now.hour > 12:
            hour_text = str(now.hour - 12)
        else:
            hour_text = str(now.hour)
        minute_text = now.format("04 PM")

    api_key = config.get("api_key") or ""
    app_key = config.get("app_key") or ""
    mac = (config.get("mac_address") or "").strip()
    system_of_measurement = (config.get("systemOfMeasurement") or "Imperial").lower()
    temp_color = config.get("tempColor", TEMP_COLOR_DEFAULT)
    display_metric = (system_of_measurement == "metric")

    display_sample = not (api_key and app_key)

    if display_sample:
        temp_val = 14 if display_metric else 57
        humidity_val = 50
    else:
        record = get_ambient_latest(api_key, app_key, mac)
        if not record:
            temp_val = "?"
            humidity_val = "?"
        else:
            tempf = record.get("tempf")
            humidity_raw = record.get("humidity")

            if tempf == None:
                temp_val = "?"
            elif display_metric:
                temp_val = int((tempf - 32) * 5.0 / 9.0 + 0.5)
            else:
                temp_val = int(tempf + 0.5)

            if humidity_raw == None:
                humidity_val = "?"
            else:
                humidity_val = int(humidity_raw + 0.5)

    show_unit = config.bool("show_temp_unit", True)
    temp_unit = ("C" if display_metric else "F") if show_unit else ""
    temp_text = render.Text(
        content = "%s°%s" % (str(temp_val), temp_unit),
        font = "5x8",
        color = temp_color,
    )
    if display_sample:
        humidity_text = render.Text(content = "SAMPLE", font = "tom-thumb", color = "#FF0000")
    else:
        humidity_text = render.Text(
            content = "%s%%" % str(humidity_val),
            font = "5x8",
            color = HUMIDITY_COLOR,
        )

    return render.Root(
        delay = 500,
        max_age = 60,
        child = render.Box(
            render.Column(
                expanded = True,
                main_align = "space_evenly",
                cross_align = "center",
                children = [
                    render.Row(
                        children = [
                            render.Text(content = hour_text, font = "6x13", color = time_color),
                            blink_text,
                            render.Text(content = minute_text, font = "6x13", color = time_color),
                        ],
                    ),
                    render.Row(
                        cross_align = "center",
                        children = [
                            calendar_icon(now),
                            render.Box(width = 4, height = 1),
                            render.Column(
                                children = [
                                    temp_text,
                                    humidity_text,
                                ],
                            ),
                        ],
                    ),
                ],
            ),
        ),
    )

def get_schema():
    return schema.Schema(
        version = "1",
        fields = [
            schema.Location(
                id = "location",
                name = "Location",
                desc = "Used to determine your timezone for the clock.",
                icon = "locationArrow",
            ),
            schema.Toggle(
                id = "24hour_format",
                name = "24 hour clock",
                desc = "Enable for 24-hour time format.",
                icon = "clock",
                default = False,
            ),
            schema.Color(
                id = "time_color",
                name = "Time color",
                desc = "Change the color of the time.",
                icon = "brush",
                default = "fff",
            ),
            schema.Text(
                id = "api_key",
                name = "Ambient Weather API Key",
                desc = "Your Ambient Weather API key (ambientweather.net/account)",
                icon = "key",
                default = "",
            ),
            schema.Text(
                id = "app_key",
                name = "Ambient Weather Application Key",
                desc = "Your Ambient Weather application key",
                icon = "key",
                default = "",
            ),
            schema.Text(
                id = "mac_address",
                name = "Device MAC Address",
                desc = "MAC address of your weather station (leave blank to use first device)",
                icon = "wifi",
                default = "",
            ),
            schema.Dropdown(
                id = "systemOfMeasurement",
                name = "System of measurement",
                desc = "Choose which system to display measurements",
                icon = "ruler",
                default = "Imperial",
                options = [
                    schema.Option(display = "Imperial", value = "Imperial"),
                    schema.Option(display = "Metric", value = "Metric"),
                ],
            ),
            schema.Color(
                id = "tempColor",
                name = "Temperature color",
                desc = "Color for temperature display",
                icon = "brush",
                default = TEMP_COLOR_DEFAULT,
            ),
            schema.Toggle(
                id = "show_temp_unit",
                name = "Show temperature unit",
                desc = "Display C or F after temperature",
                icon = "thermometer",
                default = True,
            ),
            schema.Toggle(
                id = "blink",
                name = "Blinking separator",
                desc = "Blink the colon between hours and minutes.",
                icon = "gear",
                default = True,
            ),
            schema.Toggle(
                id = "night_mode",
                name = "Night Mode",
                desc = "Enable night mode - Dim the display and show only the clock",
                icon = "gear",
                default = False,
            ),
            schema.Text(
                id = "nightModeStart",
                name = "Night Mode Start",
                icon = "clock",
                desc = "Use 24-hour format (HHmm), e.g. 2300",
                default = "2300",
            ),
            schema.Text(
                id = "nightModeEnd",
                name = "Night Mode End",
                icon = "clock",
                desc = "Use 24-hour format (HHmm), e.g. 0730",
                default = "0700",
            ),
        ],
    )
