#!/usr/bin/env python3
"""Convert PATCO's official GTFS ZIP archive into the app's bundled JSON feed."""

import csv
import io
import json
import sys
import zipfile


SOURCE_URL = "https://rapid.nationalrtap.org/GTFSFileManagement/UserUploadFiles/13562/PATCO_GTFS.zip"
REQUIRED_FILES = (
    "agency.txt", "feed_info.txt", "routes.txt", "stops.txt", "calendar.txt",
    "calendar_dates.txt", "trips.txt", "stop_times.txt",
)
STATION_NAMES = {
    "9-10th and Locust": "9/10th and Locust",
    "12-13th and Locust": "12/13th and Locust",
    "15-16th and Locust": "15/16th and Locust",
}


def rows(archive: zipfile.ZipFile, filename: str) -> list[dict[str, str]]:
    with archive.open(filename) as file:
        return list(csv.DictReader(io.TextIOWrapper(file, encoding="utf-8-sig")))


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("Usage: UpdatePATCOGTFS.py INPUT.zip OUTPUT.json")

    archive_path, output_path = sys.argv[1:]
    with zipfile.ZipFile(archive_path) as archive:
        missing = [filename for filename in REQUIRED_FILES if filename not in archive.namelist()]
        if missing:
            raise SystemExit(f"Archive is missing required files: {', '.join(missing)}")

        agency = rows(archive, "agency.txt")[0]
        feed = rows(archive, "feed_info.txt")[0]
        route = next(
            (row for row in rows(archive, "routes.txt") if row.get("route_short_name", "").upper() == "PATCO"),
            None,
        )
        if route is None:
            raise SystemExit("Archive does not contain a PATCO route")

        feed.setdefault("feed_publisher_name", agency.get("agency_name", ""))
        stations = [
            {
                "id": row["stop_id"],
                "code": row.get("stop_code") or row["stop_id"],
                "name": STATION_NAMES.get(row["stop_name"], row["stop_name"]),
                "latitude": float(row["stop_lat"]),
                "longitude": float(row["stop_lon"]),
                "zone": row.get("zone_id", ""),
                "url": row.get("stop_url", ""),
            }
            for row in rows(archive, "stops.txt")
            if row.get("location_type", "0") != "1"
        ]
        calendars = [
            {
                "serviceId": row["service_id"],
                "weekdays": {day: row[day] == "1" for day in (
                    "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"
                )},
                "startDate": row["start_date"],
                "endDate": row["end_date"],
            }
            for row in rows(archive, "calendar.txt")
        ]
        calendar_dates = [
            {
                "serviceId": row["service_id"],
                "date": row["date"],
                "exceptionType": int(row["exception_type"]),
            }
            for row in rows(archive, "calendar_dates.txt")
        ]
        stop_times: dict[str, list[dict[str, str]]] = {}
        for row in rows(archive, "stop_times.txt"):
            stop_times.setdefault(row["trip_id"], []).append(row)

        trips = []
        for row in rows(archive, "trips.txt"):
            if row.get("route_id") != route["route_id"]:
                continue
            times = sorted(stop_times.get(row["trip_id"], []), key=lambda time: int(time["stop_sequence"]))
            if len(times) < 2:
                continue
            trips.append({
                "id": row["trip_id"],
                "serviceId": row["service_id"],
                "headsign": row["trip_headsign"],
                "directionId": int(row["direction_id"]) if row.get("direction_id") else None,
                "bikesAllowed": row.get("bikes_allowed") == "1",
                "wheelchairAccessible": row.get("wheelchair_accessible") == "1",
                "stopTimes": [
                    {
                        "stopId": time["stop_id"],
                        "arrival": time["arrival_time"],
                        "departure": time["departure_time"],
                        "sequence": int(time["stop_sequence"]),
                    }
                    for time in times
                ],
            })

    output = {
        "generatedFrom": SOURCE_URL,
        "feed": feed,
        "route": route,
        "stops": stations,
        "calendars": calendars,
        "calendarDates": calendar_dates,
        "trips": trips,
    }
    with open(output_path, "w", encoding="utf-8") as file:
        json.dump(output, file, separators=(",", ":"))


if __name__ == "__main__":
    main()
