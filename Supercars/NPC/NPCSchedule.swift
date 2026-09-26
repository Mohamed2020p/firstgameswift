import Foundation

// MARK: - NPCSchedule: how busy the city is at a given hour and in a given district.  Day: more pedestrians and normal activity.
// Night: far fewer people, but downtown / the plaza stay lively (nightlife).

enum NPCSchedule {
    /// 0 (dead of night) ... 1 (midday)
    static func dayFactor(hour: Float) -> Float {
        let up: Float = smoothstep(5.0, 8.0, hour)
        let down: Float = 1 - smoothstep(19.5, 23.0, hour)
        return up * down
    }

    /// relative pedestrian density of a district at the given hour (multiplies the spawn acceptance)
    static func density(kind: WBlockKind, hour: Float) -> Float {
        let day: Float = dayFactor(hour: hour)
        var dayValue: Float = 0.5
        var nightValue: Float = 0.1
        switch kind {
        case .downtown:
            dayValue = 1.0
            nightValue = 0.55
        case .midrise:
            dayValue = 0.8
            nightValue = 0.3
        case .residential:
            dayValue = 0.5
            nightValue = 0.08
        case .park:
            dayValue = 0.65
            nightValue = 0.04
        case .plaza:
            dayValue = 0.95
            nightValue = 0.5
        case .industrial:
            dayValue = 0.22
            nightValue = 0.04
        case .civic:
            dayValue = 0.4
            nightValue = 0.15
        }
        return nightValue + (dayValue - nightValue) * day
    }

    /// share of the pedestrian budget in use at this hour
    static func populationScale(hour: Float) -> Float {
        return 0.4 + 0.6 * dayFactor(hour: hour)
    }

    /// taxis: busiest in the evening and at night, but always some
    static func taxiDemand(hour: Float) -> Float {
        let evening: Float = smoothstep(17, 20, hour) * (1 - smoothstep(23.5, 24, hour))
        let early: Float = 1 - smoothstep(2, 5, hour)
        return clampf(0.35 + 0.4 * dayFactor(hour: hour) + 0.35 * max(evening, early), 0.2, 1)
    }
}
