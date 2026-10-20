import Foundation

/// The light outside, by the clock: where the sun is in the sky, the
/// colour temperature of its light there, and the faint cast that gives
/// the desk's backdrop — warm when the sun is low, morning and evening,
/// cooler when it's high, and a cool dim blue after dusk.
public enum Daylight {
    /// A place on the earth, in degrees (north and east positive).
    public struct Place: Equatable, Sendable {
        public var latitude: Double
        public var longitude: Double
        public init(latitude: Double, longitude: Double) {
            self.latitude = latitude
            self.longitude = longitude
        }
    }

    /// What the light does to a colour: a multiplier for each linear
    /// channel, the brightest 1, mixed in by `strength`.
    public struct Cast: Equatable, Sendable {
        public var red: Double
        public var green: Double
        public var blue: Double
        /// The sun's elevation and its light's temperature, for showing.
        public var elevation: Double
        public var kelvin: Double

        /// No cast: the colours as chosen.
        public static let neutral = Cast(red: 1, green: 1, blue: 1, elevation: 90, kelvin: reference)
    }

    /// The temperature the backdrop's colours were chosen under: light at
    /// it leaves them as they are.
    public static let reference: Double = 5500
    /// How far toward the light's own colour a colour goes, at most.
    public static let strength: Double = 0.18

    // MARK: The sun

    /// The sun's elevation above the horizon, in degrees, at `date` seen
    /// from `place` (the NOAA almanac's short form: good to a fraction of
    /// a degree, more than enough for a colour).
    public static func elevation(at date: Date, from place: Place) -> Double {
        let rad = Double.pi / 180
        // Days since J2000.0.
        let n = date.timeIntervalSince1970 / 86400 + 2440587.5 - 2451545.0
        let g = (357.529 + 0.98560028 * n) * rad
        let q = 280.459 + 0.98564736 * n
        let lambda = (q + 1.915 * sin(g) + 0.020 * sin(2 * g)) * rad
        let epsilon = (23.439 - 0.00000036 * n) * rad
        let ra = atan2(cos(epsilon) * sin(lambda), cos(lambda))
        let decl = asin(sin(epsilon) * sin(lambda))
        let gmst = (18.697374558 + 24.06570982441908 * n) * 15 * rad
        let hour = gmst + place.longitude * rad - ra
        let phi = place.latitude * rad
        return asin(sin(phi) * sin(decl) + cos(phi) * cos(decl) * cos(hour)) / rad
    }

    /// The light's colour temperature with the sun at `elevation`, and
    /// how much of it shows: low sun warm (2700 K at the horizon), high
    /// sun toward 6400 K; through civil twilight the sky's blue takes
    /// over, and the night keeps it, half as strong.
    public static func light(elevation e: Double) -> (kelvin: Double, weight: Double) {
        if e >= 0 { return (2700 + 3700 * (1 - exp(-e / 18)), 1) }
        let night = 7000.0
        if e <= -6 { return (night, 0.5) }
        let t = -e / 6
        let s = t * t * (3 - 2 * t)
        return (2700 + (night - 2700) * s, 1 - 0.5 * s)
    }

    /// The cast at `date` from `place`.
    public static func cast(at date: Date, from place: Place) -> Cast {
        let e = elevation(at: date, from: place)
        let (k, weight) = light(elevation: e)
        let c = rgb(kelvin: k), r = rgb(kelvin: reference)
        var f = [c.0 / r.0, c.1 / r.1, c.2 / r.2]
        let top = f.max() ?? 1
        f = f.map { $0 / top }
        let s = strength * weight
        return Cast(red: 1 - s + s * f[0], green: 1 - s + s * f[1], blue: 1 - s + s * f[2], elevation: e, kelvin: k)
    }

    /// A blackbody's colour at `kelvin`, in linear sRGB with Y = 1: the
    /// Planckian locus (Krystek's fit, 1000–15000 K) in CIE 1960 UCS,
    /// to xy, to XYZ, to sRGB.
    public static func rgb(kelvin: Double) -> (Double, Double, Double) {
        let t = min(15000, max(1000, kelvin))
        let u = (0.860117757 + 1.54118254e-4 * t + 1.28641212e-7 * t * t) / (1 + 8.42420235e-4 * t + 7.08145163e-7 * t * t)
        let v = (0.317398726 + 4.22806245e-5 * t + 4.20481691e-8 * t * t) / (1 - 2.89741816e-5 * t + 1.61456053e-7 * t * t)
        let d = 2 * u - 8 * v + 4
        let x = 3 * u / d, y = 2 * v / d
        let X = x / y, Y = 1.0, Z = (1 - x - y) / y
        return (max(0, 3.2406 * X - 1.5372 * Y - 0.4986 * Z),
                max(0, -0.9689 * X + 1.8758 * Y + 0.0415 * Z),
                max(0, 0.0557 * X - 0.2040 * Y + 1.0570 * Z))
    }

    // MARK: Where we are

    /// Where the clock's time zone is, as the system's zone table places
    /// its city — no asking for the Mac's location; failing that, the
    /// zone's meridian at a middling latitude.
    public static func place(for zone: TimeZone = .current) -> Place {
        if let p = zoneTable[zone.identifier] { return p }
        let standard = Double(zone.secondsFromGMT() - Int(zone.daylightSavingTimeOffset()))
        return Place(latitude: 40, longitude: standard / 240)
    }

    private static let zoneTable: [String: Place] = {
        guard let text = try? String(contentsOfFile: "/usr/share/zoneinfo/zone.tab", encoding: .utf8) else { return [:] }
        return parseZoneTable(text)
    }()

    /// zone.tab's lines: country, ±DDMM±DDDMM (or with seconds), zone.
    public static func parseZoneTable(_ text: String) -> [String: Place] {
        var out: [String: Place] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let f = line.split(separator: "\t")
            guard f.count >= 3, let p = coordinates(String(f[1])) else { continue }
            out[String(f[2])] = p
        }
        return out
    }

    /// "+5955+01045", "+340308-1181434": ISO 6709 degrees and minutes
    /// (and seconds).
    static func coordinates(_ s: String) -> Place? {
        guard let split = s.dropFirst().firstIndex(where: { $0 == "+" || $0 == "-" }) else { return nil }
        func degrees(_ part: Substring, _ width: Int) -> Double? {
            guard let sign = part.first, sign == "+" || sign == "-" else { return nil }
            let digits = Array(part.dropFirst())
            guard digits.count == width + 2 || digits.count == width + 4, digits.allSatisfy(\.isNumber) else { return nil }
            let d = Double(String(digits[0..<width]))!
            let m = Double(String(digits[width..<width + 2]))!
            let sec = digits.count == width + 4 ? Double(String(digits[(width + 2)...]))! : 0
            return (sign == "-" ? -1 : 1) * (d + m / 60 + sec / 3600)
        }
        guard let lat = degrees(s[..<split], 2), let lon = degrees(s[split...], 3) else { return nil }
        return Place(latitude: lat, longitude: lon)
    }
}
