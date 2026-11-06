#!/usr/bin/env python3
"""The Apple TV app's showcase: made-up titles with generated artwork and
the API answers they'd come with, so every screen can be drawn and
screenshotted without a server (`-StreamShowcase YES`, UI tests).

Run from clients/appletv:  python3 Scripts/showcase.py
Writes StreamTV/Resources/Showcase/ (images, a short video, JSON). The
titles are invented; the artwork is gradients and type drawn by ffmpeg.
"""
import json
import os
import subprocess
from datetime import datetime, timedelta, timezone

OUT = os.path.join(os.path.dirname(__file__), "..", "StreamTV", "Resources", "Showcase")
FONT = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"
FONT_LIGHT = "/System/Library/Fonts/Supplemental/Arial.ttf"
os.makedirs(OUT, exist_ok=True)

MOVIES = [
    ("northbound", "Northbound", 2019, "PG-13", 118, ["Drama", "Adventure"], "#1d3557", "#e76f51",
     "A retired ferry captain takes one last run up a frozen coast to bring her estranged son home.", True),
    ("glass-harbor", "The Glass Harbor", 2021, "R", 131, ["Thriller", "Mystery"], "#0b3d3a", "#94d2bd",
     "When a lighthouse keeper finds a ship's log dated next week, the harbor town starts counting down.", True),
    ("paper-satellites", "Paper Satellites", 2016, "PG", 102, ["Comedy", "Family"], "#3a0ca3", "#f72585",
     "Two kids build a rocket out of cereal boxes and accidentally get the attention of mission control.", False),
    ("low-tide", "Low Tide", 2023, "R", 109, ["Crime", "Drama"], "#283618", "#dda15e",
     "A shellfish diver and a detective chase the same body across three mudflat towns.", False),
    ("signal-fires", "Signal Fires", 1998, "PG-13", 124, ["Action", "Thriller"], "#6a040f", "#ffba08",
     "A forest-fire lookout intercepts a message meant for someone who died twenty years ago.", True),
    ("midnight-transit", "Midnight Transit", 2012, "R", 97, ["Crime", "Thriller"], "#03071e", "#4cc9f0",
     "A night-bus driver has until dawn to deliver a passenger nobody else can see.", False),
    ("orchardist", "The Orchardist", 2008, "PG", 112, ["Drama"], "#386641", "#f2e8cf",
     "One apple harvest, four generations, and a letter that arrives forty years late.", False),
    ("copperline", "Copperline", 2022, "PG-13", 140, ["Science Fiction", "Adventure"], "#582f0e", "#b6ad90",
     "Miners on a copper moon discover the vein they're following is following them back.", True),
]
SHOWS = [
    ("deep-field", "Deep Field", 2020, "TV-14", ["Science Fiction", "Drama"], "Apple TV+", "#10002b", "#c77dff",
     "An observatory crew spots a galaxy that wasn't there yesterday, and it's getting closer.", 3),
    ("office-hours", "Office Hours", 2005, "TV-PG", ["Comedy"], "NBC", "#1b263b", "#ffd166",
     "A community college's night-school faculty try, and mostly fail, to teach anyone anything.", 2),
    ("kingfisher", "Kingfisher", 2017, "TV-MA", ["Crime", "Drama"], "HBO", "#001219", "#ee9b00",
     "A river-police unit in a flooded city works the cases nobody on dry land wants.", 2),
    ("crossing", "The Crossing", 2014, "TV-14", ["Drama", "Mystery"], "ABC", "#335c67", "#fff3b0",
     "Hundreds of strangers wash ashore claiming to be from a future that hasn't happened yet.", 1),
]
PEOPLE = [("ada-reyes", "Ada Reyes", "#9d4edd"), ("tom-okafor", "Tom Okafor", "#ff7b00"),
          ("june-park", "June Park", "#2a9d8f"), ("leo-marsh", "Leo Marsh", "#e63946"),
          ("mira-stone", "Mira Stone", "#457b9d"), ("sam-quill", "Sam Quill", "#bc6c25")]
PROFILES = [("p-alex", "Alex", "#e5a00d"), ("p-sam", "Sam", "#2a9d8f"), ("p-kids", "Kids", "#e63946")]


def ff(args):
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", *args], check=True)


def esc(text):
    return text.replace(":", "\\:").replace("'", "’")


def poster(name, title, year, a, b):
    path = os.path.join(OUT, f"{name}-poster.jpg")
    if os.path.exists(path):
        return
    ff(["-f", "lavfi", "-i", f"gradients=s=400x600:c0={b}:c1={a}:x0=400:y0=0:x1=0:y1=450:d=1",
        "-vf", f"vignette=PI/3,drawtext=fontfile='{FONT}':text='{esc(title.upper())}':fontcolor=white:fontsize=34:x=(w-tw)/2:y=h*0.72,"
               f"drawtext=fontfile='{FONT_LIGHT}':text='{year}':fontcolor=white@0.8:fontsize=22:x=(w-tw)/2:y=h*0.72+48",
        "-frames:v", "1", "-q:v", "4", path])


def backdrop(name, a, b, size="1280x720", suffix="backdrop", label=None):
    path = os.path.join(OUT, f"{name}-{suffix}.jpg")
    if os.path.exists(path):
        return
    w, h = size.split("x")
    text = f",drawtext=fontfile='{FONT_LIGHT}':text='{esc(label)}':fontcolor=white@0.35:fontsize=40:x=w*0.62:y=h*0.4" if label else ""
    ff(["-f", "lavfi", "-i", f"gradients=s={size}:c0={b}:c1={a}:c2=#000000:x0={int(w)//1}:y0=0:x1=0:y1={h}:nb_colors=3:d=1",
        "-vf", f"noise=alls=6:allf=t{text}", "-frames:v", "1", "-q:v", "5", path])


def logo(name, title):
    path = os.path.join(OUT, f"{name}-logo.png")
    if os.path.exists(path):
        return
    ff(["-f", "lavfi", "-i", "color=c=black@0.0:s=900x220,format=rgba",
        "-vf", f"drawtext=fontfile='{FONT}':text='{esc(title.upper())}':fontcolor=white:fontsize=110:x=0:y=(h-th)/2:"
               f"shadowcolor=black@0.5:shadowx=4:shadowy=4",
        "-frames:v", "1", path])


def portrait(name, color):
    path = os.path.join(OUT, f"{name}-profile.jpg")
    if os.path.exists(path):
        return
    ff(["-f", "lavfi", "-i", f"gradients=s=300x450:c0={color}:c1=#111111:d=1", "-frames:v", "1", "-q:v", "5", path])


def video():
    path = os.path.join(OUT, "showcase.mp4")
    if os.path.exists(path):
        return
    # Footage that reads as a film under the hero and the player's controls:
    # a slowly turning dusk gradient with a quiet tone under it.
    ff(["-f", "lavfi", "-i", "gradients=s=640x360:r=24:d=20:c0=#1b2a4a:c1=#c8643c:c2=#0b0d14:nb_colors=3:speed=0.015,vignette",
        "-f", "lavfi", "-i", "sine=f=220:d=20,volume=0.2",
        "-c:v", "libx264", "-preset", "veryfast", "-crf", "26", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "64k",
        "-movflags", "+faststart", path])


def art(name, kind, color):
    return {"src": f"showcase/{name}-{kind}.{'png' if kind == 'logo' else 'jpg'}", "color": color, "placeholder": None}


def write(name, payload):
    with open(os.path.join(OUT, f"{name}.json"), "w") as file:
        json.dump(payload, file, indent=1)


for key, title, year, rating, runtime, genres, a, b, overview, has_logo in MOVIES:
    poster(key, title, year, a, b)
    backdrop(key, a, b)
    if has_logo:
        logo(key, title)
for key, title, year, rating, genres, network, a, b, overview, seasons in SHOWS:
    poster(key, title, year, a, b)
    backdrop(key, a, b)
    logo(key, title)
    for episode in range(1, 7):
        backdrop(f"{key}-s1e{episode}", a, b, size="960x540", suffix="still", label=f"E{episode}")
for key, name, color in PEOPLE:
    portrait(key, color)
video()

print("artwork ready in", os.path.relpath(OUT))


# --- The API's answers ------------------------------------------------------

NOW = datetime.now(timezone.utc).replace(microsecond=0)
MOVIE = {m[0]: m for m in MOVIES}
SHOW = {s[0]: s for s in SHOWS}


def images(key, logo_too=False, color="#222222"):
    out = {"poster": art(key, "poster", color), "backdrop": art(key, "backdrop", color)}
    if logo_too:
        out["logo"] = art(key, "logo", None)
    return out


def movie_card(key, progress=None, watched=False):
    _, title, year, rating, runtime, genres, a, b, overview, has_logo = MOVIE[key]
    return {"kind": "movie", "id": key, "title": title, "year": year, "content_rating": rating, "runtime_minutes": runtime,
            "images": images(key, has_logo, a), "progress": progress, "watched": watched, "credit": None}


def show_card(key, unwatched=0, arrival=None):
    _, title, year, rating, genres, network, a, b, overview, seasons = SHOW[key]
    return {"kind": "show", "id": key, "title": title, "year": year, "content_rating": rating,
            "images": images(key, True, a), "unwatched_count": unwatched, "arrival": arrival}


EPISODE_TITLES = ["First Light", "Redshift", "The Long Exposure", "Parallax", "Dark Matter", "Event Horizon"]


def episode_id(show, season, number):
    return f"{show}-s{season}e{number}"


def episode_card(show, number, progress=None, watched=False):
    _, title, year, rating, genres, network, a, b, overview, seasons = SHOW[show]
    return {"kind": "episode", "id": episode_id(show, 1, number), "code": f"S01E{number:02d}", "title": EPISODE_TITLES[number - 1],
            "season_number": 1, "episode_number": number,
            "show": {"id": show, "title": title, "images": images(show, True, a)},
            "images": {"still": art(f"{show}-s1e{number}", "still", a)}, "progress": progress, "watched": watched}


LIBRARIES = [{"id": "lib-movies", "name": "Movies", "kind": "movies"}, {"id": "lib-tv", "name": "TV Shows", "kind": "shows"},
             {"id": "lib-youtube", "name": "YouTube", "kind": "channels"}, {"id": "lib-home", "name": "Home videos", "kind": "home_videos"}]
write("api_v1_libraries", LIBRARIES)

profiles = [{"id": key, "name": name, "color": color, "avatar": None, "has_pin": key == "p-sam", "kind": "kid" if key == "p-kids" else "standard"}
            for key, name, color in PROFILES]
write("api_v1_profiles", profiles)
write("api_v1_profiles_current", {"profile": profiles[0], "chosen": True, "needs_picker": False})
write("api_v1_profiles_current_picker", {"profile": profiles[0], "chosen": False, "needs_picker": True})
for profile in profiles:
    write(f"post_api_v1_profiles_{profile['id']}_select", {"token": "showcase", "profile": profile})

write("post_api_v1_pairings", {"code": "KX7Q-2MPD", "poll_token": "showcase-poll", "expires_at": (NOW + timedelta(minutes=10)).isoformat()})
write("api_v1_pairings_showcase-poll", {"state": "pending", "token": None, "user": None})

hero_movie = MOVIE["northbound"]
write("api_v1_home", {
    "hero": {"kind": "movie", "id": "northbound", "title": hero_movie[1], "subtitle": str(hero_movie[2]), "label": "Continue watching",
             "overview": hero_movie[8], "images": images("northbound", True, hero_movie[6]), "play": {"kind": "movie", "id": "northbound"},
             "progress": 0.42, "resume_at": 2974.0, "trailer": {"url": "showcase/showcase.mp4", "name": "Official Trailer"}},
    "hubs": [
        {"key": "continue_watching", "title": "Continue watching", "kind": "continue",
         "items": [movie_card("northbound", 0.42), episode_card("deep-field", 3, 0.18), movie_card("low-tide", 0.77)]},
        {"key": "next_up", "title": "Next up", "kind": "wide", "items": [episode_card("deep-field", 4), episode_card("deep-field", 5)]},
        {"key": "recently_added:lib-movies", "title": "Recently added in Movies", "kind": "poster",
         "items": [movie_card(k, watched=(k == "orchardist")) for k in ["copperline", "glass-harbor", "low-tide", "signal-fires", "midnight-transit", "orchardist", "paper-satellites"]]},
        {"key": "recently_added:lib-tv", "title": "Recently added in TV Shows", "kind": "poster",
         "items": [show_card("deep-field", 3, "New episodes"), show_card("kingfisher", 8), show_card("office-hours"), show_card("crossing", 2)]},
    ],
    "layout": [],
})
write("api_v1_movies", [movie_card(m[0], watched=(m[0] == "orchardist")) for m in MOVIES])
write("api_v1_shows", [show_card(s[0], unwatched) for s, unwatched in zip(SHOWS, [3, 0, 8, 2])])
write("api_v1_collections", [
    {"id": "col-coast", "title": "Stories from the Coast", "collection_kind": "manual", "item_count": 3, "images": {"poster": art("northbound", "poster", None)}},
    {"id": "col-night", "title": "After Dark", "collection_kind": "smart", "item_count": 4, "images": {"poster": art("midnight-transit", "poster", None)}},
])

# YouTube videos and home videos, for their tiles.
VIDEOS = [("vid-dishwasher", "The dishwasher, revisited", 754, "Technology Connections", "kingfisher"),
          ("vid-tides", "Why the tide comes in twice a day", 1322, "Veritasium", "low-tide"),
          ("vid-lenses", "Every lens explained", 998, "Filmmaker IQ", "glass-harbor"),
          ("vid-copper", "How copper is mined", 641, "Practical Engineering", "copperline")]
video_cards = [{"kind": "video", "id": key, "title": title, "upload_date": "2026-09-2%d" % (i + 1), "duration_seconds": length,
                "channel": {"id": "ch-" + channel.lower().replace(" ", "-"), "title": channel, "avatar": None},
                "images": {"thumb": art(pic, "backdrop", None)}, "progress": 0.3 if i == 1 else None, "watched": False}
               for i, (key, title, length, channel, pic) in enumerate(VIDEOS)]
clip_cards = [{"kind": "clip", "id": f"clip-{i}", "title": f"IMG_{4020 + i}", "captured_at": f"202{i}-09-27T15:0{i}:00", "captured_floating": True,
               "city": city, "country": "United Kingdom", "favorite": i == 0, "duration_seconds": 34 + i * 20,
               "images": {"thumb": art(f"deep-field-s1e{i + 1}", "still", None)}, "progress": None, "watched": False}
              for i, city in enumerate(["Brighton", "Whitby", "St Ives"])]
home = json.load(open(os.path.join(OUT, "api_v1_home.json")))
home["hubs"].insert(2, {"key": "subscriptions", "title": "New from your subscriptions", "kind": "videos", "items": video_cards})
home["hubs"].append({"key": "on_this_day", "title": "On this day", "kind": "clips", "items": clip_cards})
write("api_v1_home", home)
write("api_v1_watch_later", {"id": "pl-later", "items": ["glass-harbor"]})
write("api_v1_playlists", [{"id": "pl-later", "title": "Watch later", "item_count": 3, "watch_later": True, "first": None},
                           {"id": "pl-friday", "title": "Friday nights", "item_count": 5, "watch_later": False, "first": None}])

# Grid: five channels airing the showcase's titles around now.
def iso(moment):
    return moment.isoformat().replace("+00:00", "Z")


slot = NOW.replace(minute=0 if NOW.minute < 30 else 30, second=0)
stations = []
lineups = [("2", "Deep Field", "deep-field", 60), ("4", "NBC", "office-hours", 30), ("5", "Movies", None, 120),
           ("7", "Kingfisher", "kingfisher", 60), ("9", "Coast", "crossing", 60)]
films = ["glass-harbor", "signal-fires", "copperline", "midnight-transit", "orchardist"]
for index, (number, name, show, minutes) in enumerate(lineups):
    airings = []
    start = slot - timedelta(minutes=minutes)
    for n in range(10):
        begins = start + timedelta(minutes=minutes * n)
        if show:
            _, title, year, rating, genres, network, a, b, overview, seasons = SHOW[show]
            ep = n % 6 + 1
            airings.append({"id": f"air-{number}-{n}", "station_id": f"st-{number}", "starts_at": iso(begins), "ends_at": iso(begins + timedelta(minutes=minutes)),
                            "reason": "The channel's mix", "filler": False, "kind": "episode", "playable_id": episode_id(show, 1, ep), "title": title,
                            "subtitle": f"S01E{ep:02d} · {EPISODE_TITLES[ep - 1]}", "episode_title": EPISODE_TITLES[ep - 1], "code": f"S01E{ep:02d}",
                            "show_id": show, "year": year, "content_rating": rating, "overview": overview, "reminded": False,
                            "media_start": 0, "media_end": None, "images": {"still": art(f"{show}-s1e{ep}", "still", a), "backdrop": art(show, "backdrop", a)}})
        else:
            key = films[n % len(films)]
            _, title, year, rating, runtime, genres, a, b, overview, has_logo = MOVIE[key]
            airings.append({"id": f"air-{number}-{n}", "station_id": f"st-{number}", "starts_at": iso(begins), "ends_at": iso(begins + timedelta(minutes=minutes)),
                            "reason": "The channel's mix", "filler": False, "kind": "movie", "playable_id": key, "title": title, "subtitle": str(year),
                            "episode_title": None, "code": None, "show_id": None, "year": year, "content_rating": rating, "overview": overview,
                            "reminded": False, "media_start": 0, "media_end": None, "images": {"backdrop": art(key, "backdrop", a), "poster": art(key, "poster", a)}})
    stations.append({"id": f"st-{number}", "number": number, "name": name, "call_sign": None, "hidden": False, "favorite": number == "2", "airings": airings})
write("api_v1_stations", [{k: v for k, v in station.items() if k != "airings"} for station in stations]
      + [{"id": "st-12", "number": "12", "name": "Shopping Hour", "call_sign": None, "hidden": True, "favorite": False}])
write("api_v1_guide", {"now": iso(NOW), "from": iso(slot - timedelta(hours=2)), "to": iso(slot + timedelta(hours=8)), "time_zone": "Europe/London", "stations": stations})


# Title pages: details, seasons, people, collections, channels, playlists.
def cast(start=0):
    roles = ["Ruth Calder", "Eli Calder", "Harbourmaster", "Detective Wynn", "The Pilot", "Mrs Asher"]
    people = [{"person_id": key, "name": name, "role": "cast", "character": roles[(i + start) % len(roles)], "job": None,
               "image": art(key, "profile", color)} for i, (key, name, color) in enumerate(PEOPLE)]
    return people + [{"person_id": "mira-stone", "name": "Mira Stone", "role": "director", "character": None, "job": "Director", "image": None}]


def extras(key, a):
    return [{"id": f"{key}-trailer", "kind": "extra", "extra_kind": "trailer", "kind_label": "Trailer", "title": "Official Trailer",
             "duration_seconds": 142, "images": {"thumb": art(key, "backdrop", a)}, "season_number": None},
            {"id": f"{key}-making", "kind": "extra", "extra_kind": "featurette", "kind_label": "Featurette", "title": "Making the film",
             "duration_seconds": 611, "images": {"thumb": art(key, "backdrop", a)}, "season_number": None}]


for i, (key, title, year, rating, runtime, genres, a, b, overview, has_logo) in enumerate(MOVIES):
    detail = movie_card(key, 0.42 if key == "northbound" else None, watched=(key == "orchardist"))
    detail.update({"overview": overview, "tagline": "Some journeys only go one way." if key == "northbound" else None, "genres": genres,
                   "resume_at": 2974.0 if key == "northbound" else None, "my_rating": 8 if key == "glass-harbor" else None,
                   "trailer": {"url": "showcase/showcase.mp4", "name": "Official Trailer"},
                   "versions": [{"media_file_id": f"{key}-file", "edition": None, "filename": f"{title}.mkv", "video": "4K HDR", "audio": "Atmos",
                                 "playable": True, "unplayable_reason": None}],
                   "cast": cast(i), "extras": extras(key, a),
                   "collections": [{"id": "col-coast", "title": "Stories from the Coast", "kind": "manual"}] if key in ("northbound", "low-tide", "glass-harbor") else []})
    write(f"api_v1_movies_{key}", detail)
    write(f"api_v1_movies_{key}_similar", [movie_card(m[0]) for m in MOVIES if m[0] != key][:6])

for key, title, year, rating, genres, network, a, b, overview, seasons in SHOWS:
    detail = show_card(key, 3 if key == "deep-field" else 0)
    detail.update({"overview": overview, "genres": genres, "network": network, "status": "Returning Series",
                   "trailer": {"url": "showcase/showcase.mp4", "name": "Official Trailer"}, "my_rating": None,
                   "seasons": [{"season_number": n, "title": f"Season {n}", "episode_count": 6, "available_count": 6 if n == 1 else 4,
                                "watched_count": 2 if n == 1 else 0, "images": {}} for n in range(1, seasons + 1)],
                   "next_up": {"episode_id": episode_id(key, 1, 3), "code": "S01E03", "title": EPISODE_TITLES[2], "resume_at": 842.0, "started_show": True},
                   "cast": cast(2), "extras": extras(key, a)[:1], "collections": []})
    write(f"api_v1_shows_{key}", detail)
    write(f"api_v1_shows_{key}_similar", [show_card(x[0]) for x in SHOWS if x[0] != key] + [movie_card("copperline")])
    for n in range(1, seasons + 1):
        episodes = []
        for e in range(1, 7 if n == 1 else 5):
            card = episode_card(key, e, progress=0.3 if (n, e) == (1, 3) else None, watched=(n == 1 and e < 3))
            card.update({"id": episode_id(key, n, e), "code": f"S{n:02d}E{e:02d}", "season_number": n, "overview":
                         "The crew argue over what they saw, and a long exposure shows something that shouldn't be there." if e % 2 else
                         "A night at the telescope becomes a week, and the town below starts to notice the light.",
                         "air_date": f"{year + n - 1}-0{min(e, 9)}-1{e % 9}", "runtime_minutes": 48 if key != "office-hours" else 22,
                         "available": True, "resume_at": 842.0 if (n, e) == (1, 3) else None, "my_rating": None, "versions": [], "locked_fields": []})
            episodes.append(card)
        write(f"api_v1_shows_{key}_seasons_{n}", {"season_number": n, "title": f"Season {n}",
                                                  "overview": f"Season {n} of {title}." if n > 1 else None, "episodes": episodes})

for i, (key, name, color) in enumerate(PEOPLE):
    write(f"api_v1_people_{key}", {"id": key, "name": name, "image": art(key, "profile", color), "tmdb_id": 1000 + i,
                                   "movies": [movie_card(m[0]) for m in MOVIES[i:i + 4]], "shows": [show_card(x[0]) for x in SHOWS[:2]]})

write("api_v1_collections_col-coast", {"id": "col-coast", "title": "Stories from the Coast", "collection_kind": "manual", "item_count": 3,
                                       "overview": "Harbours, tides and the people who wait on them.", "images": images("glass-harbor", False, "#0b3d3a"),
                                       "items": [movie_card(k) for k in ("northbound", "glass-harbor", "low-tide")], "pinned_to_home": False,
                                       "locked_fields": [], "rules": None})
write("api_v1_collections_col-night", {"id": "col-night", "title": "After Dark", "collection_kind": "smart", "item_count": 4,
                                       "overview": "Films that happen between dusk and dawn.", "images": images("midnight-transit", False, "#03071e"),
                                       "items": [movie_card(k) for k in ("midnight-transit", "signal-fires", "low-tide", "glass-harbor")],
                                       "pinned_to_home": False, "locked_fields": [], "rules": None})

channel = {"id": "ch-technology-connections", "kind": "channel", "title": "Technology Connections", "handle": "@TechConnectify",
           "description": "Videos about the everyday technology we take for granted, and the history behind it.",
           "subscribed": True, "url": None, "youtube_id": None, "library": {"id": "lib-youtube", "name": "YouTube"},
           "images": {"backdrop": art("kingfisher", "backdrop", None)}, "videos": video_cards}
write("api_v1_channels_ch-technology-connections", channel)
for card in video_cards:
    detail = dict(card)
    detail.update({"description": "A deep look at how it works, why it was built that way, and what went wrong along the way.",
                   "tags": [], "url": None, "youtube_id": None, "source": "info_json", "chapters": [], "playable": True,
                   "resume_at": 400.0 if card["progress"] else None, "more_from_channel": [c for c in video_cards if c["id"] != card["id"]]})
    write(f"api_v1_videos_{card['id']}", detail)

write("api_v1_playlists_pl-later", {"id": "pl-later", "title": "Watch later", "item_count": 3, "watch_later": True, "first": None, "pinned_to_home": False,
                                    "items": [movie_card("glass-harbor"), episode_card("deep-field", 4), video_cards[0]]})
write("api_v1_playlists_pl-friday", {"id": "pl-friday", "title": "Friday nights", "item_count": 3, "watch_later": False, "first": None, "pinned_to_home": False,
                                     "items": [movie_card(k) for k in ("signal-fires", "midnight-transit", "copperline")]})



# Libraries and search: the YouTube channels, home videos through time, and
# one search's answer (the showcase answers every query the same way).
CHANNELS = [("ch-technology-connections", "Technology Connections", "@TechConnectify", "#c8643c", 212, 3),
            ("ch-veritasium", "Veritasium", "@veritasium", "#3c7dc8", 388, 0),
            ("ch-filmmaker-iq", "Filmmaker IQ", "@FilmmakerIQ", "#8a4fd0", 146, 1),
            ("ch-practical-engineering", "Practical Engineering", "@PracticalEngineeringChannel", "#3ca06e", 194, 5),
            ("ch-map-men", "Map Men", "@MapMen", "#d0b04f", 61, 0)]
for key, _title, _handle, color, _count, _unwatched in CHANNELS:
    portrait(key, color)
channel_cards = [{"kind": "channel", "id": key, "title": title, "handle": handle, "avatar": art(key, "profile", color), "banner": None,
                  "video_count": count, "unwatched_count": unwatched, "latest_upload": "2026-09-2%d" % (i + 1)}
                 for i, (key, title, handle, color, count, unwatched) in enumerate(CHANNELS)]
write("api_v1_channels", channel_cards)

PLACES = ["Brighton", "Whitby", "St Ives", "Lewes", None, "Rye"]
MOMENTS = ["2026-08-14T10:12:00", "2026-08-02T17:40:00", "2026-07-21T09:05:00", "2026-07-19T19:22:00", "2026-07-04T12:00:00",
           "2025-12-25T08:31:00", "2025-12-24T16:02:00", "2025-10-11T14:45:00", "2024-06-30T11:11:00", "2024-06-29T20:47:00"]
shows_for_clips = ["deep-field", "kingfisher", "office-hours", "crossing"]
timeline = [{"kind": "clip", "id": f"clip-t{i}", "title": f"IMG_{5100 + i}", "captured_at": moment, "captured_floating": True,
             "city": PLACES[i % len(PLACES)], "country": "United Kingdom", "favorite": i % 4 == 0, "duration_seconds": 18 + i * 13,
             "images": {"thumb": art(f"{shows_for_clips[i % 4]}-s1e{i % 6 + 1}", "still", None)},
             "progress": 0.5 if i == 1 else None, "watched": i == 3}
            for i, moment in enumerate(MOMENTS)]
write("api_v1_clips", {"years": [{"year": 2026, "count": 5}, {"year": 2025, "count": 3}, {"year": 2024, "count": 2}], "clips": timeline, "more": False})
write("api_v1_clips_filters", {"albums": [{"id": "al-summer", "title": "Summer 2026", "count": 5}, {"id": "al-xmas", "title": "Christmas", "count": 2}],
                               "people": [{"id": f"hp-{key}", "name": name.split()[0], "count": 3 + i, "image": art(key, "profile", color)}
                                          for i, (key, name, color) in enumerate(PEOPLE[:4])],
                               "favorites": 3})

write("api_v1_search", {
    "movies": [movie_card("northbound", 0.42), movie_card("glass-harbor"), movie_card("low-tide")],
    "shows": [show_card("deep-field", 3), show_card("kingfisher", 8)],
    "episodes": [episode_card("deep-field", 2), episode_card("kingfisher", 5)],
    "people": [{"id": key, "name": name, "image": art(key, "profile", color)} for key, name, color in PEOPLE[:3]],
    "collections": [{"id": "col-coast", "title": "Stories from the Coast", "image": art("northbound", "poster", None)}],
    "channels": [{"id": c["id"], "title": c["title"], "image": c["avatar"]} for c in channel_cards[:2]],
    "videos": video_cards[:2],
    "said": [{"kind": "movie", "id": "northbound", "title": "Northbound", "start": 1834.0,
              "snippet": "…if we don't make the <<north>> harbour by morning, we don't make it at all…"},
             {"kind": "video", "id": "vid-tides", "title": "Why the tide comes in twice a day", "start": 412.0,
              "snippet": "…the moon pulls the water <<north>> and south as the earth turns under it…"}],
    "clips": timeline[:2],
})

# The player: one session answers every Play, over the twenty-second clip —
# an intro to skip, credits with Up next, chapters, a SponsorBlock span on
# the bar, subtitles, two audio tracks and a trickplay sheet.
sheet = os.path.join(OUT, "trickplay-sheet-0.webp")
if not os.path.exists(sheet):
    ff(["-i", os.path.join(OUT, "showcase.mp4"), "-vf", "fps=1,scale=320:180,tile=5x4", "-frames:v", "1", "-c:v", "libwebp", "-quality", "70", sheet])
with open(os.path.join(OUT, "showcase.vtt"), "w") as file:
    file.write("WEBVTT\n\n"
               "00:00:00.500 --> 00:00:04.000\nThe tide turns at six. We go with it.\n\n"
               "00:00:04.500 --> 00:00:09.000\nAnd if the ice has closed the harbour?\n\n"
               "00:00:09.500 --> 00:00:14.000\nThen we go north until it hasn't.\n")
write("post_api_v1_playback_sessions", {
    "id": "ps-showcase", "method": "direct_play", "profile_id": "p-alex",
    "title": "Deep Field", "subtitle": "S01E03 · The Long Exposure", "back_path": "/show/deep-field?season=1",
    "show_id": "deep-field", "season_number": 1,
    "source": {"kind": "file", "url": "showcase/showcase.mp4", "mime_type": "video/mp4"},
    "progress_url": "showcase/progress", "events_url": "showcase/events", "audio_stream_index": 1,
    "subtitles": [{"id": "sub-en", "language": "en", "title": None, "forced": False, "default": True, "format": "srt",
                   "stream_index": 3, "urls": {"vtt": "showcase/showcase.vtt"}},
                  {"id": "sub-fr", "language": "fr", "title": "SDH", "forced": False, "default": False, "format": "pgs",
                   "stream_index": 4, "urls": {}}],
    "fonts": [],
    "chapters": [{"start": 0, "end": 5, "title": "Cold open"}, {"start": 5, "end": 12, "title": "The harbour"},
                 {"start": 12, "end": 20, "title": "Northbound"}],
    "trickplay": {"sheet_url": "showcase/trickplay-sheet-{index}.webp", "interval": 1, "tile_width": 320, "tile_height": 180,
                  "columns": 5, "rows": 4, "count": 20},
    "markers": [{"kind": "intro", "start": 2, "end": 8}, {"kind": "credits", "start": 15, "end": 20}],
    "skip": {"intro": False, "recap": False, "credits": False},
    "next_up": {"kind": "episode", "id": episode_id("deep-field", 1, 4), "code": "S01E04", "title": "Parallax", "show_title": "Deep Field",
                "image": art("deep-field-s1e4", "still", None), "playlist_id": None},
    "segments": [{"category": "sponsor", "start": 9, "end": 11, "action": "show"}],
    "playlist_id": None, "up_next_seconds": 10, "still_watching_after": 3, "loudness": None,
    "decision": {"summary": "Direct play", "video": None, "audio": None},
    "resume_at": 0, "duration_seconds": 20, "frame_rate": 24, "burned_subtitle": None,
    "media_file": {"id": "mf-showcase", "filename": "Deep Field S01E03.mkv",
                   "audio": [{"index": 1, "codec": "eac3", "language": "en", "title": None, "channels": 6, "default": True, "forced": False},
                             {"index": 2, "codec": "aac", "language": "fr", "title": "Commentary", "channels": 2, "default": False, "forced": False}],
                   "subtitles": []},
    "live": None,
})

# Baseball (PROPOSAL §7.8): made-up clubs, one game of each kind on today's slate.
CLUBS = {"HCG": (9001, "Harbor City", "Gulls", "#4cc9f0"), "NFX": (9002, "Northfield", "Foxes", "#f77f00"),
         "CVM": (9003, "Copper Valley", "Miners", "#d4a373"), "LKP": (9004, "Lakeport", "Herons", "#90be6d"),
         "RDG": (9005, "Ridgeline", "Owls", "#c77dff"), "BAY": (9006, "Bayside", "Pilots", "#ef476f")}


def club_logo(abbreviation):
    path = os.path.join(OUT, f"club-{abbreviation.lower()}-logo.png")
    if os.path.exists(path):
        return
    color = CLUBS[abbreviation][3]
    ff(["-f", "lavfi", "-i", "color=c=black@0.0:s=240x240,format=rgba",
        "-vf", f"drawtext=fontfile='{FONT}':text='{abbreviation[:2]}':fontcolor={color}:fontsize=130:x=(w-tw)/2:y=(h-th)/2:"
               f"borderw=6:bordercolor=white",
        "-frames:v", "1", path])


def club(abbreviation, record, score=None, pitcher=None, winner=False, hits=None, errors=None):
    team_id, location, name, _ = CLUBS[abbreviation]
    club_logo(abbreviation)
    logo = f"showcase/club-{abbreviation.lower()}-logo.png"
    return {"team": {"id": team_id, "name": f"{location} {name}", "club": name, "location": location, "abbreviation": abbreviation,
                     "logo_url": logo, "logo_png_url": logo},
            "record": record, "score": score, "hits": hits, "errors": errors, "winner": winner, "probable_pitcher": pitcher}


def ballgame(game_id, starts, state, status, away, home, watchable=False, inning=None, innings=(), broadcasts=(), decisions=None):
    return {"id": game_id, "starts_at": iso(starts), "start_time_tbd": False, "state": state, "status": status, "watchable": watchable,
            "venue": f"{home['team']['location']} Park", "series": None, "double_header": None, "inning": inning,
            "innings": [{"number": n, "away": a, "home": h} for n, (a, h) in enumerate(innings, 1)], "scheduled_innings": 9,
            "away": away, "home": home, "broadcasts": [{"name": n, "side": side} for n, side in broadcasts], "decisions": decisions}


write("api_v1_baseball", {"available": True})
write("api_v1_baseball_games", {
    # Not in Stream's answer: it moves the games' times to now (Showcase.shifted).
    "now": iso(NOW),
    "date": NOW.date().isoformat(), "today": NOW.date().isoformat(),
    "previous_date": (NOW - timedelta(days=1)).date().isoformat(), "next_date": (NOW + timedelta(days=1)).date().isoformat(),
    "games": [
        ballgame(1, NOW - timedelta(hours=2), "live", "In Progress", club("HCG", "88-61", 4, hits=8, errors=0),
                 club("NFX", "79-70", 3, hits=7, errors=1), watchable=True,
                 inning={"number": 7, "ordinal": "7th", "half": "top", "outs": 1, "balls": 2, "strikes": 1,
                         "bases": {"first": True, "second": False, "third": True}},
                 innings=[(0, 1), (2, 0), (0, 0), (1, 2), (0, 0), (1, 0), (0, None)], broadcasts=[("GULLS TV", "away"), ("FOX 9", "home")]),
        ballgame(2, NOW + timedelta(minutes=20), "upcoming", "Warmup", club("CVM", "70-79", pitcher="June Park"),
                 club("LKP", "91-58", pitcher="Leo Marsh"), watchable=True, broadcasts=[("KCVM", "away"), ("Heron Sports", "home")]),
        ballgame(3, NOW + timedelta(hours=3), "upcoming", "Scheduled", club("RDG", "64-85", pitcher="Sam Quill"),
                 club("BAY", "83-66", pitcher="Mira Stone"), broadcasts=[("Pilots Network", "home")]),
        ballgame(4, NOW - timedelta(hours=5), "final", "Final", club("BAY", "83-66", 2, winner=False, hits=5, errors=1),
                 club("HCG", "88-61", 6, winner=True, hits=11, errors=0),
                 innings=[(0, 0), (1, 3), (0, 0), (0, 1), (1, 0), (0, 0), (0, 2), (0, 0), (0, None)],
                 decisions={"winner": "Ada Reyes", "loser": "Tom Okafor", "save": None}),
    ],
})
post_watch = {"live_stream_id": "ls-gulls", "name": "Harbor City Gulls"}
write("post_api_v1_baseball_games_1_watch", post_watch)
write("post_api_v1_baseball_games_2_watch", {"live_stream_id": "ls-miners", "name": "Copper Valley Miners"})

print("answers written")
